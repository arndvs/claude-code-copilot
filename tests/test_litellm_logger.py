"""Tests for litellm_logger — comprehensive unit tests.

Covers:
- _duration_ms: datetime objects, numeric timestamps, error cases
- _extract: OpenAI-style choices (dict/object), Anthropic-style content blocks,
  empty/missing content, non-string content, usage extraction
- _extract_http_info: status code, ratelimit headers, defensive behavior
- _emit: integration test verifying JSON structure, field presence, no content leak

Uses only stdlib (unittest). No external test dependencies.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import unittest
from datetime import datetime
from io import StringIO
from types import SimpleNamespace

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from litellm_logger import _duration_ms, _extract, _extract_http_info, _emit, ProxyObservabilityLogger


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
# _duration_ms — unit tests
# ===================================================================


class TestDurationMs(unittest.TestCase):
    """Test _duration_ms with datetime objects and numeric timestamps."""

    def test_datetime_and_numeric_inputs(self):
        # Datetime objects.
        self.assertEqual(_duration_ms(datetime(2024, 1, 1), datetime(2024, 1, 1, 0, 0, 1)), 1000)
        self.assertEqual(
            _duration_ms(
                datetime(2024, 1, 1, 0, 0, 0, 0),
                datetime(2024, 1, 1, 0, 0, 0, 500000),
            ),
            500,
        )
        t = datetime(2024, 1, 1, 12, 0, 0)
        self.assertEqual(_duration_ms(t, t), 0)
        self.assertEqual(
            _duration_ms(datetime(2024, 1, 1, 0, 0, 0), datetime(2024, 1, 1, 1, 0, 0)),
            3600000,
        )
        # Numeric Unix timestamps (float/int) — delta is in seconds.
        self.assertEqual(_duration_ms(1700000000.0, 1700000002.5), 2500)
        self.assertEqual(_duration_ms(1700000000, 1700000003), 3000)
        self.assertEqual(_duration_ms(1700000000.0, 1700000000.0), 0)
        # Decimal rounding on microsecond-precision datetimes.
        self.assertEqual(
            _duration_ms(
                datetime(2024, 1, 1, 0, 0, 0, 0),
                datetime(2024, 1, 1, 0, 0, 0, 1500),  # 1.5ms → round(1.5)=2
            ),
            2,
        )

    def test_unusable_inputs_return_none(self):
        """None or type-mismatched inputs must return None (never raise)."""
        self.assertIsNone(_duration_ms(None, None))
        self.assertIsNone(_duration_ms("bad", 123))


# ===================================================================
# _extract — unit tests
# ===================================================================


class TestExtractOpenAIStyleDict(unittest.TestCase):
    """Test _extract with OpenAI-style choices as dicts."""

    def test_basic_choices_dict(self):
        response = {
            "choices": [
                {
                    "finish_reason": "stop",
                    "message": {"content": "Hello world"},
                }
            ],
            "usage": {"completion_tokens": 5},
        }
        finish, content_len, ctoks = _extract(response)
        self.assertEqual(finish, "stop")
        self.assertEqual(content_len, 11)  # len("Hello world")
        self.assertEqual(ctoks, 5)

    def test_empty_content_string(self):
        response = {
            "choices": [
                {
                    "finish_reason": "stop",
                    "message": {"content": ""},
                }
            ],
            "usage": {"completion_tokens": 0},
        }
        finish, content_len, ctoks = _extract(response)
        self.assertEqual(finish, "stop")
        self.assertEqual(content_len, 0)
        self.assertEqual(ctoks, 0)

    def test_none_content(self):
        """When content is None, content_len should be 0."""
        response = {
            "choices": [
                {
                    "finish_reason": "stop",
                    "message": {"content": None},
                }
            ],
            "usage": {"completion_tokens": 3},
        }
        finish, content_len, ctoks = _extract(response)
        self.assertEqual(finish, "stop")
        self.assertEqual(content_len, 0)
        self.assertEqual(ctoks, 3)

    def test_non_string_content_tool_calls(self):
        """Non-string content (e.g. tool call list) gives content_len=-1."""
        response = {
            "choices": [
                {
                    "finish_reason": "tool_calls",
                    "message": {"content": [{"type": "function", "name": "foo"}]},
                }
            ],
            "usage": {"completion_tokens": 10},
        }
        finish, content_len, ctoks = _extract(response)
        self.assertEqual(finish, "tool_calls")
        self.assertEqual(content_len, -1)
        self.assertEqual(ctoks, 10)

    def test_missing_usage(self):
        """When usage is missing, completion_tokens should be None."""
        response = {
            "choices": [
                {
                    "finish_reason": "length",
                    "message": {"content": "truncated"},
                }
            ],
        }
        finish, content_len, ctoks = _extract(response)
        self.assertEqual(finish, "length")
        self.assertEqual(content_len, 9)  # len("truncated")
        self.assertIsNone(ctoks)

    def test_missing_message(self):
        """When message is missing from choice, content_len should be 0."""
        response = {
            "choices": [{"finish_reason": "stop", "message": None}],
            "usage": {"completion_tokens": 0},
        }
        finish, content_len, ctoks = _extract(response)
        self.assertEqual(finish, "stop")
        # message is None, isinstance(None, dict) is False, so content stays None
        # then content in (None, "") is True => content_len = 0
        self.assertEqual(content_len, 0)
        self.assertEqual(ctoks, 0)


class TestExtractOpenAIStyleObject(unittest.TestCase):
    """Test _extract with OpenAI-style choices as objects (SimpleNamespace)."""

    def test_object_style_response(self):
        msg = SimpleNamespace(content="Hello from object")
        choice = SimpleNamespace(finish_reason="stop", message=msg)
        response = SimpleNamespace(
            choices=[choice],
            content=None,
            usage=SimpleNamespace(completion_tokens=7),
        )
        finish, content_len, ctoks = _extract(response)
        self.assertEqual(finish, "stop")
        self.assertEqual(content_len, 17)  # len("Hello from object")
        self.assertEqual(ctoks, 7)

    def test_object_style_none_content(self):
        msg = SimpleNamespace(content=None)
        choice = SimpleNamespace(finish_reason="stop", message=msg)
        response = SimpleNamespace(
            choices=[choice],
            content=None,
            usage=SimpleNamespace(completion_tokens=0),
        )
        finish, content_len, ctoks = _extract(response)
        self.assertEqual(finish, "stop")
        self.assertEqual(content_len, 0)
        self.assertEqual(ctoks, 0)

    def test_object_style_no_usage(self):
        msg = SimpleNamespace(content="data")
        choice = SimpleNamespace(finish_reason="stop", message=msg)
        response = SimpleNamespace(choices=[choice], content=None, usage=None)
        finish, content_len, ctoks = _extract(response)
        self.assertEqual(finish, "stop")
        self.assertEqual(content_len, 4)
        self.assertIsNone(ctoks)


class TestExtractAnthropicStyle(unittest.TestCase):
    """Test _extract with Anthropic-style /v1/messages content blocks."""

    def test_text_block_list(self):
        """Standard Anthropic response with text blocks."""
        response = {
            "content": [
                {"type": "text", "text": "Hello "},
                {"type": "text", "text": "world"},
            ],
            "stop_reason": "end_turn",
            "usage": {"completion_tokens": 4},
        }
        finish, content_len, ctoks = _extract(response)
        self.assertEqual(finish, "end_turn")
        self.assertEqual(content_len, 11)  # "Hello " + "world"
        self.assertEqual(ctoks, 4)

    def test_empty_text_blocks(self):
        """Text blocks with empty text should give content_len=0."""
        response = {
            "content": [{"type": "text", "text": ""}],
            "stop_reason": "end_turn",
            "usage": {"completion_tokens": 0},
        }
        finish, content_len, ctoks = _extract(response)
        self.assertEqual(finish, "end_turn")
        self.assertEqual(content_len, 0)
        self.assertEqual(ctoks, 0)

    def test_empty_content_list(self):
        """An empty content list should give content_len=0."""
        response = {
            "content": [],
            "stop_reason": "end_turn",
            "usage": {"completion_tokens": 0},
        }
        finish, content_len, ctoks = _extract(response)
        self.assertEqual(finish, "end_turn")
        self.assertEqual(content_len, 0)
        self.assertEqual(ctoks, 0)

    def test_tool_use_blocks_ignored_for_text_length(self):
        """Only text blocks are counted for content_len."""
        response = {
            "content": [
                {"type": "text", "text": "Using tool"},
                {"type": "tool_use", "id": "x", "name": "foo", "input": {}},
            ],
            "stop_reason": "tool_use",
            "usage": {"completion_tokens": 15},
        }
        finish, content_len, ctoks = _extract(response)
        self.assertEqual(finish, "tool_use")
        self.assertEqual(content_len, 10)  # only "Using tool"
        self.assertEqual(ctoks, 15)

    def test_anthropic_object_style(self):
        """Anthropic-style response as SimpleNamespace objects."""
        block = SimpleNamespace(type="text", text="Object text")
        response = SimpleNamespace(
            choices=None,
            content=[block],
            stop_reason="end_turn",
            usage=SimpleNamespace(completion_tokens=3),
        )
        finish, content_len, ctoks = _extract(response)
        self.assertEqual(finish, "end_turn")
        self.assertEqual(content_len, 11)  # len("Object text")
        self.assertEqual(ctoks, 3)

    def test_content_is_string(self):
        """When content is a plain string (unusual but possible)."""
        response = {
            "content": "Plain string content",
            "stop_reason": "end_turn",
            "usage": {"completion_tokens": 5},
        }
        finish, content_len, ctoks = _extract(response)
        self.assertEqual(finish, "end_turn")
        self.assertEqual(content_len, 20)  # len("Plain string content")
        self.assertEqual(ctoks, 5)

    def test_content_is_non_list_non_string(self):
        """When content is neither list nor string, content_len=-1."""
        response = {
            "content": 12345,
            "stop_reason": "end_turn",
            "usage": {"completion_tokens": 1},
        }
        finish, content_len, ctoks = _extract(response)
        self.assertEqual(finish, "end_turn")
        self.assertEqual(content_len, -1)
        self.assertEqual(ctoks, 1)


class TestExtractDefensive(unittest.TestCase):
    """Defensive behavior: _extract never raises on malformed input."""

    def test_malformed_inputs_never_raise(self):
        # None, empty dict, and garbage all degrade to None (no crash).
        for bad in (None, {}, "not a response"):
            finish, content_len, ctoks = _extract(bad)
            self.assertIsNone(finish)
            self.assertIsNone(content_len)
            self.assertIsNone(ctoks)

    def test_empty_choices_list(self):
        """Empty choices list should not crash (IndexError)."""
        response = {"choices": [], "usage": {"completion_tokens": 0}}
        finish, content_len, ctoks = _extract(response)
        # choices is truthy? No, [] is falsy in Python. Falls through.
        self.assertIsNone(finish)
        self.assertIsNone(content_len)
        self.assertEqual(ctoks, 0)


# ===================================================================
# _extract_http_info — unit tests
# ===================================================================


class TestExtractHttpInfoFromOriginalResponse(unittest.TestCase):
    """Extract http_status and ratelimit from kwargs['original_response']."""

    def test_status_code_extracted(self):
        kwargs = {"original_response": FakeHttpxResponse(200)}
        info = _extract_http_info(kwargs)
        self.assertEqual(info["http_status"], 200)

    def test_ratelimit_headers_extracted_and_prefix_stripped(self):
        headers = {
            "x-ratelimit-limit": "100",
            "x-ratelimit-remaining": "42",
            "x-ratelimit-reset": "1700000000",
            "content-type": "application/json",
        }
        kwargs = {"original_response": FakeHttpxResponse(200, headers)}
        info = _extract_http_info(kwargs)
        self.assertEqual(
            info["ratelimit"],
            {"limit": "100", "remaining": "42", "reset": "1700000000"},
        )

    def test_no_ratelimit_headers_omits_key(self):
        headers = {"content-type": "application/json"}
        kwargs = {"original_response": FakeHttpxResponse(200, headers)}
        info = _extract_http_info(kwargs)
        self.assertNotIn("ratelimit", info)

    def test_429_with_ratelimit(self):
        headers = {
            "x-ratelimit-limit": "60",
            "x-ratelimit-remaining": "0",
            "x-ratelimit-reset": "1700000060",
        }
        kwargs = {"original_response": FakeHttpxResponse(429, headers)}
        info = _extract_http_info(kwargs)
        self.assertEqual(info["http_status"], 429)
        self.assertEqual(info["ratelimit"]["remaining"], "0")


class TestExtractHttpInfoFromException(unittest.TestCase):
    """Extract http_status and ratelimit from kwargs['exception']."""

    def test_status_code_from_exception(self):
        kwargs = {"exception": FakeException(429)}
        info = _extract_http_info(kwargs)
        self.assertEqual(info["http_status"], 429)

    def test_ratelimit_from_exception(self):
        headers = {
            "x-ratelimit-limit": "60",
            "x-ratelimit-remaining": "0",
        }
        kwargs = {"exception": FakeException(429, headers)}
        info = _extract_http_info(kwargs)
        self.assertEqual(info["ratelimit"], {"limit": "60", "remaining": "0"})

    def test_exception_without_headers_attr(self):
        """An exception without .headers should not crash."""
        exc = Exception("boom")
        kwargs = {"exception": exc}
        info = _extract_http_info(kwargs)
        # Exception does not have .status_code so http_status should be None
        self.assertIsNone(info["http_status"])


class TestExtractHttpInfoDefensive(unittest.TestCase):
    """Defensive behaviour: never raise, degrade gracefully."""

    def test_missing_or_malformed_kwargs(self):
        # None, non-dict, empty dict, and a raw-string original_response all
        # degrade to a null http_status with no ratelimit (never raise).
        for bad in ({}, None, "garbage", {"original_response": "some raw text"}):
            info = _extract_http_info(bad)
            self.assertIsNone(info["http_status"])
            self.assertNotIn("ratelimit", info)

    def test_original_response_with_broken_headers(self):
        """If .headers raises, we still get http_status."""

        class BadHeaders:
            status_code = 200

            @property
            def headers(self):
                raise RuntimeError("broken")

        kwargs = {"original_response": BadHeaders()}
        info = _extract_http_info(kwargs)
        self.assertEqual(info["http_status"], 200)
        self.assertNotIn("ratelimit", info)

    def test_both_original_response_and_exception_prefers_original(self):
        """When both are present, original_response takes precedence."""
        kwargs = {
            "original_response": FakeHttpxResponse(200),
            "exception": FakeException(500),
        }
        info = _extract_http_info(kwargs)
        self.assertEqual(info["http_status"], 200)

    def test_ratelimit_header_case_insensitive(self):
        """Headers should be matched case-insensitively."""
        headers = {"X-RateLimit-Remaining": "5"}
        kwargs = {"original_response": FakeHttpxResponse(200, headers)}
        info = _extract_http_info(kwargs)
        self.assertEqual(info["ratelimit"], {"remaining": "5"})


# ===================================================================
# _emit integration — full PROXY_LOG output validation
# ===================================================================


def _capture_emit(kwargs, response_obj=None, status="success"):
    """Call _emit and capture the PROXY_LOG line from stdout."""
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
    if not line.startswith("PROXY_LOG "):
        raise AssertionError(f"Expected PROXY_LOG prefix, got: {line!r}")
    return json.loads(line[len("PROXY_LOG "):])


class TestEmitHttpInfo(unittest.TestCase):
    """Verify _emit includes http_status and ratelimit from kwargs."""

    def test_emit_includes_http_status(self):
        kwargs = {
            "model": "test-model",
            "call_type": "completion",
            "original_response": FakeHttpxResponse(200),
        }
        rec = _capture_emit(kwargs)
        self.assertEqual(rec["http_status"], 200)

    def test_emit_omits_ratelimit_when_absent(self):
        kwargs = {
            "model": "test-model",
            "call_type": "completion",
            "original_response": FakeHttpxResponse(200, {"content-type": "application/json"}),
        }
        rec = _capture_emit(kwargs)
        self.assertNotIn("ratelimit", rec)

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
        self.assertEqual(rec["ratelimit"], {"remaining": "10", "limit": "100"})

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
        self.assertEqual(rec["http_status"], 429)
        self.assertEqual(rec["ratelimit"]["remaining"], "0")

    def test_emit_null_http_status_when_no_response(self):
        kwargs = {"model": "test-model", "call_type": "completion"}
        rec = _capture_emit(kwargs)
        self.assertIsNone(rec["http_status"])

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
        self.assertNotIn("SECRET_CONTENT_SHOULD_NOT_APPEAR", raw_line)


class TestEmitJsonStructure(unittest.TestCase):
    """Verify the full JSON record structure from _emit."""

    def test_all_expected_fields_present(self):
        kwargs = {
            "model": "gpt-4",
            "call_type": "completion",
            "original_response": FakeHttpxResponse(200),
        }
        response_obj = {
            "choices": [
                {
                    "finish_reason": "stop",
                    "message": {"content": "Hi"},
                }
            ],
            "usage": {"completion_tokens": 1},
        }
        rec = _capture_emit(kwargs, response_obj=response_obj)
        # Required fields
        self.assertEqual(rec["t"], "proxy_log")
        self.assertEqual(rec["status"], "success")
        self.assertEqual(rec["model"], "gpt-4")
        self.assertEqual(rec["call_type"], "completion")
        self.assertEqual(rec["ms"], 1000)
        self.assertEqual(rec["finish"], "stop")
        self.assertEqual(rec["content_len"], 2)
        self.assertEqual(rec["completion_tokens"], 1)
        self.assertFalse(rec["upstream_empty"])
        self.assertEqual(rec["http_status"], 200)

    def test_upstream_empty_flag_when_content_empty(self):
        kwargs = {
            "model": "test",
            "call_type": "completion",
            "original_response": FakeHttpxResponse(200),
        }
        response_obj = {
            "choices": [
                {
                    "finish_reason": "stop",
                    "message": {"content": ""},
                }
            ],
            "usage": {"completion_tokens": 0},
        }
        rec = _capture_emit(kwargs, response_obj=response_obj, status="success")
        self.assertTrue(rec["upstream_empty"])

    def test_upstream_empty_false_on_failure(self):
        """upstream_empty should be False even if content is empty on failure."""
        kwargs = {
            "model": "test",
            "call_type": "completion",
            "exception": FakeException(500),
        }
        response_obj = {
            "choices": [
                {
                    "finish_reason": "stop",
                    "message": {"content": ""},
                }
            ],
            "usage": {"completion_tokens": 0},
        }
        rec = _capture_emit(kwargs, response_obj=response_obj, status="failure")
        self.assertFalse(rec["upstream_empty"])

    def test_emit_with_anthropic_style_response(self):
        kwargs = {
            "model": "claude-3",
            "call_type": "completion",
            "original_response": FakeHttpxResponse(200),
        }
        response_obj = {
            "content": [
                {"type": "text", "text": "Hello from Claude"},
            ],
            "stop_reason": "end_turn",
            "usage": {"completion_tokens": 5},
        }
        rec = _capture_emit(kwargs, response_obj=response_obj)
        self.assertEqual(rec["finish"], "end_turn")
        self.assertEqual(rec["content_len"], 17)
        self.assertEqual(rec["completion_tokens"], 5)
        self.assertFalse(rec["upstream_empty"])

    def test_emit_defensive_on_bad_response_obj(self):
        """_emit should not crash even if response_obj is garbage."""
        kwargs = {
            "model": "test",
            "call_type": "completion",
            "original_response": FakeHttpxResponse(200),
        }
        # This should degrade gracefully
        rec = _capture_emit(kwargs, response_obj="not a real response")
        self.assertEqual(rec["status"], "success")
        self.assertEqual(rec["http_status"], 200)

    def test_emit_records_stream_field_from_kwargs(self):
        """The stream field reflects kwargs: true, false, or null when missing."""
        for value in (True, False):
            rec = _capture_emit(
                {
                    "model": "test-model",
                    "call_type": "completion",
                    "stream": value,
                    "original_response": FakeHttpxResponse(200),
                }
            )
            self.assertIs(rec["stream"], value)
        # Missing stream key → null.
        rec = _capture_emit(
            {
                "model": "test-model",
                "call_type": "completion",
                "original_response": FakeHttpxResponse(200),
            }
        )
        self.assertIsNone(rec["stream"])


# ===================================================================
# ProxyObservabilityLogger — streaming callback methods
# ===================================================================


class TestStreamingCallbacks(unittest.TestCase):
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

    def test_stream_event_is_a_noop(self):
        """Per-chunk stream hooks must produce no PROXY_LOG output.

        The final aggregated completion is handled by log_success_event, so
        log_stream_event / async_log_stream_event are intentional no-ops.
        """
        kwargs = {"model": "test-model", "call_type": "completion", "stream": True}
        response_obj = {
            "choices": [{"finish_reason": "stop", "message": {"content": "hello"}}],
            "usage": {"completion_tokens": 5},
        }
        logger = ProxyObservabilityLogger()
        for call in (
            lambda: logger.log_stream_event(kwargs, response_obj, datetime(2024, 1, 1), datetime(2024, 1, 1, 0, 0, 1)),
            lambda: asyncio.run(logger.async_log_stream_event(kwargs, response_obj, datetime(2024, 1, 1), datetime(2024, 1, 1, 0, 0, 1))),
        ):
            buf = StringIO()
            old_stdout = sys.stdout
            try:
                sys.stdout = buf
                call()
            finally:
                sys.stdout = old_stdout
            assert buf.getvalue() == "", "stream hooks should produce no output (no-op per-chunk hook)"

    def test_emit_with_all_none(self):
        """When everything is None, _emit should not crash."""
        buf = StringIO()
        old_stdout = sys.stdout
        try:
            sys.stdout = buf
            _emit(None, None, None, None, "failure")
        finally:
            sys.stdout = old_stdout
        line = buf.getvalue().strip()
        assert line.startswith("PROXY_LOG "), f"Expected PROXY_LOG prefix, got: {line!r}"
        rec = json.loads(line[len("PROXY_LOG "):])
        assert rec["status"] == "failure"
        assert rec["ms"] is None


# ============================================================# ProxyObservabilityLogger class — verify dispatch
# ===================================================================


class TestProxyObservabilityLogger(unittest.TestCase):
    """Verify the CustomLogger subclass dispatches to _emit correctly."""

    def test_log_success_event_emits(self):
        from litellm_logger import proxy_handler_instance

        kwargs = {"model": "test", "call_type": "completion"}
        start = datetime(2024, 1, 1, 0, 0, 0)
        end = datetime(2024, 1, 1, 0, 0, 1)

        buf = StringIO()
        old_stdout = sys.stdout
        try:
            sys.stdout = buf
            proxy_handler_instance.log_success_event(kwargs, None, start, end)
        finally:
            sys.stdout = old_stdout

        line = buf.getvalue().strip()
        self.assertTrue(line.startswith("PROXY_LOG "), f"Expected PROXY_LOG prefix, got: {line!r}")
        rec = json.loads(line[len("PROXY_LOG "):])
        self.assertEqual(rec["status"], "success")

    def test_log_failure_event_emits(self):
        from litellm_logger import proxy_handler_instance

        kwargs = {"model": "test", "call_type": "completion"}
        start = datetime(2024, 1, 1, 0, 0, 0)
        end = datetime(2024, 1, 1, 0, 0, 1)

        buf = StringIO()
        old_stdout = sys.stdout
        try:
            sys.stdout = buf
            proxy_handler_instance.log_failure_event(kwargs, None, start, end)
        finally:
            sys.stdout = old_stdout

        line = buf.getvalue().strip()
        self.assertTrue(line.startswith("PROXY_LOG "), f"Expected PROXY_LOG prefix, got: {line!r}")
        rec = json.loads(line[len("PROXY_LOG "):])
        self.assertEqual(rec["status"], "failure")


if __name__ == "__main__":
    unittest.main()
