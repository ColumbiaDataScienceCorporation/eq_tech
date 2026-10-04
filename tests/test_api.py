"""Tests for apps/api."""
import os
from unittest.mock import patch

import pytest


@pytest.fixture
def client():
    from fastapi.testclient import TestClient
    # Patch init_db so we don't need a real database
    with patch("apps.api.main.init_db"):
        import importlib
        import apps.api.main as api_mod
        importlib.reload(api_mod)
        yield TestClient(api_mod.app)


def test_healthz_returns_200(client):
    with patch("apps.api.main.pg_health", return_value=False):
        resp = client.get("/healthz")
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "healthy"
    assert "db" in data


def test_healthz_db_ok_when_pg_healthy(client):
    with patch("apps.api.main.pg_health", return_value=True):
        resp = client.get("/healthz")
    assert resp.json()["db"] == "ok"


def test_healthz_db_unreachable_when_pg_down(client):
    with patch("apps.api.main.pg_health", return_value=False):
        resp = client.get("/healthz")
    assert resp.json()["db"] == "unreachable"


def test_startup_does_not_crash_when_db_unavailable():
    """Startup must not raise even if init_db fails (no PG password in pod)."""
    from sqlalchemy.exc import OperationalError
    with patch("apps.api.main.init_db", side_effect=OperationalError("no password", None, None)):
        import importlib
        import apps.api.main as api_mod
        importlib.reload(api_mod)
        from fastapi.testclient import TestClient
        client = TestClient(api_mod.app)
        resp = client.get("/healthz")
    assert resp.status_code == 200
