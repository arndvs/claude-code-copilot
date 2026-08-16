"""Tests for the settings-block structural contract in litellm_config.yaml.

The ``model_list`` contract is enforced by ``test_model_entry_contract.py``
(refs #80), but the three settings blocks — ``litellm_settings``,
``general_settings``, and ``router_settings`` — have no executable contract.
These blocks carry safety-critical configuration:

- ``drop_params`` / ``additional_drop_params`` silently strip parameters the
  upstream doesn't support. A typo (``drop_param``) would cause the upstream to
  reject every request, and CI would not catch it.
- ``general_settings.master_key`` controls the auth boundary. A malformed
  reference silently disables auth or breaks startup.
- ``callbacks`` registers the observability logger and the ``/health/version``
  endpoint. A stale module path silently drops both.
- ``router_settings.num_retries`` duplicates ``litellm_settings.num_retries``;
  divergence means the effective retry behavior differs from what CONTEXT.md
  documents.

This is an executable specification of "what a correct settings block looks
like" — it catches config errors at PR time instead of at runtime.

Refs #119
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
import yaml


REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = REPO_ROOT / "litellm_config.yaml"

# The only top-level keys LiteLLM's proxy config accepts.
KNOWN_TOP_LEVEL_KEYS = {
    "model_list",
    "litellm_settings",
    "general_settings",
    "router_settings",
    "environment_variables",
}

# Callback module paths must resolve to a Python file at the repo root.
CALLBACK_MODULE_PREFIX = "litellm_logger"
CALLBACK_MODULE_FILES = {
    "litellm_logger": REPO_ROOT / "litellm_logger.py",
    "health_version": REPO_ROOT / "health_version.py",
}


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


class TestTopLevelKeys:
    """The YAML must not contain unknown top-level keys."""

    def test_no_unknown_top_level_keys(self, config):
        """A typo like ``litellm_setting`` (missing 's') is caught immediately."""
        unknown = set(config.keys()) - KNOWN_TOP_LEVEL_KEYS
        assert not unknown, (
            f"Unknown top-level key(s) in litellm_config.yaml: {sorted(unknown)}. "
            f"Expected one of {sorted(KNOWN_TOP_LEVEL_KEYS)} (CONTEXT.md §1)."
        )


class TestLitellmSettings:
    """litellm_settings must carry the safety-critical param-stripping config."""

    def test_drop_params_is_true(self, config):
        """drop_params must be the boolean true (not a string or missing)."""
        settings = config.get("litellm_settings", {})
        assert settings.get("drop_params") is True, (
            f"litellm_settings.drop_params must be true; got "
            f"{settings.get('drop_params')!r}. A typo here lets unsupported "
            f"params reach the upstream and cause 400s (CONTEXT.md §1)."
        )

    def test_additional_drop_params_is_list_of_strings(self, config):
        """additional_drop_params must be a list of strings."""
        settings = config.get("litellm_settings", {})
        value = settings.get("additional_drop_params")
        assert isinstance(value, list) and value, (
            f"litellm_settings.additional_drop_params must be a non-empty list; "
            f"got {value!r} (CONTEXT.md §1)."
        )
        assert all(isinstance(item, str) for item in value), (
            f"litellm_settings.additional_drop_params must be a list of strings; "
            f"got {value!r} (CONTEXT.md §1)."
        )

    def test_callbacks_is_non_empty_list(self, config):
        """callbacks must be a non-empty list (observability + health/version)."""
        settings = config.get("litellm_settings", {})
        callbacks = settings.get("callbacks")
        assert isinstance(callbacks, list) and callbacks, (
            f"litellm_settings.callbacks must be a non-empty list; got "
            f"{callbacks!r}. Without it, PROXY_LOG and /health/version vanish "
            f"(CONTEXT.md §1)."
        )

    def test_callback_module_paths_are_importable(self, config):
        """Each callback's module path must resolve to an existing Python file.

        A stale module path (e.g. after a rename) silently drops observability
        and the /health/version endpoint while the proxy still starts.
        """
        settings = config.get("litellm_settings", {})
        callbacks = settings.get("callbacks", [])
        for callback in callbacks:
            assert isinstance(callback, str), (
                f"callback {callback!r} is not a string (CONTEXT.md §1)."
            )
            module = callback.split(".")[0]
            assert module in CALLBACK_MODULE_FILES, (
                f"callback {callback!r} references unknown module {module!r}; "
                f"expected one of {sorted(CALLBACK_MODULE_FILES)} (CONTEXT.md §1)."
            )
            assert CALLBACK_MODULE_FILES[module].exists(), (
                f"callback {callback!r} references {CALLBACK_MODULE_FILES[module].name} "
                f"which does not exist at the repo root (CONTEXT.md §1)."
            )


class TestGeneralSettings:
    """general_settings must carry the auth boundary."""

    def test_master_key_uses_os_environ_pattern(self, config):
        """master_key must reference an env var via the os.environ/ pattern."""
        settings = config.get("general_settings", {})
        master_key = settings.get("master_key")
        assert isinstance(master_key, str) and master_key.startswith("os.environ/"), (
            f"general_settings.master_key must be an 'os.environ/...' reference; "
            f"got {master_key!r}. A malformed reference silently disables auth "
            f"(CONTEXT.md §1)."
        )


class TestRouterSettings:
    """router_settings must be internally consistent."""

    def test_num_retries_is_positive_int(self, config):
        """router_settings.num_retries must be a positive integer."""
        settings = config.get("router_settings", {})
        num_retries = settings.get("num_retries")
        assert isinstance(num_retries, int) and num_retries > 0, (
            f"router_settings.num_retries must be a positive int; got "
            f"{num_retries!r} (CONTEXT.md §1)."
        )

    def test_num_retries_consistent_across_blocks(self, config):
        """num_retries must match between litellm_settings and router_settings.

        If only one block is updated, the effective retry behavior diverges from
        what CONTEXT.md documents without any signal.
        """
        litellm_retries = config.get("litellm_settings", {}).get("num_retries")
        router_retries = config.get("router_settings", {}).get("num_retries")
        assert litellm_retries == router_retries, (
            f"num_retries diverges: litellm_settings={litellm_retries!r} vs "
            f"router_settings={router_retries!r}. They must match (CONTEXT.md §1)."
        )
