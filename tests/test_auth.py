"""Tests for lib.auth.groups."""
import pytest


def test_require_groups_importable():
    from lib.auth.groups import require_groups
    assert callable(require_groups)


def test_flask_group_auth_importable():
    from lib.auth.groups import FlaskGroupAuth
    assert FlaskGroupAuth is not None


def test_flask_imports_are_optional(monkeypatch):
    """Groups module must import even when flask is absent (API container has no flask)."""
    import importlib
    import lib.auth.groups as mod
    # Verify the module already loaded without error
    assert hasattr(mod, "FlaskGroupAuth")
    assert hasattr(mod, "require_groups")


def test_parse_groups():
    from lib.auth.groups import parse_groups
    result = parse_groups("abc-123, def-456 , , ghi-789")
    assert result == ["abc-123", "def-456", "ghi-789"]


def test_parse_groups_empty():
    from lib.auth.groups import parse_groups
    assert parse_groups("") == []
    assert parse_groups("  ,  ") == []
