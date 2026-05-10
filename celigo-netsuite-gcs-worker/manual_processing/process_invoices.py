#!/usr/bin/env python3
"""
Process large NetSuite invoice JSON file by sending each record individually to the GCS worker endpoint.

This script reads a JSON file containing multiple invoice records and sends each one
to the production endpoint for processing and storage in GCS using parallel workers.

This script is intended for large backfill operations that Celigo cannot directly manage and should only be run locally,
and attended.

Expected Input File Schema:
{
    "success": true,
    "status": "COMPLETE",
    "files": [
        {
            "rownumber": 1,
            "id": 3136716,
            "name": "INV23112428313.pdf",
            "url": "/core/media/media.nl?id=3136716&c=5260239&h=somehash&_xt=.pdf",
            "fullUrl": "https://5260239.app.netsuite.com/core/media/media.nl?id=3136716&c=5260239&h=somehash&_xt=.pdf",
            "billingAccountId": "shriek_underestimated"
        },
        ... more file objects
    ]
}

Required fields per file:
- fullUrl: Complete URL to the PDF file
- name: Filename
- id: File ID from NetSuite
- billingAccountId: Used as folder name in GCS. Technically ptiona

Optional fields per file:

- rownumber: Row number from source data
- Any additional fields will be stored as metadata

Output Files:
- success_audit_[timestamp].json: Full details of successful uploads including GCS paths
- errors_[timestamp].json: Details of any failed uploads
- processing_summary_[timestamp].json: Overall statistics and references to output files
"""

import json
import os
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from threading import Lock
from typing import Any, Dict, List, Tuple

import requests
from dotenv import load_dotenv

# Environment Config - REQUIRED
load_dotenv()
BEARER_TOKEN = os.environ.get("CELIGO_NETSUITE_GCS_WORKER_API_KEY")

# Configuration - UPDATE THESE VALUES
ENDPOINT_URL = "https://us-central1-fivetran-automation.cloudfunctions.net/celigo-netsuite-gcs-worker"
INPUT_FILE = "invoicePdf2024JanMar.json"
DELAY_BETWEEN_REQUESTS = 0  # Seconds, decimal okay
UPLOAD_COMMENTS = f"Processed via bulk script by edicristofaro: {INPUT_FILE}"

# Optional configuration
TIMEOUT_SECONDS = 30  # Request timeout
MAX_RETRIES = 3  # Number of retries for failed requests
RETRY_DELAY = 5  # Seconds to wait before retrying
MAX_WORKERS = 20  # Number of parallel workers - tested up to 20 for large batches, can probably go higher


def process_single_file(
    file_data: Dict[str, Any], session: requests.Session, index: int, total: int
) -> Tuple[int, Dict[str, Any]]:
    """
    Send a single file record to the endpoint in the single-file format.

    Args:
        file_data: File information from the batch JSON
        session: Requests session with auth headers
        index: Current file index (1-based)
        total: Total number of files

    Returns:
        Tuple of (index, response data or error information)
    """
    # Convert from batch format to single file format
    # The single file endpoint expects 'fullUrl' at the root level
    single_file_payload = {
        "fullUrl": file_data["fullUrl"],
        "name": file_data["name"],
        "id": file_data["id"],
        "billingAccountId": file_data.get("billingAccountId", ""),
        # Include any other metadata fields
        "rownumber": file_data.get("rownumber"),
        "upload_comments": UPLOAD_COMMENTS,
    }

    # Add any additional fields that exist in the file data
    for key, value in file_data.items():
        if key not in single_file_payload and value is not None:
            single_file_payload[key] = value

    for attempt in range(MAX_RETRIES):
        try:
            response = session.post(ENDPOINT_URL, json=single_file_payload, timeout=TIMEOUT_SECONDS)

            if response.status_code == 200:
                return index, {
                    "success": True,
                    "status_code": response.status_code,
                    "response": response.json(),
                    "request_payload": single_file_payload,
                    "file_data": file_data,
                }
            else:
                # Don't retry for client errors (4xx)
                if 400 <= response.status_code < 500:
                    return index, {
                        "success": False,
                        "status_code": response.status_code,
                        "error": response.text,
                        "no_retry": True,
                        "file_data": file_data,
                    }

                # For server errors, retry
                if attempt < MAX_RETRIES - 1:
                    print(
                        f"  [File {index}/{total}] Attempt {attempt + 1} failed with status {response.status_code}, retrying..."
                    )
                    time.sleep(RETRY_DELAY)
                    continue

                return index, {
                    "success": False,
                    "status_code": response.status_code,
                    "error": response.text,
                    "file_data": file_data,
                }

        except requests.exceptions.RequestException as e:
            if attempt < MAX_RETRIES - 1:
                print(f"  [File {index}/{total}] Attempt {attempt + 1} failed with exception: {e}, retrying...")
                time.sleep(RETRY_DELAY)
                continue

            return index, {
                "success": False,
                "error": str(e),
                "exception_type": type(e).__name__,
                "file_data": file_data,
            }

    return index, {"success": False, "error": "Max retries exceeded", "file_data": file_data}


def main():
    """Main processing function."""
    print(f"Starting invoice processing at {datetime.now()}")
    print(f"Endpoint: {ENDPOINT_URL}")
    print(f"Input file: {INPUT_FILE}")
    print(f"Parallel workers: {MAX_WORKERS}")
    print()

    # Load the JSON file
    try:
        with open(INPUT_FILE, "r") as f:
            data = json.load(f)
    except Exception as e:
        print(f"Error loading JSON file: {e}")
        return

    # Validate the structure
    if not isinstance(data, dict) or "files" not in data:
        print("Error: Invalid JSON structure. Expected 'files' array.")
        return

    files = data.get("files", [])
    total_files = len(files)

    print(f"Found {total_files} files to process")
    print(f"Delay between requests: {DELAY_BETWEEN_REQUESTS}s")
    print()

    # Track start time for ETA calculations
    start_time = datetime.now()

    # Process statistics with thread-safe tracking
    stats_lock = Lock()
    successful = 0
    failed = 0
    errors: List[Dict[str, Any]] = []
    successes: List[Dict[str, Any]] = []
    processed = 0

    # Process results helper
    def process_result(index: int, result: Dict[str, Any]):
        nonlocal successful, failed, processed

        file_data = result["file_data"]
        file_name = file_data.get("name", f"unknown_{file_data.get('id', index)}")

        with stats_lock:
            processed += 1

            if result["success"]:
                successful += 1
                print(f"[{processed}/{total_files}] {file_name}: ✓ Success", flush=True)

                # Log successful upload details
                if "response" in result:
                    response_data = result["response"]
                    if "file_path" in response_data:
                        print(f"  → Uploaded to: {response_data['file_path']}", flush=True)

                    # Track success details for audit log
                    success_entry = {
                        "file": file_name,
                        "file_id": file_data.get("id"),
                        "row_number": file_data.get("rownumber"),
                        "billing_account_id": file_data.get("billingAccountId"),
                        "timestamp": datetime.now().isoformat(),
                        "request_payload": result.get("request_payload"),
                        "api_response": response_data,
                        "gcs_location": response_data.get("file_path"),
                        "destination_bucket": response_data.get("destination_bucket"),
                    }
                    successes.append(success_entry)
            else:
                failed += 1
                print(f"[{processed}/{total_files}] {file_name}: ✗ Failed", flush=True)
                print(f"  → Error: {result.get('error', 'Unknown error')}", flush=True)

                # Track error details
                errors.append(
                    {
                        "file": file_name,
                        "file_id": file_data.get("id"),
                        "error": result.get("error"),
                        "status_code": result.get("status_code"),
                        "row_number": file_data.get("rownumber"),
                        "timestamp": datetime.now().isoformat(),
                    }
                )

            # Print progress summary every 100 files or 10% of total (whichever is smaller)
            progress_interval = min(100, max(1, total_files // 10))
            if processed % progress_interval == 0 or processed == total_files:
                elapsed = (datetime.now() - start_time).total_seconds()
                rate = processed / elapsed if elapsed > 0 else 0
                eta_seconds = (total_files - processed) / rate if rate > 0 else 0
                eta_str = f"{int(eta_seconds // 60)}m {int(eta_seconds % 60)}s" if eta_seconds > 0 else "calculating..."
                print(
                    f"\n>>> Progress: {processed}/{total_files} ({processed / total_files * 100:.1f}%) | "
                    f"Success: {successful} | Failed: {failed} | "
                    f"Rate: {rate:.1f} files/sec | ETA: {eta_str}\n",
                    flush=True,
                )

    # Process files in parallel
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        # Create sessions for each worker to avoid connection pooling issues
        sessions = []
        for _ in range(MAX_WORKERS):
            session = requests.Session()
            session.headers.update({"Authorization": f"Bearer {BEARER_TOKEN}", "Content-Type": "application/json"})
            sessions.append(session)

        # Submit all tasks
        print("Submitting files for processing...\n", flush=True)
        future_to_index = {}
        for i, file_data in enumerate(files, 1):
            # Use round-robin to distribute sessions across workers
            session = sessions[(i - 1) % MAX_WORKERS]
            future = executor.submit(process_single_file, file_data, session, i, total_files)
            future_to_index[future] = i

            # Show submission progress for large batches
            if total_files > 100 and i % 100 == 0:
                print(f"Submitted {i}/{total_files} files...", flush=True)

            # Add delay between submissions if configured
            if DELAY_BETWEEN_REQUESTS > 0 and i < total_files:
                time.sleep(DELAY_BETWEEN_REQUESTS)

        print(f"All {total_files} files submitted. Processing with {MAX_WORKERS} workers...\n", flush=True)

        # Process completed tasks as they finish
        for future in as_completed(future_to_index):
            try:
                index, result = future.result()
                process_result(index, result)
            except Exception as e:
                index = future_to_index[future]
                print(f"[{index}/{total_files}] Unexpected error: {e}")
                with stats_lock:
                    failed += 1
                    processed += 1

    # Print summary
    print("\n" + "=" * 60)
    print("PROCESSING COMPLETE")
    print("=" * 60)
    print(f"Total files: {total_files}")
    print(f"Successful: {successful} ({successful / total_files * 100:.1f}%)")
    print(f"Failed: {failed} ({failed / total_files * 100:.1f}%)")
    print(f"Completed at: {datetime.now()}")

    # Generate timestamp for file names
    timestamp_str = datetime.now().strftime("%Y%m%d_%H%M%S")

    # Write success audit log
    if successes:
        success_log_file = f"success_audit_{timestamp_str}.json"
        with open(success_log_file, "w") as f:
            json.dump(
                {"timestamp": datetime.now().isoformat(), "total_successful": len(successes), "successes": successes},
                f,
                indent=2,
            )
        print(f"\nSuccess audit log written to: {success_log_file}")

    # Write error log if there were failures
    if errors:
        error_log_file = f"errors_{timestamp_str}.json"
        with open(error_log_file, "w") as f:
            json.dump(
                {"timestamp": datetime.now().isoformat(), "total_errors": len(errors), "errors": errors}, f, indent=2
            )
        print(f"Error details written to: {error_log_file}")

    # Write processing summary
    summary_file = f"processing_summary_{timestamp_str}.json"
    with open(summary_file, "w") as f:
        json.dump(
            {
                "timestamp": datetime.now().isoformat(),
                "endpoint": ENDPOINT_URL,
                "input_file": INPUT_FILE,
                "total_files": total_files,
                "successful": successful,
                "failed": failed,
                "success_rate": f"{successful / total_files * 100:.1f}%",
                "errors_count": len(errors),
                "output_files": {
                    "success_audit": success_log_file if successes else None,
                    "error_log": error_log_file if errors else None,
                },
            },
            f,
            indent=2,
        )
    print(f"Processing summary written to: {summary_file}")


if __name__ == "__main__":
    main()
