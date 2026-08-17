"""Tests for health_version — /health/version endpoint logic."""

from __future__ import annotations

import sys
import os
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


class TestGetVersion:
    """Unit tests for get_version() — the core logic."""

    def test_returns_sha_and_built_at_from_env(self, monkeypatch):
        monkeypatch.setenv("BUILD_SHA", "abc1234")
        monkeypatch.setenv("BUILD_TIMESTAMP", "2024-01-15T10:30:00Z")
        from health_version import get_version

        result = get_version()
        assert result["sha"] == "abc1234"
        assert result["built_at"] == "2024-01-15T10:30:00Z"

    def test_sha_is_truncated_to_7_chars(self, monkeypatch):
        """A long SHA (baked in or from git) must be trimmed to 7 chars."""
        # Env-baked full 40-char SHA.
        monkeypatch.setenv("BUILD_SHA", "a" * 40)
        from health_version import get_version

        assert get_version()["sha"] == "a" * 7

        # git rev-parse --short can exceed 7 chars in large repos.
        monkeypatch.delenv("BUILD_SHA", raising=False)
        with patch("health_version.subprocess.run") as mock_run:
            mock_run.return_value.returncode = 0
            mock_run.return_value.stdout = "abcdef1234567890\n"  # 16-char abbrev
            result = get_version()
        assert result["sha"] == "abcdef1"

    def test_sha_falls_back_to_git_when_env_unset(self, monkeypatch):
        """Git provides the SHA when BUILD_SHA is missing, and is not called when set."""
        monkeypatch.delenv("BUILD_SHA", raising=False)
        from health_version import get_version

        with patch("health_version.subprocess.run") as mock_run:
            mock_run.return_value.returncode = 0
            mock_run.return_value.stdout = "deadbee\n"
            assert get_version()["sha"] == "deadbee"
        mock_run.assert_called_once()

        # git is never invoked when BUILD_SHA is already baked in.
        monkeypatch.setenv("BUILD_SHA", "abc1234")
        with patch("health_version.subprocess.run") as mock_run:
            get_version()
        mock_run.assert_not_called()

    def test_built_at_defaults_to_unknown_when_not_a_real_value(self, monkeypatch):
        """The Dockerfile default 'unknown' and an empty string normalize to 'unknown'."""
        from health_version import get_version

        for value in (None, "", "unknown"):
            monkeypatch.setenv("BUILD_SHA", "abc1234")
            if value is None:
                monkeypatch.delenv("BUILD_TIMESTAMP", raising=False)
            else:
                monkeypatch.setenv("BUILD_TIMESTAMP", value)
            assert get_version()["built_at"] == "unknown"

    def test_response_has_exactly_two_keys(self, monkeypatch):
        monkeypatch.setenv("BUILD_SHA", "deadbee")
        monkeypatch.setenv("BUILD_TIMESTAMP", "2024-06-01T00:00:00Z")
        from health_version import get_version

        assert set(get_version().keys()) == {"sha", "built_at"}


class TestGitFallback:
    """The git rev-parse fallback and its failure modes."""

    def test_git_failure_paths_return_unknown(self, monkeypatch):
        """A raised git error or non-zero exit both degrade to 'unknown'."""
        from health_version import get_version

        # subprocess raises (git unavailable).
        monkeypatch.delenv("BUILD_SHA", raising=False)
        with patch("health_version.subprocess.run", side_effect=Exception("git not found")):
            assert get_version()["sha"] == "unknown"

        # git exits non-zero with no stdout.
        with patch("health_version.subprocess.run") as mock_run:
            mock_run.return_value.returncode = 128
            mock_run.return_value.stdout = ""
            assert get_version()["sha"] == "unknown"


class TestRegisterRouter:
    """Verify _register_router degrades gracefully outside the proxy."""

    def test_register_router_does_not_raise_outside_proxy(self):
        """Calling _register_router outside litellm proxy context must not fail."""
        import health_version

        health_version._register_router()


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
        """Include custom_api_router on a real FastAPI app and assert exactly one
        GET /health/version route exists, using a recursive route collector that
        handles both eager-flattening (older FastAPI) and lazy _IncludedRouter
        (FastAPI 0.100+) registration styles.

        A second module registering GET /health/version via either @app.get() or
        a second include_router() would cause the count to exceed 1 and fail.
        """
        from fastapi import FastAPI
        from fastapi.routing import APIRoute
        from fastapi.testclient import TestClient
        import health_version

        def _collect_get_routes(routes, path: str) -> list:
            """Recursively collect all GET APIRoute objects for a given path.

            Handles both direct APIRoute registrations and lazy _IncludedRouter
            objects (FastAPI 0.100+), which nest their routes under original_router.
            """
            found = []
            for r in routes:
                if isinstance(r, APIRoute) and r.path == path and "GET" in (r.methods or set()):
                    found.append(r)
                # _IncludedRouter (FastAPI 0.100+) stores the original router;
                # recurse to find APIRoute objects nested inside it.
                if hasattr(r, "original_router") and hasattr(r.original_router, "routes"):
                    found.extend(_collect_get_routes(r.original_router.routes, path))
            return found

        app = FastAPI()
        app.include_router(health_version.custom_api_router)

        hv_routes = _collect_get_routes(app.routes, "/health/version")
        assert len(hv_routes) == 1, (
            f"Expected exactly 1 GET /health/version route, found {len(hv_routes)} — "
            f"a second module may have registered the route"
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
