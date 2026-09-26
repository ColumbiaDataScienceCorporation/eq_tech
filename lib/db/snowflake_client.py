"""
lib.db.snowflake_client – SQLAlchemy engine for Snowflake.

Requires the snowflake-sqlalchemy package.  The engine is created lazily so
that services that do not use Snowflake pay no import cost.

Usage:
    from lib.db.snowflake_client import get_snowflake_engine
    import pandas as pd

    df = pd.read_sql("SELECT * FROM PRICES LIMIT 10", get_snowflake_engine())
"""

from sqlalchemy import create_engine, Engine

from lib.config.settings import get_settings

_engine: Engine | None = None


def get_snowflake_engine() -> Engine:
    """Return the shared Snowflake SQLAlchemy engine."""
    global _engine
    if _engine is None:
        settings = get_settings()
        if not settings.snowflake_account:
            raise RuntimeError(
                "EQTECH_SNOWFLAKE_ACCOUNT is not configured. "
                "Set it as an environment variable or in .env."
            )
        _engine = create_engine(
            settings.snowflake_url,
            pool_size=2,
            max_overflow=4,
            pool_pre_ping=True,
        )
    return _engine
