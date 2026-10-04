"""Tests for lib.logging.structured."""


def test_get_logger_returns_structured_logger():
    from lib.logging.structured import StructuredLogger, get_logger
    log = get_logger("test")
    assert isinstance(log, StructuredLogger)


def test_logger_info_no_kwargs():
    from lib.logging.structured import get_logger
    log = get_logger("test.plain")
    log.info("plain message")  # must not raise


def test_logger_info_with_kwargs():
    from lib.logging.structured import get_logger
    log = get_logger("test.kwargs")
    log.info("structured message", portfolio_id="P001", count=42)  # must not raise


def test_logger_warning_with_kwargs():
    from lib.logging.structured import get_logger
    log = get_logger("test.warning")
    log.warning("something went wrong", error="details here")  # must not raise


def test_logger_error_with_exc_info():
    from lib.logging.structured import get_logger
    log = get_logger("test.exc")
    try:
        raise ValueError("test")
    except ValueError:
        log.exception("caught error", context="test_suite")  # must not raise
