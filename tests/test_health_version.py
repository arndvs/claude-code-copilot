"""Tests for health_version — /health/version endpoint logic.

RED phase: tests fail until health_version module is implemented.
"""

from __future__ import annotations

import os
import sys

import pytest

sys.path.insert(0, ".")


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

    def test_sha_defaults_to_unknown_when_unset(self, monkeypatch):
        monkeypatch.delenv("BUILD_SHA", raising=False)
        monkeypatch.delenv("BUILD_TIMESTAMP", raising=False)
        from health_version import get_version

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
