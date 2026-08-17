"""Tests for scripts/generate_config.py.

The config generator makes the "Copilot model route" a single-source
abstraction (refs #108): a compact alias → {primary, fallback} mapping emits the
full litellm_config.yaml, so adding a model is a one-line edit and the four
editor headers appear in exactly one place.

The key invariant is drift: the committed litellm_config.yaml must be exactly
what the generator produces. If someone hand-edits the YAML (bypassing the
abstraction) or changes the mapping without regenerating, CI fails.

Refs #108, #130
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import generate_config  # noqa: E402  (import after sys.path setup)

CONFIG_PATH = REPO_ROOT / "litellm_config.yaml"


def _committed_config() -> dict:
    if not CONFIG_PATH.exists():
        pytest.skip(f"litellm_config.yaml not found at {CONFIG_PATH}")
    data = yaml.safe_load(CONFIG_PATH.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        pytest.fail(
            f"litellm_config.yaml did not parse as a mapping (got {type(data).__name__})"
        )
    return data


def test_generated_yaml_matches_committed():
    """The committed YAML must be exactly what the generator emits (no drift).

    This single guard subsumes the generator's structural contract: the emitted
    top-level blocks, router fallback wiring, editor headers, and per-alias
    provider prefixes are all pinned by the committed YAML matching the generator
    output byte-for-byte. The independently-asserted structural contracts for the
    committed config live in test_model_entry_contract.py, test_settings_contract.py,
    and test_routing_contract.py (refs #80, #119, #113).
    """
    generated = generate_config.generate_config()
    assert isinstance(generated, str) and generated.strip(), (
        "generate_config() must return a non-empty YAML string"
    )
    generated_data = yaml.safe_load(generated)
    assert isinstance(generated_data, dict), (
        "generated config did not parse as a mapping"
    )
    assert generated_data == _committed_config(), (
        "litellm_config.yaml has drifted from generate_config.py output. "
        "Regenerate with 'python3 scripts/generate_config.py' (or 'make "
        "generate-config') and commit the result."
    )
