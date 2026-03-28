"""Structured JSON logging for production.

Usage:
    from app.logging_config import setup_logging
    setup_logging("INFO")  # Call once at startup
"""

from __future__ import annotations

import json
import logging
import sys


class JSONFormatter(logging.Formatter):
    """Emit log records as single-line JSON objects."""

    def format(self, record: logging.LogRecord) -> str:
        return json.dumps({
            "ts": record.created,
            "level": record.levelname,
            "module": record.module,
            "msg": record.getMessage(),
        }, ensure_ascii=False)


def setup_logging(level: str = "INFO") -> None:
    """Configure root logger with JSON output to stdout."""
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JSONFormatter())
    logging.root.handlers = [handler]
    logging.root.setLevel(getattr(logging, level.upper(), logging.INFO))
