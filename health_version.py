"""health_version.py — /health/version endpoint for the LiteLLM proxy.

Returns the git commit SHA and build timestamp baked in at Docker build time.
No auth required (same as /health/readiness).

Registered as a LiteLLM callback in litellm_config.yaml. At import time, the
module attaches its router to the proxy's FastAPI app. The endpoint is then
available alongside /health/readiness with no auth.

The ``version_callback_instance`` export is a no-op CustomLogger — its only
purpose is to give litellm_config.yaml a valid callback reference so the proxy
imports this module at startup (which triggers ``_register_router``).

Environment variables (set as Docker build ARGs → ENV):
  BUILD_SHA        — 7-char git commit SHA (default: "unknown")
  BUILD_TIMESTAMP  — ISO 8601 build time (default: "unknown")
"""

from __future__ import annotations

import os

from fastapi import APIRouter

try:
    from litellm.integrations.custom_logger import CustomLogger
except Exception:  # pragma: no cover
    class CustomLogger:  # type: ignore[no-redef]
        """Fallback base so importing this module never fails outside the proxy."""


custom_api_router = APIRouter()


def get_version() -> dict:
    """Return version info from build-time environment variables."""
    return {
        "sha": os.environ.get("BUILD_SHA", "unknown"),
        "built_at": os.environ.get("BUILD_TIMESTAMP", "unknown"),
    }


@custom_api_router.get("/health/version")
async def health_version():
    """Return build version info. No auth required."""
    return get_version()


def _register_router():
    """Attach custom_api_router to the LiteLLM proxy app, if available.

    Called at module import time. Fails silently when imported outside the
    proxy context (e.g. during tests or standalone use).
    """
    try:
        from litellm.proxy.proxy_server import app  # noqa: WPS433

        app.include_router(custom_api_router)
    except Exception:
        pass


_register_router()


class _VersionCallbackNoop(CustomLogger):
    """No-op callback — exists only so litellm imports this module at startup."""

    pass


version_callback_instance = _VersionCallbackNoop()
