"""Unit tests for scripts/probe_parser.py.

Covers the response-classification and outcome-resolution logic extracted from
probe_completion.sh (refs #112). These are pure functions — no network, no
subprocess — so every edge case is testable deterministically.

Refs #112
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import probe_parser  # noqa: E402


class TestClassifyResponse:
    def test_valid_json_with_content(self):
        r = probe_parser.classify_response("200", '{"content": "hi"}')
        assert r["has_content"] is True
        assert r["format"] == "json"
        assert r["is_hard_error"] is False

    def test_valid_json_without_content(self):
        r = probe_parser.classify_response("200", '{"content": ""}')
        assert r["has_content"] is False
        assert r["format"] == "json"
        assert r["is_hard_error"] is False

    def test_sse_with_content_block_delta(self):
        body = (
            'data: {"type": "content_block_delta", "delta": {"text": "hi"}}\n'
            "data: [DONE]\n"
        )
        r = probe_parser.classify_response("200", body)
        assert r["has_content"] is True
        assert r["format"] == "sse"

    def test_sse_with_no_text_deltas(self):
        body = 'data: {"type": "content_block_delta", "delta": {"text": ""}}\n'
        r = probe_parser.classify_response("200", body)
        assert r["has_content"] is False
        assert r["format"] == "sse"

    def test_non_json_non_sse_200_is_hard_error(self):
        r = probe_parser.classify_response("200", "not json at all")
        assert r["is_hard_error"] is True
        assert "not valid JSON" in r["error_detail"]

    @pytest.mark.parametrize("code", ["400", "401", "403", "500", "502", "503", "000"])
    def test_hard_error_codes(self, code):
        r = probe_parser.classify_response(code, "{}")
        assert r["is_hard_error"] is True
        assert r["error_detail"]

    def test_retryable_code_is_not_hard(self):
        r = probe_parser.classify_response("429", "{}")
        assert r["is_hard_error"] is False


class TestResolveOutcome:
    def test_ok_when_any_attempt_has_content(self):
        attempts = [
            {"has_content": False, "is_hard_error": False},
            {"has_content": True, "is_hard_error": False},
        ]
        r = probe_parser.resolve_outcome(attempts, retries=2)
        assert r["status"] == "ok"

    def test_fail_on_hard_error(self):
        attempts = [
            {"has_content": False, "is_hard_error": True, "error_detail": "auth error HTTP 401"},
        ]
        r = probe_parser.resolve_outcome(attempts, retries=1)
        assert r["status"] == "fail"
        assert "auth error" in r["detail"]

    def test_degraded_when_all_empty(self):
        attempts = [
            {"has_content": False, "is_hard_error": False},
            {"has_content": False, "is_hard_error": False},
        ]
        r = probe_parser.resolve_outcome(attempts, retries=2)
        assert r["status"] == "degraded"

    def test_fail_when_retries_zero(self):
        r = probe_parser.resolve_outcome([], retries=0)
        assert r["status"] == "fail"
        assert "no probe attempts" in r["detail"]

    def test_fail_when_no_attempts_and_retries_positive(self):
        r = probe_parser.resolve_outcome([], retries=3)
        assert r["status"] == "fail"
