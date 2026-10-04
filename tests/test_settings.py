"""Tests for lib.config.settings."""
import os

import pytest


def test_settings_load_with_no_env_vars(monkeypatch):
    """Settings must load even when EQTECH_* vars are absent (bare container)."""
    for key in list(os.environ):
        if key.startswith("EQTECH_"):
            monkeypatch.delenv(key, raising=False)
    from lib.config.settings import Environment, get_settings
    s = get_settings()
    assert s.environment == Environment.DEV


def test_settings_environment_from_string(monkeypatch):
    monkeypatch.setenv("EQTECH_ENVIRONMENT", "uat")
    from lib.config.settings import Environment, get_settings
    s = get_settings()
    assert s.environment == Environment.UAT


def test_settings_environment_case_insensitive(monkeypatch):
    monkeypatch.setenv("EQTECH_ENVIRONMENT", "PROD")
    from lib.config.settings import Environment, get_settings
    s = get_settings()
    assert s.environment == Environment.PROD


def test_settings_invalid_environment_raises(monkeypatch):
    monkeypatch.setenv("EQTECH_ENVIRONMENT", "staging")
    from lib.config.settings import get_settings
    with pytest.raises(Exception):
        get_settings()
