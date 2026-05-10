"""
Validation and sanitization utilities for Celigo NetSuite GCS Worker.

This module provides functions for validating and sanitizing user input
to ensure security and data integrity.
"""

from typing import Any, Dict

from config import config


def sanitize_request_for_logging(request_data: Dict[str, Any]) -> Dict[str, Any]:
    """
    Sanitize request data for safe logging by removing/masking sensitive fields.

    Args:
        request_data: The request JSON data to sanitize

    Returns:
        Sanitized copy safe for logging
    """
    if not request_data:
        return {}

    sanitized = request_data.copy()

    # Remove or mask potentially sensitive fields
    for key in list(sanitized.keys()):
        if any(sensitive in key.lower() for sensitive in config.sensitive_fields):
            sanitized[key] = "[REDACTED]"

    # For batch requests, sanitize file info but keep structure for debugging
    if "files" in sanitized and isinstance(sanitized["files"], list):
        sanitized_files = []
        for file_info in sanitized["files"][:10]:  # Limit to first 10 for logs
            if isinstance(file_info, dict):
                sanitized_file = {k: v for k, v in file_info.items()}
                # Keep useful debugging info but limit URL length
                if "fullUrl" in sanitized_file and len(str(sanitized_file["fullUrl"])) > 100:
                    url = str(sanitized_file["fullUrl"])
                    sanitized_file["fullUrl"] = url[:50] + "..." + url[-30:]
                sanitized_files.append(sanitized_file)
        sanitized["files"] = sanitized_files
        if len(request_data.get("files", [])) > 10:
            sanitized["files_truncated"] = f"... and {len(request_data['files']) - 10} more files"

    return sanitized


def sanitize_billing_account_id(billing_account_id: str) -> str:
    """
    Sanitize the billing account ID to prevent path traversal attacks.

    Expected format: two words separated by underscore (e.g., "surprisingly_zebra")
    If the format doesn't match, use a safe default.

    Args:
        billing_account_id: Raw billing account ID from request

    Returns:
        str: Sanitized billing account ID safe for use as a folder name
    """
    if not billing_account_id:
        return "unknown_billing_account_id"

    billing_account_id = billing_account_id.replace("..", "").replace("/", "").replace("\\", "")

    if config.BILLING_ACCOUNT_PATTERN.match(billing_account_id):
        return billing_account_id

    return "invalid_billing_account_format"
