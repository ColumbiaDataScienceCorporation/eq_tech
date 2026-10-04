"""
Run all app import tests before deploying.
Usage: python scripts/test_imports.py
       (activate .venv first or run via .venv/Scripts/python)
"""
import os
import sys

os.environ.setdefault("EQTECH_ENVIRONMENT", "dev")
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))          # repo root
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(__file__)), "apps", "api"))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(__file__)), "apps", "ui-dash"))

TESTS = [
    ("lib.auth.groups",        "from lib.auth.groups import require_groups, FlaskGroupAuth"),
    ("lib.config.settings",    "from lib.config.settings import get_settings; get_settings()"),
    ("lib.db.postgres",        "from lib.db.postgres import get_db_session"),
    ("lib.logging.structured", "from lib.logging.structured import get_logger; get_logger('test')"),
    ("lib.portfolio.metrics",  "from lib.portfolio.metrics import compute_sharpe_ratio"),
    ("lib.market_data.client", "from lib.market_data.client import CsvMarketDataClient"),
    ("lib.storage.azure_blob", "from lib.storage.azure_blob import get_container_client"),
    ("apps/api/main.py",       "import main as api_main"),
    ("apps/ui-dash/app.py",    "import app as dash_app"),
]

passed = failed = 0
for label, code in TESTS:
    try:
        exec(compile(code, "<import-test>", "exec"))  # noqa: S102
        print(f"  [OK]  {label}")
        passed += 1
    except Exception as e:
        print(f"  [XX]  {label}")
        print(f"        {type(e).__name__}: {e}")
        failed += 1

print(f"\n  {passed} passed  {failed} failed")
sys.exit(1 if failed else 0)
