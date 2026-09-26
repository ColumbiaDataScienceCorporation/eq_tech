"""
lib.db.postgres – SQLAlchemy engine and session management for PostgreSQL.

Provides a module-level engine singleton and a context-manager session factory.
Connection pool settings are tuned for AKS pod workloads (short-lived processes
that may share a node).

Usage:
    from lib.db.postgres import get_db_session

    with get_db_session() as session:
        rows = session.execute(text("SELECT 1")).fetchall()
"""

from contextlib import contextmanager
from typing import Generator

from sqlalchemy import create_engine, text, Engine
from sqlalchemy.orm import sessionmaker, Session

from lib.config.settings import get_settings

_engine: Engine | None = None
_SessionLocal: sessionmaker | None = None


def get_engine() -> Engine:
    """Return the shared SQLAlchemy engine, creating it on first call."""
    global _engine
    if _engine is None:
        settings = get_settings()
        _engine = create_engine(
            settings.postgres_url,
            pool_size=5,
            max_overflow=10,
            pool_timeout=30,
            pool_recycle=1800,   # recycle connections every 30 min (Azure drops idle ones)
            pool_pre_ping=True,  # validate the connection before use
            echo=settings.log_level == "DEBUG",
        )
    return _engine


def get_session_factory() -> sessionmaker:
    global _SessionLocal
    if _SessionLocal is None:
        _SessionLocal = sessionmaker(
            bind=get_engine(),
            autocommit=False,
            autoflush=False,
            expire_on_commit=False,
        )
    return _SessionLocal


@contextmanager
def get_db_session() -> Generator[Session, None, None]:
    """
    Context manager yielding a SQLAlchemy Session.
    Commits on success, rolls back on any exception, always closes.

    Example:
        with get_db_session() as session:
            session.add(MyModel(...))
    """
    factory = get_session_factory()
    session: Session = factory()
    try:
        yield session
        session.commit()
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()


def health_check() -> bool:
    """Return True if the PostgreSQL database is reachable. Safe to call from /healthz."""
    try:
        with get_engine().connect() as conn:
            conn.execute(text("SELECT 1"))
        return True
    except Exception:
        return False
