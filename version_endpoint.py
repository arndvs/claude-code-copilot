"""version_endpoint.py — /health/version route for the LiteLLM proxy.

Exposes build metadata (git SHA + build timestamp) as a JSON endpoint so
operators can confirm which version is deployed without SSH access.

Integration:
  Set LITELLM_WORKER_STARTUP_HOOKS=version_endpoint:mount_version_endpoint
  in the environment (Dockerfile ENV or start_proxy.sh) so the route is
  registered when the proxy starts.

Environment variables consumed:
  GIT_SHA           — baked at docker build via --build-arg (default: 'unknown')
  BUILD_TIMESTAMP   — baked at docker build via --build-arg (default: 'unknown')

When GIT_SHA is unset or 'unknown', the endpoint falls back to
`git rev-parse --short HEAD` for local development.
"""

from __future__ import annotations

import os
import subprocess

from fastapi import FastAPI
from fastapi.responses import JSONResponse


# Directory of this file — used as cwd for git fallback so it works regardless
# of the process working directory.
_MODULE_DIR = os.path.dirname(os.path.abspath(__file__))


def get_version_info() -> dict:
    """Return {"sha": "...", "built_at": "..."} from env vars or git fallback."""
    sha = os.environ.get("GIT_SHA", "").strip()

    # Fall back to live git if env is missing or is the Dockerfile default
    if not sha or sha == "unknown":
        sha = _git_sha_fallback()

    built_at = os.environ.get("BUILD_TIMESTAMP", "").strip()
    if not built_at:
        built_at = "unknown"

    return {"sha": sha, "built_at": built_at}


def _git_sha_fallback() -> str:
    """Try `git rev-parse --short HEAD`; return 'unknown' on any failure."""
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


def _get_app() -> FastAPI:
    """Import the live LiteLLM proxy FastAPI app instance.

    Isolated into a helper so tests can patch it with a test app.
    """
    from litellm.proxy.proxy_server import app  # type: ignore[import]

    return app


def mount_version_endpoint() -> None:
    """Register GET /health/version on the proxy's FastAPI app.

    Called as a LITELLM_WORKER_STARTUP_HOOKS entry point:
      LITELLM_WORKER_STARTUP_HOOKS=version_endpoint:mount_version_endpoint
    """
    app = _get_app()

    @app.get("/health/version", tags=["health"])
    async def health_version():
        """Return build version metadata. No auth required."""
        return JSONResponse(content=get_version_info())
