"""Tests for litellm_logger — _extract_http_info helper and _emit integration.

RED phase: all tests for _extract_http_info should fail until the helper is
implemented; _emit integration tests should fail until the wiring is in place.
"""

from __future__ import annotations

import json
import sys
from io import StringIO
from types import SimpleNamespace

import pytest

sys.path.insert(0, ".")
from litellm_logger import _extract_http_info, _emit, ProxyObservabilityLogger


# ---------------------------------------------------------------------------
# Helpers to build fake httpx-like responses / exceptions
# ---------------------------------------------------------------------------


class FakeHttpxResponse:
    """Mimics httpx.Response with .status_code and .headers."""

    def __init__(self, status_code: int, headers: dict | None = None):
        self.status_code = status_code
        self.headers = headers or {}


class FakeException:
    """Mimics a LiteLLM exception that carries .status_code and .headers."""

    def __init__(self, status_code: int, headers: dict | None = None):
        self.status_code = status_code
        self.headers = headers or {}


# ===================================================================
# _extract_http_info — unit tests
# ===================================================================


class TestExtractHttpInfoFromOriginalResponse:
    """Extract http_status and ratelimit from kwargs['original_response']."""

    def test_status_code_extracted(self):
        kwargs = {"original_response": FakeHttpxResponse(200)}
        info = _extract_http_info(kwargs)
        assert info["http_status"] == 200

    def test_ratelimit_headers_extracted_and_prefix_stripped(self):
        headers = {
            "x-ratelimit-limit": "100",
            "x-ratelimit-remaining": "42",
            "x-ratelimit-reset": "1700000000",
            "content-type": "application/json",
        }
        kwargs = {"original_response": FakeHttpxResponse(200, headers)}
        info = _extract_http_info(kwargs)
        assert info["ratelimit"] == {
            "limit": "100",
            "remaining": "42",
            "reset": "1700000000",
        }

    def test_no_ratelimit_headers_omits_key(self):
        headers = {"content-type": "application/json"}
        kwargs = {"original_response": FakeHttpxResponse(200, headers)}
        info = _extract_http_info(kwargs)
        assert "ratelimit" not in info

    def test_429_with_ratelimit(self):
        headers = {
            "x-ratelimit-limit": "60",
            "x-ratelimit-remaining": "0",
            "x-ratelimit-reset": "1700000060",
        }
        kwargs = {"original_response": FakeHttpxResponse(429, headers)}
        info = _extract_http_info(kwargs)
        assert info["http_status"] == 429
        assert info["ratelimit"]["remaining"] == "0"


class TestExtractHttpInfoFromException:
    """Extract http_status and ratelimit from kwargs['exception']."""

    def test_status_code_from_exception(self):
        kwargs = {"exception": FakeException(429)}
        info = _extract_http_info(kwargs)
        assert info["http_status"] == 429

    def test_ratelimit_from_exception(self):
        headers = {
            "x-ratelimit-limit": "60",
            "x-ratelimit-remaining": "0",
        }
        kwargs = {"exception": FakeException(429, headers)}
        info = _extract_http_info(kwargs)
        assert info["ratelimit"] == {"limit": "60", "remaining": "0"}

    def test_exception_without_headers_attr(self):
        """An exception without .headers should not crash."""
        exc = Exception("boom")
        kwargs = {"exception": exc}
        info = _extract_http_info(kwargs)
        # http_status may be null but should not crash
        assert info["http_status"] is None


class TestExtractHttpInfoDefensive:
    """Defensive behaviour: never raise, degrade gracefully."""

    def test_empty_kwargs(self):
        info = _extract_http_info({})
        assert info["http_status"] is None
        assert "ratelimit" not in info

    def test_none_kwargs(self):
        info = _extract_http_info(None)
        assert info["http_status"] is None

    def test_non_dict_kwargs(self):
        info = _extract_http_info("garbage")
        assert info["http_status"] is None

    def test_original_response_is_string(self):
        """original_response might be a raw string in some LiteLLM paths."""
        kwargs = {"original_response": "some raw text"}
        info = _extract_http_info(kwargs)
        assert info["http_status"] is None

    def test_original_response_with_broken_headers(self):
        """If .headers raises, we still get http_status."""

        class BadHeaders:
            status_code = 200

            @property
            def headers(self):
                raise RuntimeError("broken")

        kwargs = {"original_response": BadHeaders()}
        info = _extract_http_info(kwargs)
        assert info["http_status"] == 200
        assert "ratelimit" not in info

    def test_both_original_response_and_exception_prefers_original(self):
        """When both are present, original_response takes precedence."""
        kwargs = {
            "original_response": FakeHttpxResponse(200),
            "exception": FakeException(500),
        }
        info = _extract_http_info(kwargs)
        assert info["http_status"] == 200

    def test_ratelimit_header_case_insensitive(self):
        """Headers should be matched case-insensitively."""
        headers = {"X-RateLimit-Remaining": "5"}
        kwargs = {"original_response": FakeHttpxResponse(200, headers)}
        info = _extract_http_info(kwargs)
        assert info["ratelimit"] == {"remaining": "5"}


# ===================================================================
# _emit integration — http_status and ratelimit in PROXY_LOG
# ===================================================================


def _capture_emit(kwargs, response_obj=None, status="success"):
    """Call _emit and capture the PROXY_LOG line from stdout."""
    from datetime import datetime

    start = datetime(2024, 1, 1, 0, 0, 0)
    end = datetime(2024, 1, 1, 0, 0, 1)

    buf = StringIO()
    old_stdout = sys.stdout
    try:
        sys.stdout = buf
        _emit(kwargs, response_obj, start, end, status)
    finally:
        sys.stdout = old_stdout

    line = buf.getvalue().strip()
    assert line.startswith("PROXY_LOG "), f"Expected PROXY_LOG prefix, got: {line!r}"
    return json.loads(line[len("PROXY_LOG "):])


class TestEmitHttpInfo:
    """Verify _emit includes http_status and ratelimit from kwargs."""

    def test_emit_includes_http_status(self):
        kwargs = {
            "model": "test-model",
            "call_type": "completion",
            "original_response": FakeHttpxResponse(200),
        }
        rec = _capture_emit(kwargs)
        assert rec["http_status"] == 200

    def test_emit_omits_ratelimit_when_absent(self):
        kwargs = {
            "model": "test-model",
            "call_type": "completion",
            "original_response": FakeHttpxResponse(200, {"content-type": "application/json"}),
        }
        rec = _capture_emit(kwargs)
        assert "ratelimit" not in rec

    def test_emit_includes_ratelimit_when_present(self):
        kwargs = {
            "model": "test-model",
            "call_type": "completion",
            "original_response": FakeHttpxResponse(
                200,
                {"x-ratelimit-remaining": "10", "x-ratelimit-limit": "100"},
            ),
        }
        rec = _capture_emit(kwargs)
        assert rec["ratelimit"] == {"remaining": "10", "limit": "100"}

    def test_emit_429_failure_with_ratelimit(self):
        kwargs = {
            "model": "test-model",
            "call_type": "completion",
            "exception": FakeException(
                429,
                {
                    "x-ratelimit-limit": "60",
                    "x-ratelimit-remaining": "0",
                    "x-ratelimit-reset": "1700000060",
                },
            ),
        }
        rec = _capture_emit(kwargs, status="failure")
        assert rec["http_status"] == 429
        assert rec["ratelimit"]["remaining"] == "0"

    def test_emit_null_http_status_when_no_response(self):
        kwargs = {"model": "test-model", "call_type": "completion"}
        rec = _capture_emit(kwargs)
        assert rec["http_status"] is None

    def test_emit_never_logs_content(self):
        """Ensure no message content leaks into the log line."""
        kwargs = {
            "model": "test-model",
            "call_type": "completion",
            "original_response": FakeHttpxResponse(200),
        }
        response_obj = {
            "choices": [
                {
                    "finish_reason": "stop",
                    "message": {"content": "SECRET_CONTENT_SHOULD_NOT_APPEAR"},
                }
            ],
            "usage": {"completion_tokens": 10},
        }
        rec = _capture_emit(kwargs, response_obj=response_obj)
        raw_line = json.dumps(rec)
        assert "SECRET_CONTENT_SHOULD_NOT_APPEAR" not in raw_line


# ===================================================================
# _emit integration — stream field in PROXY_LOG
# ===================================================================


class TestEmitStreamField:
    """Verify _emit includes stream indicator from kwargs."""

    def test_emit_stream_true_when_stream_in_kwargs(self):
        """When kwargs['stream'] is True, log should record stream=True."""
        kwargs = {
            "model": "test-model",
            "call_type": "completion",
            "stream": True,
            "original_response": FakeHttpxResponse(200),
        }
        rec = _capture_emit(kwargs)
        assert rec["stream"] is True

    def test_emit_stream_false_when_stream_false_in_kwargs(self):
        """When kwargs['stream'] is False, log should record stream=False."""
        kwargs = {
            "model": "test-model",
            "call_type": "completion",
            "stream": False,
            "original_response": FakeHttpxResponse(200),
        }
        rec = _capture_emit(kwargs)
        assert rec["stream"] is False

    def test_emit_stream_none_when_missing(self):
        """When kwargs has no 'stream' key, log should record stream=None."""
        kwargs = {
            "model": "test-model",
            "call_type": "completion",
            "original_response": FakeHttpxResponse(200),
        }
        rec = _capture_emit(kwargs)
        assert rec["stream"] is None


# ===================================================================
# ProxyObservabilityLogger — streaming callback methods
# ===================================================================


class TestStreamingCallbacks:
    """Verify logger handles streaming success/failure callbacks."""

    def _capture_logger_call(self, method_name, kwargs, response_obj=None):
        """Call a logger method and capture the PROXY_LOG line."""
        from datetime import datetime
        import asyncio

        start = datetime(2024, 1, 1, 0, 0, 0)
        end = datetime(2024, 1, 1, 0, 0, 1)
        logger = ProxyObservabilityLogger()

        buf = StringIO()
        old_stdout = sys.stdout
        try:
            sys.stdout = buf
            method = getattr(logger, method_name)
            if method_name.startswith("async_"):
                asyncio.run(method(kwargs, response_obj, start, end))
            else:
                method(kwargs, response_obj, start, end)
        finally:
            sys.stdout = old_stdout

        line = buf.getvalue().strip()
        assert line.startswith("PROXY_LOG "), f"Expected PROXY_LOG prefix, got: {line!r}"
        return json.loads(line[len("PROXY_LOG "):])

    def test_log_stream_success_event(self):
        """log_stream_event should log with status=success and stream=True."""
        kwargs = {"model": "test-model", "call_type": "completion", "stream": True}
        response_obj = {
            "choices": [{"finish_reason": "stop", "message": {"content": "hello"}}],
            "usage": {"completion_tokens": 5},
        }
        rec = self._capture_logger_call("log_stream_event", kwargs, response_obj)
        assert rec["status"] == "success"
        assert rec["stream"] is True

    def test_async_log_stream_success_event(self):
        """async_log_stream_event should log with status=success and stream=True."""
        kwargs = {"model": "test-model", "call_type": "completion", "stream": True}
        response_obj = {
            "choices": [{"finish_reason": "stop", "message": {"content": "hello"}}],
            "usage": {"completion_tokens": 5},
        }
        rec = self._capture_logger_call("async_log_stream_event", kwargs, response_obj)
        assert rec["status"] == "success"
        assert rec["stream"] is True

