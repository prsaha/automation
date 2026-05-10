"""
Logging configuration module for Celigo NetSuite GCS Worker.

This module provides structured JSON logging optimized for Google Cloud Run.
"""

import json
import logging
from datetime import datetime, timezone

from config import config


class CloudRunFormatter(logging.Formatter):
    """Custom formatter for structured JSON logging in Google Cloud Run."""

    def format(self, record):
        """Format log record as JSON with Cloud Run compatible fields."""
        log_obj = {
            "severity": record.levelname,
            "message": record.getMessage(),
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }

        # Add any extra fields, excluding standard logging fields
        excluded_fields = {
            "name",
            "msg",
            "args",
            "created",
            "filename",
            "funcName",
            "levelname",
            "levelno",
            "lineno",
            "module",
            "msecs",
            "pathname",
            "process",
            "processName",
            "relativeCreated",
            "thread",
            "threadName",
            "exc_info",
            "exc_text",
            "stack_info",
            "getMessage",
        }

        for key, value in record.__dict__.items():
            if key not in excluded_fields:
                log_obj[key] = value

        return json.dumps(log_obj)


def get_logger(name: str) -> logging.Logger:
    """
    Get a configured logger instance.

    Args:
        name: Logger name (typically __name__)

    Returns:
        Configured logger instance
    """
    handler = logging.StreamHandler()
    handler.setFormatter(CloudRunFormatter())

    logger = logging.getLogger(name)
    logger.addHandler(handler)
    logger.setLevel(getattr(logging, config.LOG_LEVEL.upper()))
    logger.propagate = False

    return logger
