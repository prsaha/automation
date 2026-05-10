"""
Authentication utilities for Celigo NetSuite GCS Worker.

This module provides functions for authenticating incoming requests
using bearer token authentication.
"""

from typing import Optional

from config import config
from logging_config import get_logger

logger = get_logger(__name__)


def authenticate_request(request, request_id: Optional[str] = None) -> bool:
    """
    Verifies that the request contains a valid bearer token.

    Args:
        request: HTTP request object
        request_id: Optional request ID for logging correlation

    Returns:
        bool: True if authentication succeeds, False otherwise
    """
    auth_header = request.headers.get("Authorization", "")

    if not auth_header.startswith("Bearer "):
        logger.warning(
            f"[{request_id}] Auth failed: Missing/invalid Authorization header.",
            extra={
                "request_id": request_id,
                "remote_addr": request.remote_addr,
                "user_agent": request.headers.get("User-Agent"),
                "auth_header_present": bool(auth_header),
                "auth_header_prefix": auth_header[:20] if auth_header else None,
            },
        )
        return False

    token = auth_header.split("Bearer ")[1].strip()
    if not token:
        logger.warning(
            f"[{request_id}] Auth failed: Empty bearer token.",
            extra={
                "request_id": request_id,
                "remote_addr": request.remote_addr,
                "user_agent": request.headers.get("User-Agent"),
                "auth_header_length": len(auth_header),
            },
        )
        return False

    if token in config.VALID_TOKENS:
        return True
    else:
        logger.warning(
            f"[{request_id}] Auth failed: Invalid bearer token.",
            extra={
                "request_id": request_id,
                "remote_addr": request.remote_addr,
                "user_agent": request.headers.get("User-Agent"),
                "token_length": len(token),
                "token_prefix": token[:8] if len(token) >= 8 else token[:4],
                "valid_token_count": len(config.VALID_TOKENS),
            },
        )
        return False
