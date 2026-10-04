"""Tests for apps/ui-dash."""


def test_dash_app_imports():
    """The dash app module must import without error."""
    import importlib

    import app as dash_app
    importlib.reload(dash_app)
    assert hasattr(dash_app, "app")


def test_dash_app_has_server():
    """Gunicorn needs app.server to exist."""
    import app as dash_app
    assert hasattr(dash_app.app, "server")
