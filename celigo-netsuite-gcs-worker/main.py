"""
Celigo NetSuite GCS Worker

This module provides a Google Cloud Function that fetches PDF files from URLs
provided in API requests and stores them in Google Cloud Storage, with associated metadata.
It supports both single file uploads and batch processing.

Environment Variables:
    DESTINATION_BUCKET: GCS bucket where files will be stored (required)
    AUTHORIZED_TOKENS: Comma-separated list of valid bearer tokens (required)
    GCP_PROJECT: GCP project ID (optional, default is inferred from credentials)
    ALLOWED_NETSUITE_HOST: Allowed NetSuite host for PDF downloads (optional, default: https://5260239.app.netsuite.com)
    LOG_LEVEL: DEBUG, INFO, WARNING, ERROR (optional, default: INFO)
    LOG_SUCCESSFUL_RESPONSES: true/false (optional, default: true)
    LOG_RESPONSE_DETAILS: true/false (optional, default: false)
"""

import uuid
from datetime import datetime, timezone
from typing import Any, Dict, Tuple, Union
from urllib.parse import urlparse

import functions_framework
import requests
from flask import jsonify
from google.cloud.storage import Client as StorageClient

from auth import authenticate_request
from config import config
from logging_config import get_logger
from validation import sanitize_billing_account_id, sanitize_request_for_logging

# Initialize logger
logger = get_logger(__name__)


# Initialize GCS client
if config.GCP_PROJECT:
    storage_client = StorageClient(project=config.GCP_PROJECT)
else:
    storage_client = StorageClient()

bucket = storage_client.bucket(config.DESTINATION_BUCKET)


@functions_framework.http
def main(request) -> Tuple[Any, int]:
    """
    Main Cloud Function entrypoint that handles HTTP requests.

    Authenticates the request using bearer token, then processes both single file
    requests and batch file requests, determining the request type based on the
    JSON payload structure.

    Args:
        request: HTTP request object containing a JSON payload.

    Returns:
        Tuple[Any, int]: JSON response and HTTP status code.
    """
    request_id = str(uuid.uuid4())

    logger.info(
        f"[{request_id}] Incoming {request.method} request to {request.path}",
        extra={
            "request_id": request_id,
            "method": request.method,
            "path": request.path,
            "remote_addr": request.remote_addr,
            "user_agent": request.headers.get("User-Agent"),
        },
    )

    if not authenticate_request(request, request_id):
        return jsonify(
            {
                "error": "Unauthorized. Valid bearer token required.",
                "status": "UNAUTHORIZED",
            }
        ), 401

    try:
        request_json = request.get_json()
    except Exception as e:
        logger.error(
            f"[{request_id}] Failed to parse JSON payload: {e}",
            extra={
                "request_id": request_id,
                "error_type": type(e).__name__,
                "content_type": request.headers.get("Content-Type"),
                "content_length": request.headers.get("Content-Length"),
                "raw_data_preview": str(request.get_data())[:200] if config.LOG_RESPONSE_DETAILS else None,
            },
        )
        return jsonify({"error": "Invalid JSON payload."}), 400

    if not request_json:
        logger.error(
            f"[{request_id}] Empty JSON payload received",
            extra={
                "request_id": request_id,
                "content_type": request.headers.get("Content-Type"),
                "content_length": request.headers.get("Content-Length"),
            },
        )
        return jsonify({"error": "Empty JSON payload."}), 400

    # Log request details for debugging
    if config.LOG_RESPONSE_DETAILS:
        sanitized_request = sanitize_request_for_logging(request_json)
        logger.debug(
            f"[{request_id}] Request payload details",
            extra={
                "request_id": request_id,
                "payload_size": len(str(request_json)),
                "payload_keys": list(request_json.keys()),
                "request_body": sanitized_request,
            },
        )

    # Check if this is the batch format with files array
    if "files" in request_json:
        file_count = len(request_json.get("files", []))
        logger.info(
            f"[{request_id}] Processing batch request with {file_count} files",
            extra={"request_id": request_id, "file_count": file_count},
        )
        return process_files_payload(request_json, request_id)

    # Process single file (NetSuite format)
    elif "fullUrl" in request_json:
        file_name = request_json.get("name")
        logger.info(
            f"[{request_id}] Processing single file: {file_name}",
            extra={"request_id": request_id, "file_name": file_name},
        )
        return process_single_file(request_json, request_id)

    else:
        logger.error(
            f"[{request_id}] Invalid payload structure: {list(request_json.keys())}",
            extra={"request_id": request_id, "payload_keys": list(request_json.keys())},
        )
        return jsonify({"error": 'JSON payload must include either "files" or "fullUrl" field.'}), 400


def process_files_payload(payload: Dict[str, Any], request_id: str) -> Tuple[Any, int]:
    """
    Process a payload containing a list of files (batch format).

    Args:
        payload: JSON payload containing a 'files' array of file information.
        request_id: Unique request ID for logging correlation.

    Returns:
        Tuple[Any, int]: Response containing processing results and HTTP status code.
    """
    if not payload.get("success"):
        logger.error(
            f"[{request_id}] Batch request rejected: upstream operation unsuccessful",
            extra={
                "request_id": request_id,
                "payload_success": payload.get("success"),
                "payload_status": payload.get("status"),
                "files_count": len(payload.get("files", [])),
                "payload_keys": list(payload.keys()),
                "request_body": sanitize_request_for_logging(payload) if config.config.LOG_RESPONSE_DETAILS else None,
            },
        )
        return jsonify({"error": "Payload indicates unsuccessful upstream operation. Aborting."}), 400

    files = payload.get("files", [])
    if not files:
        logger.error(
            f"[{request_id}] Batch request has no files",
            extra={
                "request_id": request_id,
                "payload_keys": list(payload.keys()),
                "files_field_type": type(payload.get("files")).__name__,
                "request_body": sanitize_request_for_logging(payload) if config.config.LOG_RESPONSE_DETAILS else None,
            },
        )
        return jsonify({"error": "No files found in payload."}), 400

    results = []
    errors = []

    # Log batch processing start with summary
    if config.LOG_RESPONSE_DETAILS:
        billing_accounts_preview = {}
        file_names_preview = []
        for file_info in files[:10]:  # Preview first 10 files
            if isinstance(file_info, dict):
                billing_account = file_info.get("billingAccountId", "unknown")
                billing_accounts_preview[billing_account] = billing_accounts_preview.get(billing_account, 0) + 1
                file_names_preview.append(file_info.get("name", f"file_{file_info.get('id', 'unknown')}"))

        logger.info(
            f"[{request_id}] Starting batch processing of {len(files)} files",
            extra={
                "request_id": request_id,
                "total_files": len(files),
                "billing_accounts_preview": billing_accounts_preview,
                "sample_file_names": file_names_preview[:5],
                "files_truncated": len(files) > 10,
            },
        )

    for file_info in files:
        try:
            # Extract file information
            file_url = file_info.get("fullUrl")
            if not file_url:
                error_msg = "Missing URL"
                logger.warning(
                    f"[{request_id}] File missing URL: {file_info.get('name', 'unknown')}",
                    extra={
                        "request_id": request_id,
                        "file_name": file_info.get("name"),
                        "file_id": file_info.get("id"),
                        "file_info_keys": list(file_info.keys()) if isinstance(file_info, dict) else None,
                        "file_info": file_info if config.LOG_RESPONSE_DETAILS else None,
                    },
                )
                errors.append({"file": file_info.get("name"), "error": error_msg})
                continue

            file_name = file_info.get("name")
            if not file_name:
                file_name = f"file_{file_info.get('id', datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S'))}.pdf"
            elif not file_name.lower().endswith(".pdf"):
                file_name += ".pdf"

            raw_billing_account_id = file_info.get("billingAccountId", "")
            folder = sanitize_billing_account_id(raw_billing_account_id)

            metadata = {k: str(v) for k, v in file_info.items() if v is not None}

            content = retrieve_pdf_from_url(file_url)
            if isinstance(content, tuple):  # Error response
                error_response = content[0].get_json()["error"]
                logger.warning(
                    f"[{request_id}] Failed to retrieve PDF for {file_name}: {error_response}",
                    extra={
                        "request_id": request_id,
                        "file_name": file_name,
                        "file_url": file_url,
                        "billing_account_id": folder,
                        "http_status": content[1],
                        "error_response": content[0].get_json() if config.LOG_RESPONSE_DETAILS else None,
                    },
                )
                errors.append({"file": file_name, "error": error_response})
                continue

            logger.debug(
                f"[{request_id}] Downloaded {file_name} ({len(content)} bytes)",
                extra={"request_id": request_id, "file_name": file_name, "file_size": len(content)},
            )

            try:
                status = save_file_to_gcs(file_name, folder, content, metadata)
                results.append(status)

                if config.LOG_SUCCESSFUL_RESPONSES:
                    extra_data = {
                        "request_id": request_id,
                        "file_name": file_name,
                        "file_path": status.get("file_path"),
                        "billing_account_id": folder,
                    }
                    if config.LOG_RESPONSE_DETAILS:
                        extra_data.update(
                            {"file_size": len(content), "content_type": "application/pdf", "upload_status": status}
                        )
                    logger.info(
                        f"[{request_id}] Uploaded {file_name} to {folder}/{file_name}",
                        extra=extra_data,
                    )
            except Exception as e:
                logger.error(
                    f"[{request_id}] Error saving {file_name} to GCS: {e}",
                    extra={
                        "request_id": request_id,
                        "file_name": file_name,
                        "billing_account_id": folder,
                        "error_type": type(e).__name__,
                        "error_message": str(e),
                        "file_size": len(content),
                        "blob_name": f"{folder}/{file_name}",
                        "bucket_name": config.DESTINATION_BUCKET,
                        "metadata_count": len(metadata) if metadata else 0,
                    },
                )
                errors.append({"file": file_name, "error": str(e)})

        except Exception as e:
            logger.error(
                f"[{request_id}] Unexpected error processing file {file_info.get('name', 'unknown')}: {e}",
                extra={
                    "request_id": request_id,
                    "file_name": file_info.get("name", "unknown"),
                    "file_id": file_info.get("id"),
                },
            )
            errors.append({"file": file_info.get("name", "unknown"), "error": str(e)})

    response = {
        "processed": len(results),
        "total": len(files),
        "results": results,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "destination_bucket": config.DESTINATION_BUCKET,
    }

    if errors:
        response["errors"] = errors
        # Log detailed error summary for failed batch operations
        if config.LOG_RESPONSE_DETAILS:
            error_summary = {}
            for error in errors:
                error_type = error.get("error", "Unknown error")
                error_summary[error_type] = error_summary.get(error_type, 0) + 1

            logger.warning(
                f"[{request_id}] Batch errors summary",
                extra={
                    "request_id": request_id,
                    "total_errors": len(errors),
                    "error_types": error_summary,
                    "failed_files": [e.get("file") for e in errors[:5]],
                },
            )

    # Enhanced batch completion logging
    completion_level = "info" if len(errors) == 0 else "warning" if len(results) > 0 else "error"
    extra_data = {
        "request_id": request_id,
        "total_files": len(files),
        "successful": len(results),
        "failed": len(errors),
        "success_rate": round((len(results) / len(files)) * 100, 2) if files else 0,
    }

    if config.LOG_RESPONSE_DETAILS and results:
        # Add details about successful uploads
        billing_accounts = {}
        for result in results[:10]:  # Limit to first 10
            file_path = result.get("file_path", "")
            if "/" in file_path:
                account = file_path.split("/")[0]
                billing_accounts[account] = billing_accounts.get(account, 0) + 1

        extra_data.update(
            {
                "billing_accounts_used": billing_accounts,
                "sample_successful_files": [r.get("file_name") for r in results[:5]],
            }
        )

    getattr(logger, completion_level)(
        f"[{request_id}] Batch completed: {len(results)}/{len(files)} successful ({extra_data['success_rate']}%)",
        extra=extra_data,
    )

    # Let's return a mixed status if we had any success or a 400 if we didn't process anything successfully
    response_status_code = 400 if completion_level == "error" else 207

    return jsonify(response), response_status_code


def process_single_file(request_json: Dict[str, Any], request_id: str) -> Tuple[Any, int]:
    """
    Process a payload containing a single file (legacy format).

    Args:
        request_json: JSON payload containing file information with 'fullUrl'.
        request_id: Unique request ID for logging correlation.

    Returns:
        Tuple[Any, int]: Response containing processing results and HTTP status code.
    """
    pdf_url = request_json.get("fullUrl")
    if not pdf_url:
        return jsonify({"error": "No fullUrl found in payload."}), 400

    file_name = request_json.get("name")
    if not file_name:
        file_name = datetime.now(timezone.utc).strftime("%Y-%m-%d-%H-%M-%S")

    raw_billing_account_id = request_json.get("billingAccountId", "")
    folder = sanitize_billing_account_id(raw_billing_account_id)

    if not file_name.lower().endswith(".pdf"):
        file_name += ".pdf"

    metadata = {k: str(v) for k, v in request_json.items() if v is not None}

    if "_PARENT" in request_json and isinstance(request_json["_PARENT"], dict):
        for key, value in request_json["_PARENT"].items():
            metadata[f"_PARENT_{key}"] = str(value)

    content = retrieve_pdf_from_url(pdf_url)
    if isinstance(content, tuple):  # Error response
        return content

    # Log successful download
    logger.debug(
        f"[{request_id}] Downloaded {file_name} ({len(content)} bytes)",
        extra={"request_id": request_id, "file_name": file_name, "file_size": len(content)},
    )

    try:
        status = save_file_to_gcs(file_name, folder, content, metadata)

        # Log successful upload if configured
        if config.LOG_SUCCESSFUL_RESPONSES:
            extra_data = {
                "request_id": request_id,
                "file_name": file_name,
                "file_path": status.get("file_path"),
                "billing_account_id": folder,
            }
            if config.LOG_RESPONSE_DETAILS:
                extra_data.update(
                    {
                        "file_size": len(content),
                        "content_type": "application/pdf",
                        "upload_status": status,
                        "metadata_fields": list(metadata.keys()) if metadata else [],
                    }
                )
            logger.info(
                f"[{request_id}] Uploaded single file {file_name} to {folder}/{file_name}",
                extra=extra_data,
            )
        response = {
            **status,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "destination_bucket": config.DESTINATION_BUCKET,
        }

        return jsonify(response), 200
    except Exception as e:
        logger.error(
            f"[{request_id}] Error saving single file {file_name}: {e}",
            extra={
                "request_id": request_id,
                "file_name": file_name,
                "billing_account_id": folder,
                "error_type": type(e).__name__,
                "error_message": str(e),
                "file_size": len(content),
                "blob_name": f"{folder}/{file_name}",
                "bucket_name": config.DESTINATION_BUCKET,
                "metadata_count": len(metadata) if metadata else 0,
                "pdf_url": pdf_url,
            },
        )
        return jsonify({"error": str(e)}), 500


def retrieve_pdf_from_url(pdf_url: str) -> Union[bytes, Tuple[Any, int]]:
    """
    Download the PDF from the provided URL.

    Verifies that the content is a PDF by checking:
    1. Content-Type header
    2. URL extension
    3. File signature (%PDF-)

    Security: Only allows downloads from the configured NetSuite host to prevent SSRF attacks.

    Args:
        pdf_url: URL of the PDF file to download.

    Returns:
        Union[bytes, Tuple[Any, int]]:
            - If successful: PDF file content as bytes
            - If failed: Tuple of error response and HTTP status code
    """
    try:
        parsed_url = urlparse(pdf_url)
        allowed_parsed = urlparse(config.ALLOWED_NETSUITE_HOST)
        if parsed_url.scheme != allowed_parsed.scheme or parsed_url.netloc != allowed_parsed.netloc:
            logger.error(
                f"SSRF prevention: Blocked request to unauthorized host {parsed_url.scheme}://{parsed_url.netloc}",
                extra={
                    "provided_url": pdf_url,
                    "provided_host": f"{parsed_url.scheme}://{parsed_url.netloc}",
                    "allowed_host": config.ALLOWED_NETSUITE_HOST,
                    "url_path": parsed_url.path,
                    "url_query": parsed_url.query,
                },
            )
            return jsonify(
                {
                    "error": "Invalid URL. Only NetSuite URLs are allowed.",
                    "details": {
                        "provided_host": f"{parsed_url.scheme}://{parsed_url.netloc}",
                        "allowed_host": config.ALLOWED_NETSUITE_HOST,
                    },
                }
            ), 403
    except Exception as e:
        logger.error(
            f"URL parsing failed: {str(e)}",
            extra={"provided_url": pdf_url, "error_type": type(e).__name__, "error_message": str(e)},
        )
        return jsonify({"error": f"Invalid URL format: {str(e)}"}), 400

    try:
        response = requests.get(pdf_url)
        if response.status_code != 200:
            logger.error(
                f"HTTP request failed with status {response.status_code}",
                extra={
                    "url": pdf_url,
                    "status_code": response.status_code,
                    "response_headers": dict(response.headers) if config.LOG_RESPONSE_DETAILS else None,
                    "response_text": response.text[:500] if config.LOG_RESPONSE_DETAILS and response.text else None,
                },
            )
            return jsonify({"error": f"Failed to retrieve file. Status code: {response.status_code}"}), 400

        content_type = response.headers.get("Content-Type", "").lower()
        is_pdf_content_type = "application/pdf" in content_type
        is_pdf_extension = pdf_url.lower().endswith(".pdf")
        is_pdf_signature = False
        if len(response.content) >= 5:
            is_pdf_signature = response.content[:5] == b"%PDF-"

        if not (is_pdf_content_type or is_pdf_extension or is_pdf_signature):
            logger.error(
                "File validation failed: Not a PDF",
                extra={
                    "url": pdf_url,
                    "content_type": content_type,
                    "file_size": len(response.content),
                    "has_pdf_content_type": is_pdf_content_type,
                    "has_pdf_extension": is_pdf_extension,
                    "has_pdf_signature": is_pdf_signature,
                    "first_bytes": response.content[:20].hex() if response.content else None,
                    "response_headers": dict(response.headers) if config.LOG_RESPONSE_DETAILS else None,
                },
            )
            return jsonify(
                {
                    "error": "The retrieved file does not appear to be a PDF.",
                    "details": {
                        "content_type": content_type,
                        "url": pdf_url,
                        "file_size": len(response.content),
                        "first_bytes": str(response.content[:20] if response.content else b""),
                    },
                }
            ), 400

        return response.content
    except requests.exceptions.RequestException as e:
        logger.error(
            f"Request exception during PDF retrieval: {str(e)}",
            extra={
                "url": pdf_url,
                "error_type": type(e).__name__,
                "error_message": str(e),
                "timeout_occurred": "timeout" in str(e).lower(),
                "connection_error": "connection" in str(e).lower(),
            },
        )
        return jsonify({"error": f"Error retrieving PDF: {str(e)}"}), 500


def save_file_to_gcs(file_name: str, folder: str, content: bytes, metadata: Dict[str, Any]) -> Dict[str, str]:
    """
    Upload the file content to Google Cloud Storage.

    Creates a date-based folder structure (YYYY-MM-DD) and stores
    the file within that folder, along with associated metadata.

    Args:
        file_name: Name of the file to store.
        folder: Name of the folder/partition key to store the file.
        content: Binary content of the file.
        metadata: Dictionary of metadata to associate with the file.

    Returns:
        Dict[str, str]: Status information about the uploaded file.
    """
    blob_name = f"{folder}/{file_name}"

    try:
        blob = bucket.blob(blob_name)
        if metadata:
            cleaned_metadata = {k: str(v) for k, v in metadata.items() if v is not None}
            blob.metadata = cleaned_metadata
            if config.LOG_RESPONSE_DETAILS:
                logger.debug(
                    f"Setting metadata for {blob_name}",
                    extra={
                        "blob_name": blob_name,
                        "metadata_keys": list(cleaned_metadata.keys()),
                        "metadata_count": len(cleaned_metadata),
                    },
                )

        blob.upload_from_string(content, content_type="application/pdf")

        if config.LOG_RESPONSE_DETAILS:
            logger.debug(
                f"Successfully uploaded {blob_name}",
                extra={
                    "blob_name": blob_name,
                    "bucket_name": bucket.name,
                    "file_size": len(content),
                    "content_type": "application/pdf",
                },
            )

        return {
            "message": "File uploaded successfully.",
            "file_path": blob_name,
            "file_name": file_name,
        }
    except Exception as e:
        logger.error(
            f"GCS upload failed for {blob_name}: {str(e)}",
            extra={
                "blob_name": blob_name,
                "bucket_name": bucket.name,
                "file_size": len(content),
                "error_type": type(e).__name__,
                "error_message": str(e),
                "metadata_provided": bool(metadata),
            },
        )
        raise
