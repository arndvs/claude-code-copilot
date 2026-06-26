"""Tests for streaming support in litellm_config.yaml.

Verifies that all model routes have `stream: true` configured, ensuring the
proxy uses streaming mode to reduce empty-content 200 responses from the
Anthropic adapter.

Refs #49
"""

from __future__ import annotations

import yaml
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = REPO_ROOT / "litellm_config.yaml"


@pytest.fixture
def config():
    """Load and return the parsed litellm_config.yaml."""
    with open(CONFIG_PATH) as f:
        return yaml.safe_load(f)


class TestStreamingEnabled:
    """All model_list entries must have stream: true in litellm_params."""

    def test_config_file_exists(self):
        """Config file existence check — does not require the config fixture."""
        assert CONFIG_PATH.exists(), "litellm_config.yaml not found at repo root"

    def test_all_models_have_stream_true(self, config):
        """Every model alias must set stream: true to enable streaming."""
        model_list = config.get("model_list", [])
        assert model_list, "model_list is empty"

        for entry in model_list:
            name = entry.get("model_name", "<unnamed>")
            params = entry.get("litellm_params", {})
            stream_val = params.get("stream")
            assert stream_val is True, (
                f"Model '{name}' has stream={stream_val!r}, expected True. "
                f"Streaming reduces empty-content 200s from the Anthropic adapter."
            )

    def test_global_settings_do_not_override_stream_false(self, config):
        """litellm_settings must not globally force stream: false."""
        settings = config.get("litellm_settings", {})
        # stream should either not be set globally, or be True
        stream_val = settings.get("stream")
        assert stream_val is not False, (
            f"litellm_settings has stream={stream_val!r} which would override "
            f"per-model stream: true"
        )
