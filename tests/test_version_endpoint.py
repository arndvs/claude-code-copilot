"""Tests for version_endpoint — /health/version route logic.

Covers:
- get_version_info() returns correct dict from env vars
- git rev-parse fallback when BUILD_SHA is unset
- 'unknown' fallback when both env and git are unavailable
- mount_version_endpoint() registers the route on the FastAPI app
"""

from __future__ import annotations

import os
import sys
from unittest.mock import patch, MagicMock

sys.path.insert(0, ".")
from version_endpoint import get_version_info, mount_version_endpoint


# ===================================================================
# get_version_info — unit tests
# ===================================================================


class TestGetVersionInfoFromEnv:
    """When env vars are set, they should be reflected in the response."""

    def test_sha_from_env(self):
        with patch.dict(os.environ, {"BUILD_SHA": "abc1234", "BUILD_TIMESTAMP": "2024-01-01T00:00:00Z"}):
            info = get_version_info()
        assert info["sha"] == "abc1234"

    def test_built_at_from_env(self):
        with patch.dict(os.environ, {"BUILD_SHA": "abc1234", "BUILD_TIMESTAMP": "2024-01-01T00:00:00Z"}):
            info = get_version_info()
        assert info["built_at"] == "2024-01-01T00:00:00Z"

    def test_response_has_exactly_two_keys(self):
        with patch.dict(os.environ, {"BUILD_SHA": "abc1234", "BUILD_TIMESTAMP": "2024-01-01T00:00:00Z"}):
            info = get_version_info()
        assert set(info.keys()) == {"sha", "built_at"}


class TestGetVersionInfoGitFallback:
    """When BUILD_SHA env is unset/empty, fall back to git rev-parse --short HEAD."""

    def test_sha_falls_back_to_git(self):
        with patch.dict(os.environ, {"BUILD_TIMESTAMP": "2024-01-01T00:00:00Z"}, clear=False):
            env = os.environ.copy()
            env.pop("BUILD_SHA", None)
            with patch.dict(os.environ, env, clear=True):
                with patch("version_endpoint.subprocess.run") as mock_run:
                    mock_run.return_value = MagicMock(
                        returncode=0,
                        stdout="deadbee\n",
                    )
                    info = get_version_info()
        assert info["sha"] == "deadbee"

    def test_sha_unknown_when_git_fails(self):
        """When env is unset and git rev-parse fails, sha should be 'unknown'."""
        env = os.environ.copy()
        env.pop("BUILD_SHA", None)
        with patch.dict(os.environ, env, clear=True):
            with patch("version_endpoint.subprocess.run") as mock_run:
                mock_run.side_effect = Exception("git not found")
                info = get_version_info()
        assert info["sha"] == "unknown"

    def test_sha_unknown_when_env_is_literal_unknown(self):
        """The Dockerfile default 'unknown' should trigger git fallback."""
        with patch.dict(os.environ, {"BUILD_SHA": "unknown", "BUILD_TIMESTAMP": "ts"}):
            with patch("version_endpoint.subprocess.run") as mock_run:
                mock_run.return_value = MagicMock(returncode=0, stdout="face123\n")
                info = get_version_info()
        # When env is 'unknown', we try git; if git works, use it
        assert info["sha"] == "face123"


class TestGetVersionInfoBuildTimestamp:
    """When BUILD_TIMESTAMP env is unset, built_at should be 'unknown'."""

    def test_built_at_unknown_when_env_unset(self):
        env = os.environ.copy()
        env.pop("BUILD_TIMESTAMP", None)
        with patch.dict(os.environ, env, clear=True):
            with patch.dict(os.environ, {"BUILD_SHA": "abc1234"}):
                info = get_version_info()
        assert info["built_at"] == "unknown"

    def test_built_at_unknown_when_env_is_literal_unknown(self):
        """The Dockerfile default 'unknown' for BUILD_TIMESTAMP stays as 'unknown'."""
        with patch.dict(os.environ, {"BUILD_SHA": "abc1234", "BUILD_TIMESTAMP": "unknown"}):
            info = get_version_info()
        assert info["built_at"] == "unknown"


# ===================================================================
# mount_version_endpoint — integration test
# ===================================================================


class TestMountVersionEndpoint:
    """mount_version_endpoint() should register a GET /health/version route."""

    def test_registers_route_on_app(self):
        """After calling mount_version_endpoint, the app should have /health/version."""
        from fastapi import FastAPI
        from fastapi.testclient import TestClient

        app = FastAPI()

        with patch("version_endpoint._get_app", return_value=app):
            mount_version_endpoint()

        client = TestClient(app)
        with patch.dict(os.environ, {"BUILD_SHA": "test123", "BUILD_TIMESTAMP": "2024-06-01T12:00:00Z"}):
            resp = client.get("/health/version")

        assert resp.status_code == 200
        assert resp.headers["content-type"].startswith("application/json"), (
            f"Expected application/json content-type, got: {resp.headers['content-type']}"
        )
        data = resp.json()
        assert data["sha"] == "test123"
        assert data["built_at"] == "2024-06-01T12:00:00Z"

    def test_no_auth_required(self):
        """The /health/version endpoint should not require Authorization header."""
        from fastapi import FastAPI
        from fastapi.testclient import TestClient

        app = FastAPI()

        with patch("version_endpoint._get_app", return_value=app):
            mount_version_endpoint()

        client = TestClient(app)
        with patch.dict(os.environ, {"BUILD_SHA": "noauth", "BUILD_TIMESTAMP": "ts"}):
            # No Authorization header
            resp = client.get("/health/version")

        assert resp.status_code == 200
        assert resp.json()["sha"] == "noauth"
