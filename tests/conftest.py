"""Shared fixtures for the test suite."""
import os
import sys

import pytest

# Ensure repo root and app directories are on the path for all tests
_ROOT = os.path.dirname(os.path.dirname(__file__))
for _p in [_ROOT, os.path.join(_ROOT, "apps", "api"), os.path.join(_ROOT, "apps", "ui-dash")]:
    if _p not in sys.path:
        sys.path.insert(0, _p)


@pytest.fixture(autouse=True)
def reset_settings():
    """Reset the settings singleton before each test so env var changes take effect."""
    import lib.config.settings as _s
    _s._settings = None
    yield
    _s._settings = None


@pytest.fixture(autouse=True)
def default_env(monkeypatch):
    """Ensure EQTECH_ENVIRONMENT is set to dev for every test unless overridden."""
    monkeypatch.setenv("EQTECH_ENVIRONMENT", "dev")
