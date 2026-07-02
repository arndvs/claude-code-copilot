"""Unit tests for scripts/proxy_status.py.

These exercise the URL resolution / validation / classification / health logic
directly, complementing the end-to-end `make claude-status` integration tests in
scripts/test_security.sh (which fake HOME and stub curl). Every edge case those
integration tests cover (hosted, IPv6 loopback, missing scheme, missing host,
malformed env, trailing slash) has a fast, deterministic unit test here.

Refs #81
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import proxy_status  # noqa: E402  (import after sys.path setup)


class TestResolveProxyUrl:
    def test_returns_configured_url(self):
        settings = {"env": {"ANTHROPIC_BASE_URL": "https://proxy.example.test"}}
        assert proxy_status.resolve_proxy_url(settings) == "https://proxy.example.test"

    def test_strips_trailing_slash(self):
        settings = {"env": {"ANTHROPIC_BASE_URL": "https://proxy.example.test/"}}
        assert proxy_status.resolve_proxy_url(settings) == "https://proxy.example.test"

    def test_empty_value_falls_back_to_localhost_port(self):
        settings = {"env": {"ANTHROPIC_BASE_URL": ""}}
        assert proxy_status.resolve_proxy_url(settings, fallback_port="9999") == "http://localhost:9999"

    def test_missing_key_returns_none(self):
        assert proxy_status.resolve_proxy_url({"env": {"OTHER": "x"}}) is None

    def test_non_dict_env_returns_none(self):
        # Test 1f3: malformed env block ("env": []) → route Anthropic direct.
        assert proxy_status.resolve_proxy_url({"env": []}) is None

    def test_non_dict_settings_returns_none(self):
        assert proxy_status.resolve_proxy_url([]) is None

    def test_non_string_value_is_coerced_not_crashed(self):
        # A non-string ANTHROPIC_BASE_URL (malformed settings) must not raise; it
        # is coerced so validate_proxy_url can reject it as invalid.
        assert proxy_status.resolve_proxy_url({"env": {"ANTHROPIC_BASE_URL": 123}}) == "123"
        assert proxy_status.resolve_proxy_url({"env": {"ANTHROPIC_BASE_URL": True}}) == "True"

    def test_json_null_is_coerced_not_localhost_fallback(self):
        # An explicit JSON null must NOT be treated as "use localhost"; it is
        # coerced so validate_proxy_url rejects it (matches the old Makefile).
        assert proxy_status.resolve_proxy_url({"env": {"ANTHROPIC_BASE_URL": None}}) == "None"


class TestValidateProxyUrl:
    @pytest.mark.parametrize(
        "url",
        [
            "http://localhost:4000",
            "https://proxy.example.test",
            "http://127.0.0.1:8080",
            "http://[::1]:4000",
        ],
    )
    def test_valid_urls(self, url):
        assert proxy_status.validate_proxy_url(url) is True

    @pytest.mark.parametrize(
        "url",
        [
            "proxy.example.test",   # Test 1f: no scheme
            "http://:4000",          # Test 1f2: no hostname
            "ftp://host",            # wrong scheme
            "",                       # empty
            "://nohost",             # no scheme, no host
        ],
    )
    def test_invalid_urls(self, url):
        assert proxy_status.validate_proxy_url(url) is False


class TestClassifyProxy:
    @pytest.mark.parametrize("url", ["http://localhost:4000", "http://127.0.0.1:8080", "http://[::1]:4000"])
    def test_local(self, url):
        # Test 1e: IPv6 loopback is local.
        assert proxy_status.classify_proxy(url) == "local"

    def test_hosted(self):
        assert proxy_status.classify_proxy("https://proxy.example.test") == "hosted"

    @pytest.mark.parametrize("url", [None, ""])
    def test_direct(self, url):
        assert proxy_status.classify_proxy(url) == "direct"


class TestProbeHealth:
    def test_success(self, monkeypatch):
        monkeypatch.setattr(
            proxy_status.subprocess, "run", lambda *a, **k: type("R", (), {"returncode": 0})()
        )
        assert proxy_status.probe_health("http://x") is True

    def test_failure(self, monkeypatch):
        monkeypatch.setattr(
            proxy_status.subprocess, "run", lambda *a, **k: type("R", (), {"returncode": 22})()
        )
        assert proxy_status.probe_health("http://x") is False

    def test_curl_missing_or_timeout_is_false(self, monkeypatch):
        def boom(*a, **k):
            raise FileNotFoundError("curl not found")

        monkeypatch.setattr(proxy_status.subprocess, "run", boom)
        assert proxy_status.probe_health("http://x") is False


class TestRenderStatus:
    def test_direct_when_no_proxy(self):
        lines = proxy_status.render_status({"env": {}}, probe=lambda url: True)
        assert lines == ["🌐 Routing: Anthropic API directly"]

    def test_invalid_url(self):
        settings = {"env": {"ANTHROPIC_BASE_URL": "proxy.example.test"}}
        lines = proxy_status.render_status(settings, probe=lambda url: True)
        assert lines == ["❌ Proxy URL in settings is invalid: proxy.example.test"]

    def test_local_running(self):
        settings = {"env": {"ANTHROPIC_BASE_URL": "http://localhost:4000"}}
        lines = proxy_status.render_status(settings, probe=lambda url: True)
        assert lines == ["🔗 Routing: local proxy", "✅ Proxy: running at http://localhost:4000"]

    def test_local_down_suggests_make_start(self):
        settings = {"env": {"ANTHROPIC_BASE_URL": "http://localhost:4000"}}
        lines = proxy_status.render_status(settings, probe=lambda url: False)
        assert lines[0] == "🔗 Routing: local proxy"
        assert lines[1] == "❌ Proxy: not running at http://localhost:4000 — run 'make start'"

    def test_hosted_down_suggests_endpoint_check(self):
        settings = {"env": {"ANTHROPIC_BASE_URL": "https://proxy.example.test"}}
        lines = proxy_status.render_status(settings, probe=lambda url: False)
        assert lines[0] == "🔗 Routing: hosted proxy"
        assert lines[1] == "❌ Proxy: not running at https://proxy.example.test — check the hosted proxy endpoint"

    def test_trailing_slash_stripped_in_health_line(self):
        # Test 1f4: the displayed URL must not carry a trailing slash.
        settings = {"env": {"ANTHROPIC_BASE_URL": "https://proxy.example.test/"}}
        lines = proxy_status.render_status(settings, probe=lambda url: False)
        assert "https://proxy.example.test " in lines[1]
        assert "https://proxy.example.test/ " not in lines[1]


class TestReadFallbackPort:
    def test_reads_litellm_port(self, tmp_path):
        env = tmp_path / ".env"
        env.write_text('LITELLM_PORT="8123"\nOTHER=1\n')
        assert proxy_status.read_fallback_port(str(env)) == "8123"

    def test_defaults_when_absent(self, tmp_path):
        env = tmp_path / ".env"
        env.write_text("OTHER=1\n")
        assert proxy_status.read_fallback_port(str(env)) == proxy_status.DEFAULT_PORT

    def test_defaults_when_file_missing(self, tmp_path):
        assert proxy_status.read_fallback_port(str(tmp_path / "nope.env")) == proxy_status.DEFAULT_PORT

    def test_custom_default_used_when_absent(self, tmp_path):
        env = tmp_path / ".env"
        env.write_text("OTHER=1\n")
        assert proxy_status.read_fallback_port(str(env), default="7777") == "7777"

    def test_ignores_lookalike_keys(self, tmp_path):
        env = tmp_path / ".env"
        env.write_text('LITELLM_PORTAL="9999"\nLITELLM_PORT=8080\n')
        assert proxy_status.read_fallback_port(str(env)) == "8080"


class TestMain:
    def test_passes_make_default_port_to_fallback(self, tmp_path, monkeypatch):
        # `make claude-status PORT=XXXX` passes the port as argv[2]; main() must
        # feed it to read_fallback_port as the default (.env still takes precedence).
        settings = tmp_path / "settings.json"
        settings.write_text('{"env": {"ANTHROPIC_BASE_URL": ""}}')
        captured = {}

        def fake_read(env_path=".env", default=proxy_status.DEFAULT_PORT):
            captured["default"] = default
            return default

        monkeypatch.setattr(proxy_status, "read_fallback_port", fake_read)
        proxy_status.main(["proxy_status.py", str(settings), "6543"])
        assert captured["default"] == "6543"
