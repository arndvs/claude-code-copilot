"""Unit tests for scripts/proxy_endpoint.py.

The canonical proxy-endpoint resolver (refs #110, #128) owns the question "what
URL will the proxy be reachable at?" — unifying the divergent port/URL
resolution across start_proxy.sh, Makefile, proxy_status.py, and
claude_enable.py.

Precedence chain (highest wins):
    1. PROXY_BASE_URL (full URL override)
    2. ANTHROPIC_BASE_URL (from settings — already-configured state)
    3. http://localhost:{LITELLM_PORT} (from env or .env file)
    4. http://localhost:4000 (hardcoded default)

Refs #110, #128
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import proxy_endpoint  # noqa: E402  (import after sys.path setup)


class TestPrecedenceChain:
    """The precedence chain must resolve in the documented order."""

    def test_proxy_base_url_wins_over_everything(self, monkeypatch):
        monkeypatch.setenv("PROXY_BASE_URL", "https://proxy.example.test")
        monkeypatch.setenv("LITELLM_PORT", "9999")
        ep = proxy_endpoint.resolve_proxy_endpoint(
            env_file=".env",
            settings={"env": {"ANTHROPIC_BASE_URL": "http://localhost:5000"}},
        )
        assert ep.url == "https://proxy.example.test"
        assert ep.kind == "hosted"

    def test_anthropic_base_url_from_settings_beats_env_port(self, monkeypatch):
        monkeypatch.delenv("PROXY_BASE_URL", raising=False)
        monkeypatch.setenv("LITELLM_PORT", "9999")
        ep = proxy_endpoint.resolve_proxy_endpoint(
            env_file=".env",
            settings={"env": {"ANTHROPIC_BASE_URL": "http://localhost:5000"}},
        )
        assert ep.url == "http://localhost:5000"
        assert ep.kind == "local"

    def test_env_port_beats_default(self, monkeypatch, tmp_path):
        monkeypatch.delenv("PROXY_BASE_URL", raising=False)
        monkeypatch.delenv("LITELLM_PORT", raising=False)
        env_file = tmp_path / ".env"
        env_file.write_text("LITELLM_PORT=7777\n", encoding="utf-8")
        ep = proxy_endpoint.resolve_proxy_endpoint(
            env_file=str(env_file), settings={"env": {}}
        )
        assert ep.url == "http://localhost:7777"
        assert ep.port == "7777"

    def test_default_port_when_nothing_configured(self, monkeypatch, tmp_path):
        monkeypatch.delenv("PROXY_BASE_URL", raising=False)
        monkeypatch.delenv("LITELLM_PORT", raising=False)
        env_file = tmp_path / ".env"
        env_file.write_text("", encoding="utf-8")
        ep = proxy_endpoint.resolve_proxy_endpoint(
            env_file=str(env_file), settings={"env": {}}
        )
        assert ep.url == "http://localhost:4000"
        assert ep.port == "4000"
        assert ep.kind == "local"
