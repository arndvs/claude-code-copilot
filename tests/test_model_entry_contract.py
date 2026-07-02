"""Tests for the model-entry structural contract in litellm_config.yaml.

Every ``model_list`` entry must satisfy the contract documented in CONTEXT.md §1:
each entry routes to ``github_copilot/*``, carries the four required editor
headers Copilot validates, and those header values are identical across all
entries. This is an executable specification of "what a correct model entry
looks like" — it catches config errors at PR time instead of at runtime (the
daily ``model-health.yml`` probe, which needs secrets and can't tell "Copilot
changed availability" from "the config is structurally wrong").

Refs #80
"""

from __future__ import annotations

import re
import yaml
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = REPO_ROOT / "litellm_config.yaml"
MODELS_SCRIPT_PATH = REPO_ROOT / "scripts" / "list-copilot-models.sh"

# The four editor headers Copilot validates on every request. See CONTEXT.md §1.
REQUIRED_HEADER_KEYS = (
    "Editor-Version",
    "Editor-Plugin-Version",
    "Copilot-Integration-Id",
    "User-Agent",
)

# Every litellm_params.model must route through the Copilot provider.
COPILOT_MODEL_PREFIX = "github_copilot/"


@pytest.fixture
def config():
    """Load and return the parsed litellm_config.yaml.

    Mirrors the fixture in test_streaming_config.py: skips when the file is
    absent, fails clearly when the YAML is empty or not a mapping.
    """
    if not CONFIG_PATH.exists():
        pytest.skip(f"litellm_config.yaml not found at {CONFIG_PATH}")
    with open(CONFIG_PATH) as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict):
        pytest.fail(
            f"litellm_config.yaml did not parse as a mapping (got {type(data).__name__})"
        )
    return data


def _model_list(config):
    """Return a non-empty model_list or fail with a clear message."""
    model_list = config.get("model_list", [])
    assert model_list, "model_list is empty — the proxy has no routes to serve"
    return model_list


def _entry_headers(entry):
    """Return an entry's extra_headers mapping (or an empty dict)."""
    headers = entry.get("litellm_params", {}).get("extra_headers", {})
    return headers if isinstance(headers, dict) else {}


class TestModelEntryContract:
    """Every model_list entry must satisfy the CONTEXT.md §1 structural contract."""

    def test_config_file_exists(self):
        """Config file existence check — does not require the config fixture."""
        assert CONFIG_PATH.exists(), "litellm_config.yaml not found at repo root"

    def test_every_entry_has_non_empty_model_name(self, config):
        """A missing/empty model_name means LiteLLM cannot route to the entry."""
        for i, entry in enumerate(_model_list(config)):
            name = entry.get("model_name")
            assert isinstance(name, str) and name, (
                f"model_list[{i}] has model_name={name!r}; every entry must have a "
                f"non-empty model_name (CONTEXT.md §1)."
            )

    def test_every_entry_targets_github_copilot(self, config):
        """litellm_params.model must use the github_copilot/ provider prefix.

        A typo in the prefix routes to the wrong LiteLLM provider and fails at
        runtime with a confusing error instead of at PR time.
        """
        for entry in _model_list(config):
            name = entry.get("model_name", "<unnamed>")
            model = entry.get("litellm_params", {}).get("model")
            assert isinstance(model, str) and model.startswith(COPILOT_MODEL_PREFIX), (
                f"Model '{name}' routes to {model!r}; expected a value starting with "
                f"{COPILOT_MODEL_PREFIX!r} (CONTEXT.md §1)."
            )

    def test_every_entry_has_all_required_headers(self, config):
        """Copilot rejects requests missing any of the four editor headers."""
        for entry in _model_list(config):
            name = entry.get("model_name", "<unnamed>")
            params = entry.get("litellm_params", {})
            assert isinstance(params.get("extra_headers"), dict), (
                f"Model '{name}' has no extra_headers mapping; the four editor "
                f"headers are required on every entry (CONTEXT.md §1)."
            )
            headers = _entry_headers(entry)
            missing = [k for k in REQUIRED_HEADER_KEYS if not headers.get(k)]
            assert not missing, (
                f"Model '{name}' is missing required editor header(s): {missing}. "
                f"Copilot validates these on every request (CONTEXT.md §1)."
            )

    def test_header_values_are_consistent_across_entries(self, config):
        """All entries (incl. the wildcard) must use identical header values.

        A per-model header edit would make only *some* models fail — a subtle,
        hard-to-diagnose partial outage.
        """
        model_list = _model_list(config)
        canonical = {k: _entry_headers(model_list[0]).get(k) for k in REQUIRED_HEADER_KEYS}
        for entry in model_list:
            name = entry.get("model_name", "<unnamed>")
            headers = _entry_headers(entry)
            for key in REQUIRED_HEADER_KEYS:
                assert headers.get(key) == canonical[key], (
                    f"Model '{name}' header {key}={headers.get(key)!r} diverges from the "
                    f"canonical value {canonical[key]!r} used by other entries. All "
                    f"entries must use identical header values (CONTEXT.md §1)."
                )


class TestScriptHeaderDrift:
    """scripts/list-copilot-models.sh hardcodes the same headers — they must not drift."""

    def _extract_script_headers(self):
        """Extract the four header values embedded as jq string literals.

        The values live in a jq string-concatenation expression as escaped
        literals, e.g.  ``+ "        Editor-Version: \\"vscode/1.106.3\\"\\n"``.
        The regex tolerates both escaped (``\\"``) and raw (``"``) quoting so a
        reformat of the jq filter does not silently defeat the check.
        """
        if not MODELS_SCRIPT_PATH.exists():
            pytest.skip(f"list-copilot-models.sh not found at {MODELS_SCRIPT_PATH}")
        text = MODELS_SCRIPT_PATH.read_text()
        found = {}
        for key in REQUIRED_HEADER_KEYS:
            match = re.search(rf'{re.escape(key)}:\s*\\?"([^"\\]+)\\?"', text)
            if match:
                found[key] = match.group(1)
        # Fail loudly on extraction failure — never silently pass (issue #80, risk 3).
        assert len(found) == len(REQUIRED_HEADER_KEYS), (
            f"Could not extract all four editor headers from {MODELS_SCRIPT_PATH.name}; "
            f"found only {sorted(found)}. The script's header block was likely "
            f"reformatted — update this test's regex or the script (CONTEXT.md §1)."
        )
        return found

    def test_script_headers_match_config(self, config):
        """Header values in list-copilot-models.sh must match litellm_config.yaml.

        The script generates config entries; if its hardcoded headers drift from
        the config, it silently emits entries with stale headers that Copilot
        would reject.
        """
        model_list = _model_list(config)
        config_headers = {k: _entry_headers(model_list[0]).get(k) for k in REQUIRED_HEADER_KEYS}
        script_headers = self._extract_script_headers()
        for key in REQUIRED_HEADER_KEYS:
            assert script_headers[key] == config_headers[key], (
                f"Header {key} drift: list-copilot-models.sh has {script_headers[key]!r} "
                f"but litellm_config.yaml has {config_headers[key]!r}. Update the script "
                f"when config headers change so generated entries stay valid (CONTEXT.md §1)."
            )
