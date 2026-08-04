"""Tests for the settings-block contract in litellm_config.yaml.

The ``litellm_settings``, ``general_settings``, and ``router_settings`` blocks
must satisfy the contract documented in CONTEXT.md §1. This is an executable
specification of "what correct settings look like" — it catches silent config
bugs (like the fallback-format crash, PR #123) at PR time instead of at runtime.
Fallback wiring itself is validated separately in ``test_model_entry_contract.py``;
this module deliberately does NOT duplicate that.

Refs #124
"""

from __future__ import annotations

import yaml
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = REPO_ROOT / "litellm_config.yaml"

# Settings blocks we validate (top-level keys we understand).
KNOWN_TOP_LEVEL_KEYS = {
    "litellm_settings",
    "model_list",
    "general_settings",
    "router_settings",
}

# master_key (and every other secret reference) must come from the environment.
ENV_PATTERN = "os.environ/"


@pytest.fixture
def config():
    """Load and return the parsed litellm_config.yaml.

    Mirrors the fixture in test_model_entry_contract.py: skips when the file is
    absent, fails clearly when the YAML is empty or not a mapping.
    """
    if not CONFIG_PATH.exists():
        pytest.skip(f"litellm_config.yaml not found at {CONFIG_PATH}")
    with open(CONFIG_PATH, encoding="utf-8") as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict):
        pytest.fail(
            f"litellm_config.yaml did not parse as a mapping (got {type(data).__name__})"
        )
    return data


def _settings_block(config, name: str):
    """Return a named settings block, asserting it is a non-empty mapping."""
    block = config.get(name, {})
    assert isinstance(block, dict) and block, (
        f"{name} must be a non-empty mapping; got {type(block).__name__} "
        f"({block!r}) (CONTEXT.md §1)."
    )
    return block


class TestSettingsContract:
    """The settings blocks must satisfy the CONTEXT.md §1 contract."""

    def test_config_file_exists(self):
        """Config file existence check — does not require the config fixture."""
        assert CONFIG_PATH.exists(), "litellm_config.yaml not found at repo root"

    def test_no_unknown_top_level_keys(self, config):
        """Top-level keys we don't recognise are a drift signal rather than tolerated."""
        unknown = set(config) - KNOWN_TOP_LEVEL_KEYS
        assert not unknown, (
            f"Unknown top-level key(s) in litellm_config.yaml: {sorted(unknown)}. "
            f"Known keys are {sorted(KNOWN_TOP_LEVEL_KEYS)} (CONTEXT.md §1)."
        )

    def test_drop_params_is_true(self, config):
        """drop_params must be the boolean true (silently strips unsupported params)."""
        block = _settings_block(config, "litellm_settings")
        assert block.get("drop_params") is True, (
            f"litellm_settings.drop_params must be true; got {block.get('drop_params')!r} "
            f"(CONTEXT.md §1)."
        )

    def test_additional_drop_params_is_list_of_strings(self, config):
        """additional_drop_params must be a list of strings."""
        block = _settings_block(config, "litellm_settings")
        params = block.get("additional_drop_params")
        assert isinstance(params, list) and params, (
            f"litellm_settings.additional_drop_params must be a non-empty list of "
            f"strings; got {params!r} (CONTEXT.md §1)."
        )
        for p in params:
            assert isinstance(p, str) and p, (
                f"additional_drop_params entry {p!r} must be a non-empty string "
                f"(CONTEXT.md §1)."
            )

    def test_callbacks_resolve_to_repo_files(self, config):
        """Every callback dotted path must resolve to a Python file at repo root.

        A callback that names a module which no longer exists would register a
        no-op silently, so the proxy keeps running without the intended
        observability/health wiring (CONTEXT.md §1).
        """
        block = _settings_block(config, "litellm_settings")
        callbacks = block.get("callbacks")
        assert isinstance(callbacks, list) and callbacks, (
            f"litellm_settings.callbacks must be a non-empty list; got {callbacks!r} "
            f"(CONTEXT.md §1)."
        )
        for cb in callbacks:
            assert isinstance(cb, str) and cb, (
                f"callbacks entry {cb!r} must be a non-empty dotted path (CONTEXT.md §1)."
            )
            module = cb.split(".")[0]
            module_file = REPO_ROOT / f"{module}.py"
            assert module_file.exists(), (
                f"Callback '{cb}' references module '{module}', but "
                f"{module_file.name} does not exist at repo root (CONTEXT.md §1)."
            )

    def test_master_key_uses_os_environ(self, config):
        """general_settings.master_key must reference the LITELLM_MASTER_KEY env var.

        The auth boundary (CONTEXT.md §1) keeps the master key in the environment,
        never in the committed YAML. A hardcoded key here would be a secret leak.
        """
        block = _settings_block(config, "general_settings")
        master_key = block.get("master_key")
        assert isinstance(master_key, str) and master_key.startswith(ENV_PATTERN), (
            f"general_settings.master_key={master_key!r} must use the "
            f"{ENV_PATTERN!r} pattern so the key stays in the environment "
            f"(CONTEXT.md §1)."
        )

    def test_num_retries_consistent_and_positive(self, config):
        """router_settings.num_retries must be a positive int and match litellm_settings.

        Two places configure retries; if they drift, one silently wins and the
        operator's intent is unclear (CONTEXT.md §1).
        """
        litellm_block = _settings_block(config, "litellm_settings")
        router_block = _settings_block(config, "router_settings")

        router_retries = router_block.get("num_retries")
        assert isinstance(router_retries, int) and not isinstance(router_retries, bool), (
            f"router_settings.num_retries must be a positive int; got "
            f"{router_retries!r} (CONTEXT.md §1)."
        )
        assert router_retries > 0, (
            f"router_settings.num_retries must be positive; got {router_retries} "
            f"(CONTEXT.md §1)."
        )

        litellm_retries = litellm_block.get("num_retries")
        assert router_retries == litellm_retries, (
            f"router_settings.num_retries ({router_retries}) must match "
            f"litellm_settings.num_retries ({litellm_retries}) (CONTEXT.md §1)."
        )


class TestSettingsBlockFailsLoud:
    """Structural breaks must fail with a clear contract message, not AttributeError.

    Mirrors TestMalformedConfigFailsLoud in test_model_entry_contract.py: the
    helpers assert types up front so a malformed config yields an actionable
    message instead of an opaque AttributeError.
    """

    def test_settings_block_must_be_a_non_empty_mapping(self):
        with pytest.raises(AssertionError, match="must be a non-empty mapping"):
            _settings_block({"router_settings": "oops"}, "router_settings")

    @pytest.mark.parametrize("name", ["litellm_settings", "general_settings", "router_settings"])
    def test_settings_block_rejects_empty(self, name):
        with pytest.raises(AssertionError, match="must be a non-empty mapping"):
            _settings_block({name: {}}, name)
