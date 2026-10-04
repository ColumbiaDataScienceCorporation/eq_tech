"""
lib.config – Environment-aware configuration and credential management.

Reads settings from environment variables (injected by Kubernetes secrets in
AKS, or from a .env file on the central dev server). All secrets are typed
as SecretStr so they are never printed accidentally in logs.

Usage:
    from lib.config.settings import get_settings
    s = get_settings()
    print(s.environment, s.postgres_url)
"""

from enum import Enum

from pydantic import SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Environment(str, Enum):
    DEV = "dev"
    UAT = "uat"
    PROD = "prod"


class Settings(BaseSettings):
    """
    Central settings class. All values map to environment variables with the
    EQTECH_ prefix (e.g. EQTECH_POSTGRES_HOST). A .env file is also loaded
    from the working directory when present (useful on the dev server).
    """

    model_config = SettingsConfigDict(
        env_prefix="EQTECH_",
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # ── Runtime environment ──────────────────────────────────────────────────
    environment: Environment = Environment.DEV

    # ── PostgreSQL (Azure Flexible Server) ───────────────────────────────────
    postgres_host: str = "eq-tech-pg.postgres.database.azure.com"
    postgres_port: int = 5432
    # If blank, auto-resolved from environment (airflow_dev / airflow_uat / airflow_prod)
    postgres_db: str = ""
    postgres_user: str = "airflow_admin"
    postgres_password: SecretStr = SecretStr("")
    postgres_ssl_mode: str = "require"

    # ── Snowflake ────────────────────────────────────────────────────────────
    snowflake_account: str = ""          # e.g. "xy12345.us-east-1"
    snowflake_user: str = ""
    snowflake_password: SecretStr = SecretStr("")
    snowflake_database: str = "EQ_TECH"
    snowflake_schema: str = "PUBLIC"
    snowflake_warehouse: str = "COMPUTE_WH"
    snowflake_role: str = "ANALYST"

    # ── Azure ────────────────────────────────────────────────────────────────
    azure_tenant_id: str = "e5e33b11-e89c-466a-bf06-e94151676845"
    azure_key_vault_url: str = ""        # e.g. "https://eq-tech-kv.vault.azure.net/"
    azure_storage_account: str = ""      # e.g. "eqtechdata"

    # ── Entra ID group Object IDs (from Entra ID → Groups) ──────────────────
    analysts_group_id: str = ""
    portfolio_managers_group_id: str = ""
    risk_group_id: str = ""
    admins_group_id: str = ""

    # ── Notifications ────────────────────────────────────────────────────────
    # Teams incoming webhook URL; leave blank to disable
    teams_webhook_url: str = ""

    # ── Application ──────────────────────────────────────────────────────────
    log_level: str = ""  # resolved in @model_validator below

    @field_validator("environment", mode="before")
    @classmethod
    def normalise_env(cls, v) -> str:
        # Enum default passes the Enum instance; extract .value so str(v) doesn't give 'Environment.DEV'
        if hasattr(v, "value"):
            return v.value
        return str(v).lower()

    @model_validator(mode="after")
    def set_defaults(self) -> "Settings":
        # Default log level: DEBUG in dev, INFO everywhere else
        if not self.log_level:
            self.log_level = "DEBUG" if self.environment == Environment.DEV else "INFO"
        return self

    # ── Computed properties ──────────────────────────────────────────────────

    @property
    def postgres_db_name(self) -> str:
        """Returns the environment-specific database name."""
        return self.postgres_db or f"airflow_{self.environment.value}"

    @property
    def postgres_url(self) -> str:
        """SQLAlchemy connection URL for the environment's PostgreSQL database."""
        pw = self.postgres_password.get_secret_value()
        return (
            f"postgresql+psycopg2://{self.postgres_user}:{pw}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db_name}"
            f"?sslmode={self.postgres_ssl_mode}"
        )

    @property
    def snowflake_url(self) -> str:
        """SQLAlchemy connection URL for Snowflake."""
        pw = self.snowflake_password.get_secret_value()
        return (
            f"snowflake://{self.snowflake_user}:{pw}@{self.snowflake_account}"
            f"/{self.snowflake_database}/{self.snowflake_schema}"
            f"?warehouse={self.snowflake_warehouse}&role={self.snowflake_role}"
        )

    @property
    def is_production(self) -> bool:
        return self.environment == Environment.PROD


# Module-level singleton – created once per process
_settings: Settings | None = None


def get_settings() -> Settings:
    """Return the cached Settings singleton. Thread-safe for read-after-init."""
    global _settings
    if _settings is None:
        _settings = Settings()
    return _settings


def override_settings(**kwargs) -> Settings:
    """Replace the singleton with a custom instance. Intended for tests only."""
    global _settings
    _settings = Settings(**kwargs)
    return _settings
