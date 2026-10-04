"""
lib.logging.structured – JSON-structured logger for all EQ Tech services.

Produces machine-parseable log lines that Azure Monitor / Log Analytics can
ingest directly. Every log record includes timestamp, level, logger name,
message, and environment.

Usage:
    from lib.logging.structured import get_logger
    log = get_logger(__name__)
    log.info("Portfolio computed", portfolio_id="P001", num_positions=42)
"""

import json
import logging
import sys
from datetime import datetime, timezone
from typing import Any

from lib.config.settings import get_settings

# Fields that belong to LogRecord internals and should not be forwarded
_SKIP_FIELDS = frozenset(logging.LogRecord.__init__.__code__.co_varnames) | {
    "msg", "args", "exc_info", "exc_text", "stack_info",
    "created", "msecs", "relativeCreated", "thread", "threadName",
    "processName", "process", "taskName",
}


class _JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        entry: dict[str, Any] = {
            "timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "environment": get_settings().environment.value,
        }
        if record.exc_info:
            entry["exception"] = self.formatException(record.exc_info)
        # Forward any extra keyword arguments passed to the log call
        for key, value in record.__dict__.items():
            if key not in _SKIP_FIELDS and not key.startswith("_"):
                entry[key] = value
        return json.dumps(entry, default=str)


def get_logger(name: str) -> logging.Logger:
    """
    Return a named logger that emits JSON lines to stdout.
    The log level is resolved from Settings (DEBUG in dev, INFO elsewhere).
    Calling this multiple times with the same name is safe.
    """
    settings = get_settings()
    logger = logging.getLogger(name)

    if not logger.handlers:
        handler = logging.StreamHandler(sys.stdout)
        handler.setFormatter(_JsonFormatter())
        logger.addHandler(handler)
        logger.propagate = False

    logger.setLevel(settings.log_level.upper())
    return logger
