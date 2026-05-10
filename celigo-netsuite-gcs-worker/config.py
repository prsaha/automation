"""
Configuration module for Celigo NetSuite GCS Worker.

This module centralizes all configuration settings and environment variable
handling for the application.
"""

import os
import re
from typing import List

# Load environment variables from .env file for local development
try:
    from dotenv import load_dotenv

    load_dotenv()
except ImportError:
    pass


class Config:
    """Application configuration loaded from environment variables."""

    # Logging configuration
    LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")
    LOG_SUCCESSFUL_RESPONSES = os.environ.get("LOG_SUCCESSFUL_RESPONSES", "true").lower() == "true"
    LOG_RESPONSE_DETAILS = os.environ.get("LOG_RESPONSE_DETAILS", "false").lower() == "true"

    # GCS configuration
    DESTINATION_BUCKET = os.environ.get("DESTINATION_BUCKET")
    GCP_PROJECT = os.environ.get("GCP_PROJECT")

    # Authentication
    AUTHORIZED_TOKENS_STR = os.environ.get("AUTHORIZED_TOKENS")

    # NetSuite configuration
    ALLOWED_NETSUITE_HOST = os.environ.get("ALLOWED_NETSUITE_HOST", "https://5260239.app.netsuite.com")

    # Validation patterns
    BILLING_ACCOUNT_PATTERN = re.compile(r"^[a-zA-Z0-9]+(_[a-zA-Z0-9]+){0,3}$")

    def __init__(self):
        """Initialize configuration and validate required settings."""
        self._validate_required_settings()
        self._parse_authorized_tokens()

    def _validate_required_settings(self):
        """Validate that all required environment variables are set."""
        if not self.DESTINATION_BUCKET:
            raise ValueError("No destination bucket environment variable found. Set DESTINATION_BUCKET.")

        if not self.AUTHORIZED_TOKENS_STR:
            raise ValueError("No authorized tokens environment variable found. Set AUTHORIZED_TOKENS.")

    def _parse_authorized_tokens(self):
        """Parse the comma-separated list of authorized tokens."""
        self.VALID_TOKENS: List[str] = [token.strip() for token in self.AUTHORIZED_TOKENS_STR.split(",")]

    @property
    def sensitive_fields(self) -> List[str]:
        """List of field names that should be redacted in logs."""
        return ["authorization", "token", "password", "secret", "key", "auth"]


# Create global config instance
config = Config()
