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

When BUILD_SHA is unset or "unknown" (e.g. local ``make start``), the module
falls back to ``git rev-parse --short HEAD`` so local dev always returns a
meaningful SHA rather than the literal string "unknown".
"""

from __future__ import annotations

import os
import subprocess

from fastapi import APIRouter

try:
    from litellm.integrations.custom_logger import CustomLogger
except Exception:  # pragma: no cover
    class CustomLogger:  # type: ignore[no-redef]
        """Fallback base so importing this module never fails outside the proxy."""


custom_api_router = APIRouter()

# Directory of this file — used as cwd for git fallback so it works regardless
# of the process working directory.
_MODULE_DIR = os.path.dirname(os.path.abspath(__file__))


def _git_sha_fallback() -> str:
    """Try ``git rev-parse --short HEAD``; return 'unknown' on any failure."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
            cwd=_MODULE_DIR,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except Exception:
        pass
    return "unknown"


def get_version() -> dict:
    """Return version info from build-time env vars, with a git fallback."""
    sha = os.environ.get("BUILD_SHA", "").strip()
    # Fall back to live git when env is missing or is the Dockerfile default.
    if not sha or sha == "unknown":
        sha = _git_sha_fallback()
    # Spec requires a 7-char short SHA; trim uniformly (env var or git fallback).
    # git rev-parse --short can return more than 7 chars in large repos.
    if sha != "unknown" and len(sha) > 7:
        sha = sha[:7]
    built_at = os.environ.get("BUILD_TIMESTAMP", "").strip()
    if not built_at or built_at == "unknown":
        built_at = "unknown"
    return {
        "sha": sha,
        "built_at": built_at,
    }


@custom_api_router.get("/health/version")
async def health_version():
    """Return build version info. No auth required."""
    return get_version()


_router_registered = False


def _register_router():
    """Attach custom_api_router to the LiteLLM proxy app, if available.

    Called at module import time. Idempotent — safe to call multiple times
    (e.g. during tests that import the module more than once).
    Fails silently when imported outside the proxy context.
    """
    global _router_registered
    if _router_registered:
        return
    try:
        from litellm.proxy.proxy_server import app  # noqa: WPS433

        app.include_router(custom_api_router)
        _router_registered = True
    except Exception:
        pass


_register_router()


class _VersionCallbackNoop(CustomLogger):
    """No-op callback — exists only so litellm imports this module at startup."""

    pass


version_callback_instance = _VersionCallbackNoop()
