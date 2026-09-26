"""
lib.notifications.teams – Microsoft Teams webhook alert sender.

Send structured alerts to a Teams channel via an incoming webhook.
Alerts are silenced automatically in the dev environment to prevent
developers from spamming production channels.

Usage:
    from lib.notifications.teams import alert_dag_failure, send_alert

    send_alert("Risk Pipeline Failed", "VaR breached threshold", severity="error")
"""

import json
import urllib.request
from urllib.error import URLError

from lib.config.settings import Environment, get_settings
from lib.logging.structured import get_logger

log = get_logger(__name__)

_COLOURS = {"info": "0078D7", "warning": "FFA500", "error": "FF0000", "success": "28A745"}


def send_alert(
    title: str,
    message: str,
    severity: str = "info",
    webhook_url: str | None = None,
) -> None:
    """
    Post a card to a Teams channel via webhook.

    Does nothing and logs a debug message when:
      - webhook_url is blank and EQTECH_TEAMS_WEBHOOK_URL is not set
      - the environment is DEV (avoids noisy dev alerts in production channels)
    """
    settings = get_settings()
    url = webhook_url or settings.teams_webhook_url

    if not url:
        log.debug("Teams webhook not configured – alert suppressed", title=title)
        return

    if settings.environment == Environment.DEV:
        log.debug("Teams alerts disabled in dev", title=title, message=message)
        return

    env_label = settings.environment.value.upper()
    payload = {
        "@type": "MessageCard",
        "@context": "https://schema.org/extensions",
        "themeColor": _COLOURS.get(severity, "0078D7"),
        "summary": f"[{env_label}] {title}",
        "sections": [{
            "activityTitle": f"[{env_label}] {title}",
            "activityText": message,
            "facts": [{"name": "Severity", "value": severity.capitalize()}],
        }],
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            log.info("Teams alert sent", title=title, http_status=resp.status)
    except (URLError, OSError) as exc:
        # Notification failure must never break business logic
        log.error("Teams alert failed", title=title, error=str(exc))


def alert_dag_failure(dag_id: str, run_id: str, task_id: str) -> None:
    """Convenience wrapper for Airflow DAG failure callbacks."""
    send_alert(
        title=f"Airflow DAG Failure: {dag_id}",
        message=f"Run `{run_id}` — task `{task_id}` failed.",
        severity="error",
    )


def alert_risk_breach(portfolio_id: str, metric: str, value: float, limit: float) -> None:
    """Convenience wrapper for risk limit breach notifications."""
    send_alert(
        title=f"Risk Limit Breach: {portfolio_id}",
        message=(
            f"Portfolio **{portfolio_id}** breached the **{metric}** limit. "
            f"Current: {value:.4f}, Limit: {limit:.4f}"
        ),
        severity="error",
    )
