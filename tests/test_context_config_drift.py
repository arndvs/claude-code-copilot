"""Drift checks between CONTEXT.md and litellm_config.yaml.

CONTEXT.md is the agent-facing contract for the proxy. These tests make the
machine-verifiable routing, header, and LiteLLM settings claims fail in CI when
the config changes without the context document changing with it.

Refs #94
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest
import yaml


REPO_ROOT = Path(__file__).resolve().parent.parent
CONTEXT_PATH = REPO_ROOT / "CONTEXT.md"
CONFIG_PATH = REPO_ROOT / "litellm_config.yaml"


@pytest.fixture
def context_text() -> str:
    if not CONTEXT_PATH.exists():
        pytest.skip(f"CONTEXT.md not found at {CONTEXT_PATH}")
    return CONTEXT_PATH.read_text(encoding="utf-8")


@pytest.fixture
def config() -> dict:
    if not CONFIG_PATH.exists():
        pytest.skip(f"litellm_config.yaml not found at {CONFIG_PATH}")
    data = yaml.safe_load(CONFIG_PATH.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        pytest.fail(
            f"litellm_config.yaml did not parse as a mapping (got {type(data).__name__})"
        )
    return data


def _section(text: str, heading: str, next_heading: str) -> str:
    match = re.search(
        rf"^## {re.escape(heading)}\s*$([\s\S]*?)^## {re.escape(next_heading)}\s*$",
        text,
        flags=re.MULTILINE,
    )
    assert match, f"Could not find CONTEXT.md section {heading!r}"
    return match.group(1)


def _between(text: str, start: str, end: str) -> str:
    start_index = text.index(start)
    end_index = text.index(end, start_index)
    return text[start_index:end_index]


def _context_table(markdown: str) -> dict[str, str]:
    rows: dict[str, str] = {}
    for line in markdown.splitlines():
        match = re.match(r"^\|\s*`([^`]+)`[^|]*\|\s*`([^`]+)`", line)
        if match:
            rows[match.group(1)] = match.group(2)
    return rows


def _config_model_map(config: dict) -> dict[str, str]:
    """Map primary (non-fallback) model_names to their Copilot target.

    The CONTEXT.md table documents the primary Copilot target for each alias,
    so fallback (OpenRouter) entries are excluded here.
    """
    model_list = config.get("model_list", [])
    assert isinstance(model_list, list) and model_list, "model_list must be non-empty"
    result: dict[str, str] = {}
    for entry in model_list:
        name = entry.get("model_name", "")
        if name.endswith("-fallback"):
            continue
        result[name] = entry["litellm_params"]["model"]
    return result


def test_context_model_mapping_matches_litellm_config(context_text, config):
    section = _section(context_text, "1. LiteLLM → Copilot routing (with OpenRouter fallback)", "2. DB-less default mode")
    model_table = _between(
        section,
        "| Alias (Claude Code sends) | Primary (Copilot) | Fallback (OpenRouter) |",
        "Primary entries carry the four editor headers",
    )
    assert _context_table(model_table) == _config_model_map(config)


def test_context_litellm_settings_claims_match_config(context_text, config):
    settings = config.get("litellm_settings", {})
    assert isinstance(settings, dict), "litellm_settings must be a mapping"

    expected_snippets = (
        f"`drop_params: {str(settings['drop_params']).lower()}`",
        f"`additional_drop_params: {json.dumps(settings['additional_drop_params'])}`",
        f"`json_logs: {str(settings['json_logs']).lower()}`",
        f"`callbacks: {json.dumps(settings['callbacks'])}`",
    )

    for snippet in expected_snippets:
        assert snippet in context_text
