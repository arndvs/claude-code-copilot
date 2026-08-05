"""Offline tests for the routing contract in litellm_config.yaml.

The proxy translates Anthropic Messages requests from Claude Code into
upstream calls (GitHub Copilot primary, OpenRouter fallback). Unlike the
structural contracts in ``test_model_entry_contract.py`` (refs #80) and
``test_settings_contract.py`` (refs #119), which check that entries *look*
right, the tests here drive a mock upstream that records what the proxy
would actually forward for a representative inbound Anthropic request, and
assert the end-to-end routing contract for every alias:

- model remapping (hyphenated Claude Code name -> dotted upstream model)
- the four editor headers Copilot validates (primaries only)
- ``api_key`` on fallbacks
- ``response_format`` / ``thinking`` stripping (drop_params, no secrets)
- ``stream: true`` on the upstream request
- ``router_settings.fallbacks`` wiring primary -> fallback
- wildcard pass-through

Aliases are discovered from model_list in the YAML, so a new model entry is
covered automatically without editing this file. It runs on ``pyyaml`` +
``pytest`` only: no network, no secrets, no Docker, no LiteLLM import (so it
stays fast and works in CI where LiteLLM is not installed).

Refs #133
"""

from __future__ import annotations

import yaml
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = REPO_ROOT / "litellm_config.yaml"

COPILOT_MODEL_PREFIX = "github_copilot/"
OPENROUTER_MODEL_PREFIX = "openrouter/"
API_KEY_REF = "os.environ/OPENROUTER_API_KEY"
FALLBACK_SUFFIX = "-fallback"

# The exact four editor headers Copilot validates on every primary request.
EDITOR_HEADERS = {
    "Editor-Version",
    "Editor-Plugin-Version",
    "Copilot-Integration-Id",
    "User-Agent",
}

# A representative inbound Anthropic Messages request as Claude Code sends it.
# Carries both of the params the proxy is configured to strip, so the mock can
# prove they are dropped before reaching the upstream.
INBOUND_MESSAGE_REQUEST = {
    "model": "claude-sonnet-4-6",
    "max_tokens": 2048,
    "stream": True,
    "thinking": {"type": "enabled", "budget_tokens": 1024},
    "response_format": {"type": "text"},
    "messages": [{"role": "user", "content": "hello"}],
}


@pytest.fixture
def config():
    """Load and return the parsed litellm_config.yaml (skips when absent)."""
    if not CONFIG_PATH.exists():
        pytest.skip(f"litellm_config.yaml not found at {CONFIG_PATH}")
    with open(CONFIG_PATH, encoding="utf-8") as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict):
        pytest.fail(
            f"litellm_config.yaml did not parse as a mapping (got {type(data).__name__})"
        )
    return data


def _model_list(config):
    """Return a non-empty model_list or fail with a clear message."""
    model_list = config.get("model_list", [])
    assert isinstance(model_list, list) and model_list, (
        f"model_list must be a non-empty list; got {type(model_list).__name__}"
    )
    return model_list


def _is_fallback(name: str) -> bool:
    return isinstance(name, str) and name.endswith(FALLBACK_SUFFIX)


def _split_alias_entries(model_list):
    """Split model_list entries into (primaries, fallbacks).

    Explicit aliases only: the wildcard entry (model_name ``*`` / ``*-fallback``)
    is intentionally excluded here and handled by the dedicated wildcard tests.
    """
    primaries = []
    fallbacks = []
    for entry in model_list:
        name = entry.get("model_name", "<unnamed>")
        if name == "*" or name == "*-fallback":
            continue
        (fallbacks if _is_fallback(name) else primaries).append(entry)
    return primaries, fallbacks


def _drop_params(config):
    """Return the set of params the proxy is configured to strip upstream."""
    settings = config.get("litellm_settings", {})
    return set(settings.get("additional_drop_params", []))


def _forward(config, entry, inbound):
    """Simulate the mock upstream: what the proxy forwards for this entry.

    Returns ``(headers, body)`` as an upstream would record them, applying the
    documented transformations from ``litellm_params`` and ``litellm_settings``:
    model remap, stream, header injection, api_key passthrough, and param-drop.
    This is the machine under test for the per-alias assertions.
    """
    headers = {}
    params = entry.get("litellm_params", {})

    body = dict(inbound)
    body["model"] = params.get("model")
    body["stream"] = params.get("stream", False)
    for k in _drop_params(config):
        body.pop(k, None)

    api_key = params.get("api_key")
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    headers.update(params.get("extra_headers", {}))
    return headers, body


class TestEveryAliasCovered:
    """The routing tests must discover every alias from the YAML automatically."""

    def test_explicit_aliases_are_enumerated(self, config):
        """At least one primary and one fallback, so the loop-based tests run."""
        primaries, fallbacks = _split_alias_entries(_model_list(config))
        assert primaries, "No explicit primary aliases found in model_list"
        assert fallbacks, "No explicit fallback aliases found in model_list"

    def test_every_primary_remaps_to_copilot_with_headers(self, config):
        """Each primary alias: Copilot model remap + all four editor headers."""
        primaries, _ = _split_alias_entries(_model_list(config))
        for entry in primaries:
            name = entry["model_name"]
            params = entry.get("litellm_params", {})
            headers, body = _forward(config, entry, INBOUND_MESSAGE_REQUEST)

            model = params.get("model")
            assert isinstance(model, str) and model.startswith(COPILOT_MODEL_PREFIX), (
                f"Primary '{name}' remaps to {model!r}, expected {COPILOT_MODEL_PREFIX!r} "
                f"(CONTEXT.md §1)."
            )
            # Claude Code sends hyphenated names; Copilot uses dotted names. The
            # remap must actually translate the alias, or the proxy echoes the
            # inbound alias back at the upstream and Copilot rejects it.
            assert model != name, (
                f"Primary '{name}' remaps to itself ({model!r}); expected a distinct "
                f"dotted Copilot model (CONTEXT.md §1)."
            )
            assert "_" not in name and "-" in name, (
                f"Alias '{name}' is not a hyphenated Claude Code model name "
                f"(CONTEXT.md §1)."
            )

            missing = EDITOR_HEADERS - set(headers)
            assert not missing, (
                f"Primary '{name}' is missing editor header(s) {sorted(missing)}; "
                f"Copilot rejects requests without them (CONTEXT.md §1)."
            )

    def test_every_fallback_remaps_to_openrouter_with_api_key(self, config):
        """Each fallback alias: OpenRouter model remap + api_key upstream."""
        _, fallbacks = _split_alias_entries(_model_list(config))
        for entry in fallbacks:
            name = entry["model_name"]
            params = entry.get("litellm_params", {})
            headers, body = _forward(config, entry, INBOUND_MESSAGE_REQUEST)

            model = params.get("model")
            assert isinstance(model, str) and model.startswith(OPENROUTER_MODEL_PREFIX), (
                f"Fallback '{name}' remaps to {model!r}, expected {OPENROUTER_MODEL_PREFIX!r} "
                f"(CONTEXT.md §1)."
            )
            assert body["model"] == model, (
                f"Fallback '{name}' would forward model {body['model']!r}, expected {model!r}."
            )
            assert params.get("api_key") == API_KEY_REF, (
                f"Fallback '{name}' api_key={params.get('api_key')!r}, expected "
                f"{API_KEY_REF!r} (CONTEXT.md §1)."
            )
            assert "Authorization" in headers, (
                f"Fallback '{name}' would not send an Authorization header despite "
                f"carrying an api_key (CONTEXT.md §1)."
            )

    def test_every_primary_is_wired_to_its_fallback(self, config):
        """router_settings.fallbacks maps each primary to its ``-fallback``."""
        model_list = _model_list(config)
        fallbacks = config.get("router_settings", {}).get("fallbacks", [])
        assert isinstance(fallbacks, list), (
            "router_settings.fallbacks must be a list of dicts; got "
            f"{type(fallbacks).__name__}"
        )
        fallback_map: dict[str, list[str]] = {}
        for item in fallbacks:
            assert isinstance(item, dict), (
                f"router_settings.fallbacks item {item!r} is not a dict (LiteLLM format)"
            )
            for model, fb_list in item.items():
                fallback_map[model] = fb_list

        primaries, _ = _split_alias_entries(model_list)
        for entry in primaries:
            name = entry["model_name"]
            assert name in fallback_map, (
                f"Primary '{name}' has no entry in router_settings.fallbacks "
                f"(CONTEXT.md §1)."
            )
            fb_list = fallback_map[name]
            assert isinstance(fb_list, list) and fb_list, (
                f"Primary '{name}' has an empty fallbacks list (CONTEXT.md §1)."
            )
            assert f"{name}{FALLBACK_SUFFIX}" in fb_list, (
                f"Primary '{name}' fallbacks {fb_list!r} omit its "
                f"'{name}{FALLBACK_SUFFIX}' deployment (CONTEXT.md §1)."
            )


class TestParamDropAndStreaming:
    """The proxy must strip unsupported params and request streaming upstream."""

    def test_response_format_and_thinking_are_dropped(self, config):
        """drop_params strips response_format/thinking before the upstream."""
        drop = _drop_params(config)
        assert not {"response_format", "thinking"} - drop, (
            f"additional_drop_params={sorted(drop)} must include both 'response_format' "
            f"and 'thinking' (CONTEXT.md §1)."
        )
        assert config.get("litellm_settings", {}).get("drop_params") is True, (
            "litellm_settings.drop_params must be true for the list to take effect "
            "(CONTEXT.md §1)."
        )

    def test_drop_params_strips_on_forward(self, config):
        """The mock upstream never sees strip-list params, for any alias."""
        primaries, fallbacks = _split_alias_entries(_model_list(config))
        for entry in primaries + fallbacks:
            _headers, body = _forward(config, entry, INBOUND_MESSAGE_REQUEST)
            assert "thinking" not in body and "response_format" not in body, (
                f"'{entry['model_name']}' would forward stripped params upstream."
            )

    def test_every_alias_requests_streaming_upstream(self, config):
        """stream: true is forwarded so the Anthropic adapter streams (refs #49)."""
        primaries, fallbacks = _split_alias_entries(_model_list(config))
        for entry in primaries + fallbacks:
            _headers, body = _forward(config, entry, INBOUND_MESSAGE_REQUEST)
            assert body.get("stream") is True, (
                f"Alias '{entry['model_name']}' would forward stream="
                f"{body.get('stream')!r}, expected True (CONTEXT.md §1)."
            )


class TestWildcardPassThrough:
    """The catch-all route passes the request through unchanged apart from config."""

    def test_wildcard_primary_passes_through(self, config):
        """The '*' entry keeps ``github_copilot/*`` as its model target."""
        model_list = _model_list(config)
        wildcard = next(
            (e for e in model_list if e.get("model_name") == "*"), None
        )
        assert wildcard is not None, (
            "model_list must define the '*' catch-all primary (CONTEXT.md §1)."
        )
        params = wildcard.get("litellm_params", {})
        assert params.get("model") == "github_copilot/*", (
            f"Wildcard primary model={params.get('model')!r}; expected "
            f"'github_copilot/*' pass-through (CONTEXT.md §1)."
        )
        headers, _body = _forward(config, wildcard, INBOUND_MESSAGE_REQUEST)
        missing = EDITOR_HEADERS - set(headers)
        assert not missing, (
            f"Wildcard primary is missing editor header(s) {sorted(missing)}."
        )

    def test_wildcard_fallback_passes_through(self, config):
        """The '*-fallback' entry keeps ``openrouter/*`` and carries the api_key."""
        model_list = _model_list(config)
        wildcard_fb = next(
            (e for e in model_list if e.get("model_name") == "*-fallback"), None
        )
        assert wildcard_fb is not None, (
            "model_list must define the '*-fallback' catch-all fallback (CONTEXT.md §1)."
        )
        params = wildcard_fb.get("litellm_params", {})
        assert params.get("model") == "openrouter/*", (
            f"Wildcard fallback model={params.get('model')!r}; expected 'openrouter/*'."
        )
        assert params.get("api_key") == API_KEY_REF, (
            f"Wildcard fallback api_key={params.get('api_key')!r}; expected {API_KEY_REF!r}."
        )

    def test_wildcard_is_wired_to_wildcard_fallback(self, config):
        """router_settings.fallbacks must route '*' -> ['*-fallback']."""
        fallbacks = config.get("router_settings", {}).get("fallbacks", [])
        fallback_map: dict[str, list[str]] = {}
        for item in fallbacks:
            if isinstance(item, dict):
                fallback_map.update(item)
        assert "*" in fallback_map and "*-fallback" in fallback_map["*"], (
            "router_settings.fallbacks must wire '*' -> ['*-fallback'] (CONTEXT.md §1)."
        )
