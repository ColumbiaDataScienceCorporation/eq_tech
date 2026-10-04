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


def get_logger(name: str) -> "StructuredLogger":
    """
    Return a named logger that emits JSON lines to stdout.
    Accepts arbitrary keyword arguments as structured fields:
        log.info("msg", portfolio_id="P001", count=42)
    """
    settings = get_settings()
    _inner = logging.getLogger(name)

    if not _inner.handlers:
        handler = logging.StreamHandler(sys.stdout)
        handler.setFormatter(_JsonFormatter())
        _inner.addHandler(handler)
        _inner.propagate = False

    _inner.setLevel(settings.log_level.upper())
    return StructuredLogger(_inner)


class StructuredLogger:
    """Thin wrapper so callers can pass extra fields as kwargs rather than extra={}."""

    def __init__(self, logger: logging.Logger) -> None:
        self._log = logger

    def _emit(self, level: int, msg: str, *args: Any, **kwargs: Any) -> None:
        exc_info = kwargs.pop("exc_info", None)
        stack_info = kwargs.pop("stack_info", False)
        self._log.log(level, msg, *args, exc_info=exc_info, stack_info=stack_info,
                      extra=kwargs or None, stacklevel=2)

    def debug(self, msg: str, *args: Any, **kwargs: Any) -> None:
        self._emit(logging.DEBUG, msg, *args, **kwargs)

    def info(self, msg: str, *args: Any, **kwargs: Any) -> None:
        self._emit(logging.INFO, msg, *args, **kwargs)

    def warning(self, msg: str, *args: Any, **kwargs: Any) -> None:
        self._emit(logging.WARNING, msg, *args, **kwargs)

    def error(self, msg: str, *args: Any, **kwargs: Any) -> None:
        self._emit(logging.ERROR, msg, *args, **kwargs)

    def exception(self, msg: str, *args: Any, **kwargs: Any) -> None:
        kwargs["exc_info"] = True
        self._emit(logging.ERROR, msg, *args, **kwargs)
