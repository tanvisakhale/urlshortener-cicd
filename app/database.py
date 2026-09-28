"""
Database engine/session setup.

Configuration is entirely via environment variables so no credentials are
ever hard-coded. In production these are injected via Kubernetes Secrets
backed by AWS RDS PostgreSQL. For local/dev convenience (and for running
the unit test suite without needing a live Postgres instance), the app
falls back to a local SQLite file if DATABASE_HOST is not set.

Env vars (production/staging):
    DATABASE_HOST
    DATABASE_PORT
    DATABASE_NAME
    DATABASE_USER
    DATABASE_PASSWORD
"""
import os

from sqlalchemy import create_engine
from sqlalchemy.orm import declarative_base, sessionmaker


def _build_database_url() -> str:
    # Explicit full URL wins (useful for CI / one-off overrides).
    explicit_url = os.getenv("DATABASE_URL")
    if explicit_url:
        return explicit_url

    host = os.getenv("DATABASE_HOST")
    if not host:
        # No Postgres configured -> local/test fallback, never used in prod.
        return "sqlite:///./local_dev.db"

    port = os.getenv("DATABASE_PORT", "5432")
    name = os.getenv("DATABASE_NAME", "urlshortener")
    user = os.getenv("DATABASE_USER", "postgres")
    password = os.getenv("DATABASE_PASSWORD", "")

    return f"postgresql+psycopg2://{user}:{password}@{host}:{port}/{name}"


DATABASE_URL = _build_database_url()

connect_args = {"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {}

engine = create_engine(DATABASE_URL, connect_args=connect_args, pool_pre_ping=True)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def init_db() -> None:
    """Create tables if they don't exist. Called on app startup."""
    from app import models  # noqa: F401 (ensures models are registered)

    Base.metadata.create_all(bind=engine)
