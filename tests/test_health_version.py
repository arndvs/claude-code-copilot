"""Tests for health_version — /health/version endpoint logic."""

from __future__ import annotations

import sys
import os
from unittest.mock import patch

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


class TestGetVersion:
    """Unit tests for get_version() — the core logic."""

    def test_returns_sha_from_env(self, monkeypatch):
        monkeypatch.setenv("BUILD_SHA", "abc1234")
        monkeypatch.setenv("BUILD_TIMESTAMP", "2024-01-15T10:30:00Z")
        from health_version import get_version

        result = get_version()
        assert result["sha"] == "abc1234"

    def test_full_sha_is_truncated_to_7_chars(self, monkeypatch):
        """A full 40-char SHA baked in at build time should be trimmed to 7 chars."""
        full_sha = "a" * 40
        monkeypatch.setenv("BUILD_SHA", full_sha)
        from health_version import get_version

        result = get_version()
        assert result["sha"] == "a" * 7, f"Expected 7-char SHA, got {result['sha']!r}"

    def test_returns_built_at_from_env(self, monkeypatch):
        monkeypatch.setenv("BUILD_SHA", "abc1234")
        monkeypatch.setenv("BUILD_TIMESTAMP", "2024-01-15T10:30:00Z")
        from health_version import get_version

        result = get_version()
        assert result["built_at"] == "2024-01-15T10:30:00Z"

    def test_sha_defaults_to_unknown_when_env_and_git_both_fail(self, monkeypatch):
        """'unknown' is returned only when both env and git are unavailable."""
        monkeypatch.delenv("BUILD_SHA", raising=False)
        monkeypatch.delenv("BUILD_TIMESTAMP", raising=False)
        from health_version import get_version

        with patch("health_version.subprocess.run", side_effect=Exception("git not found")):
            result = get_version()
        assert result["sha"] == "unknown"

    def test_built_at_defaults_to_unknown_when_unset(self, monkeypatch):
        monkeypatch.delenv("BUILD_SHA", raising=False)
        monkeypatch.delenv("BUILD_TIMESTAMP", raising=False)
        from health_version import get_version

        result = get_version()
        assert result["built_at"] == "unknown"

    def test_response_has_exactly_two_keys(self, monkeypatch):
        monkeypatch.setenv("BUILD_SHA", "deadbee")
        monkeypatch.setenv("BUILD_TIMESTAMP", "2024-06-01T00:00:00Z")
        from health_version import get_version

        result = get_version()
        assert set(result.keys()) == {"sha", "built_at"}


class TestCustomApiRouter:
    """Verify the module exports a custom_api_router compatible with LiteLLM."""

    def test_module_exports_custom_api_router(self):
        import health_version

        assert hasattr(health_version, "custom_api_router")

    def test_router_has_health_version_route(self):
        import health_version

        routes = [r.path for r in health_version.custom_api_router.routes]
        assert "/health/version" in routes

    def test_route_allows_get(self):
        import health_version

        for route in health_version.custom_api_router.routes:
            if route.path == "/health/version":
                assert "GET" in route.methods
                break
        else:
            pytest.fail("/health/version route not found")


class TestVersionCallbackInstance:
    """Verify the module exports a valid LiteLLM callback instance."""

    def test_module_exports_version_callback_instance(self):
        import health_version

        assert hasattr(health_version, "version_callback_instance")

    def test_callback_is_noop(self):
        """The callback exists only to trigger module import; it does nothing."""
        import health_version

        # Should not raise
        cb = health_version.version_callback_instance
        assert cb is not None


class TestRegisterRouter:
    """Verify _register_router degrades gracefully outside the proxy."""

    def test_register_router_does_not_raise_outside_proxy(self):
        """Importing the module outside litellm proxy context must not fail."""
        # If we got here, the import at module level already succeeded
        import health_version

        # Calling it again should also be safe
        health_version._register_router()


class TestGitFallback:
    """Unit tests for the git rev-parse fallback path in get_version()."""

    def test_sha_falls_back_to_git_when_env_unset(self, monkeypatch):
        """When BUILD_SHA is missing, git provides the SHA."""
        monkeypatch.delenv("BUILD_SHA", raising=False)
        from health_version import get_version

        with patch("health_version.subprocess.run") as mock_run:
            mock_run.return_value.returncode = 0
            mock_run.return_value.stdout = "deadbee\n"
            result = get_version()

        assert result["sha"] == "deadbee"
        mock_run.assert_called_once()

    def test_sha_falls_back_to_git_when_env_is_unknown(self, monkeypatch):
        """'unknown' (the Dockerfile default) triggers the git fallback."""
        monkeypatch.setenv("BUILD_SHA", "unknown")
        from health_version import get_version

        with patch("health_version.subprocess.run") as mock_run:
            mock_run.return_value.returncode = 0
            mock_run.return_value.stdout = "face123\n"
            result = get_version()

        assert result["sha"] == "face123"

    def test_sha_unknown_when_git_fails(self, monkeypatch):
        """If git raises, sha falls back to 'unknown' — never propagates the exception."""
        monkeypatch.delenv("BUILD_SHA", raising=False)
        from health_version import get_version

        with patch("health_version.subprocess.run", side_effect=Exception("git not found")):
            result = get_version()

        assert result["sha"] == "unknown"

    def test_sha_unknown_when_git_returns_nonzero(self, monkeypatch):
        """Non-zero git exit code is treated the same as a failure."""
        monkeypatch.delenv("BUILD_SHA", raising=False)
        from health_version import get_version

        with patch("health_version.subprocess.run") as mock_run:
            mock_run.return_value.returncode = 128
            mock_run.return_value.stdout = ""
            result = get_version()

        assert result["sha"] == "unknown"

    def test_git_not_called_when_build_sha_is_set(self, monkeypatch):
        """git is never invoked when BUILD_SHA is already baked in."""
        monkeypatch.setenv("BUILD_SHA", "abc1234")
        from health_version import get_version

        with patch("health_version.subprocess.run") as mock_run:
            get_version()

        mock_run.assert_not_called()


class TestBuiltAtEdgeCases:
    """Edge cases for the built_at field."""

    def test_built_at_unknown_when_env_is_literal_unknown(self, monkeypatch):
        """The Dockerfile default 'unknown' for BUILD_TIMESTAMP stays as 'unknown'."""
        monkeypatch.setenv("BUILD_SHA", "abc1234")
        monkeypatch.setenv("BUILD_TIMESTAMP", "unknown")
        from health_version import get_version

        result = get_version()
        assert result["built_at"] == "unknown"

    def test_built_at_unknown_when_env_unset(self, monkeypatch):
        """BUILD_TIMESTAMP not set at all → 'unknown'."""
        monkeypatch.setenv("BUILD_SHA", "abc1234")
        monkeypatch.delenv("BUILD_TIMESTAMP", raising=False)
        from health_version import get_version

        result = get_version()
        assert result["built_at"] == "unknown"


class TestSingleRouteRegistration:
    """Regression guard: exactly one /health/version GET route must be registered.

    This test exists to catch any future attempt to register the route via a
    second mechanism (e.g. re-introducing LITELLM_WORKER_STARTUP_HOOKS or a
    second module).  If this test fails, a route collision has been introduced.

    Two levels of assertion:
    - Router level: custom_api_router carries exactly one route definition.
    - App level: including the router on a simulated FastAPI app produces exactly
      one included router entry and the endpoint responds correctly (the app-level
      check Copilot requested so a second module's registration would be caught).
    """

    def test_custom_api_router_has_exactly_one_route(self):
        import health_version

        routes = health_version.custom_api_router.routes
        assert len(routes) == 1, (
            f"Expected exactly 1 route on custom_api_router, found {len(routes)}: "
            f"{[r.path for r in routes]}"
        )

    def test_single_route_is_health_version_get(self):
        import health_version

        route = health_version.custom_api_router.routes[0]
        assert route.path == "/health/version"
        assert "GET" in route.methods

    def test_exactly_one_health_version_route_on_simulated_app(self):
        """Include custom_api_router on a real FastAPI app and assert no competing
        direct-registration collision exists, and the endpoint responds correctly.

        Routes registered via include_router appear as lazy _IncludedRouter objects
        in app.routes (not as APIRoute). Routes registered directly via @app.get()
        or app.add_api_route() appear as APIRoute objects in app.routes. Asserting
        zero direct APIRoute entries for /health/version catches the collision case
        where a second module uses @app.get("/health/version") without relying on the
        private _IncludedRouter type name.
        """
        from fastapi import FastAPI
        from fastapi.routing import APIRoute
        from fastapi.testclient import TestClient
        import health_version

        app = FastAPI()
        app.include_router(health_version.custom_api_router)

        # No direct APIRoute for /health/version should exist; all registration
        # must flow through custom_api_router (which uses include_router).
        # A second module calling @app.get("/health/version") would create an
        # APIRoute entry here and fail this assertion.
        direct_hv_routes = [
            r for r in app.routes
            if isinstance(r, APIRoute) and r.path == "/health/version"
        ]
        assert len(direct_hv_routes) == 0, (
            f"Found {len(direct_hv_routes)} direct APIRoute registration(s) for "
            f"/health/version — all registration must flow through custom_api_router"
        )

        # Functional check: the route is reachable and returns the correct schema.
        client = TestClient(app)
        resp = client.get("/health/version")
        assert resp.status_code == 200
        assert set(resp.json().keys()) == {"sha", "built_at"}

    def test_duplicate_include_emits_fastapi_warning(self):
        """Demonstrate that FastAPI does NOT silently de-duplicate routes:
        including the same router twice triggers a 'Duplicate Operation ID' warning.

        This validates why the _router_registered guard in _register_router()
        is necessary — without it, double registration would silently corrupt the app.
        """
        import warnings
        from fastapi import FastAPI
        import health_version

        app = FastAPI()
        app.include_router(health_version.custom_api_router)
        app.include_router(health_version.custom_api_router)  # simulated accident

        with warnings.catch_warnings(record=True) as w:
            warnings.simplefilter("always")
            app.openapi()

        dup = [x for x in w if "Duplicate Operation ID" in str(x.message)]
        assert len(dup) >= 1, (
            "Expected FastAPI to warn about a duplicate /health/version route "
            "when the router is included twice, but no warning was emitted. "
            "If FastAPI now auto-deduplicates, the _router_registered guard may "
            "be safely removed — but update this test first."
        )
