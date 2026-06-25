"""litellm_logger.py — lightweight proxy observability callback.

Emits ONE structured line per completion to stdout (captured by `docker logs`)
so empty / degraded upstream responses can be correlated over time. It logs
metadata ONLY — never message content — so it is safe to leave on in production.

Enabled via `litellm_settings.callbacks: litellm_logger.proxy_handler_instance`
in litellm_config.yaml. The file lives at the repo root so it is importable both
inside the container (WORKDIR /app, PYTHONPATH=/app) and for local `make start`
(run from the repo root).

Design rule: every code path is defensive — a logging failure must NEVER affect
request handling, so all work is wrapped in try/except and the callback degrades
to a no-op rather than raising.

Why this exists: empty `/v1/messages` completions were traced to LiteLLM's
Anthropic-translation adapter (the OpenAI `/v1/chat/completions` path on the same
server is reliable). This callback records the UPSTREAM completion's finish_reason
and content length for every request, so when a client sees an empty response we
can confirm from the logs whether the upstream actually returned content.
"""

from __future__ import annotations

import json
import sys

try:
    from litellm.integrations.custom_logger import CustomLogger
except Exception:  # pragma: no cover - litellm is always present in the proxy image
    class CustomLogger:  # type: ignore[no-redef]
        """Fallback base so importing this module never fails the proxy."""


def _duration_ms(start_time, end_time):
    try:
        return round((end_time - start_time).total_seconds() * 1000)
    except Exception:
        return None


def _extract(response_obj):
    """Return (finish_reason, content_len, completion_tokens) defensively.

    content_len: length of the text content, 0 when empty/missing, -1 when the
    content is a non-string (e.g. tool blocks).
    """
    finish = None
    content_len = None
    ctoks = None
    try:
        if isinstance(response_obj, dict):
            choices = response_obj.get("choices")
            usage = response_obj.get("usage") or {}
        else:
            choices = getattr(response_obj, "choices", None)
            usage = getattr(response_obj, "usage", None) or {}

        if choices:
            c0 = choices[0]
            if isinstance(c0, dict):
                finish = c0.get("finish_reason")
                msg = c0.get("message") or {}
                content = msg.get("content") if isinstance(msg, dict) else None
            else:
                finish = getattr(c0, "finish_reason", None)
                msg = getattr(c0, "message", None)
                content = getattr(msg, "content", None)
            if isinstance(content, str):
                content_len = len(content)
            elif content in (None, ""):
                content_len = 0
            else:
                content_len = -1

        if isinstance(usage, dict):
            ctoks = usage.get("completion_tokens")
        else:
            ctoks = getattr(usage, "completion_tokens", None)
    except Exception:
        pass
    return finish, content_len, ctoks


def _emit(kwargs, response_obj, start_time, end_time, status):
    try:
        rec = {"t": "proxy_log", "status": status}
        if isinstance(kwargs, dict):
            rec["model"] = kwargs.get("model")
            rec["call_type"] = kwargs.get("call_type")
        rec["ms"] = _duration_ms(start_time, end_time)

        finish, content_len, ctoks = _extract(response_obj)
        rec["finish"] = finish
        rec["content_len"] = content_len
        rec["completion_tokens"] = ctoks
        # The key signal: a "successful" completion whose upstream content is empty.
        rec["upstream_empty"] = bool(
            status == "success" and (content_len == 0 or ctoks == 0)
        )

        print("PROXY_LOG " + json.dumps(rec, default=str), file=sys.stdout, flush=True)
    except Exception:
        # Observability must never break request handling.
        pass


class ProxyObservabilityLogger(CustomLogger):
    def log_success_event(self, kwargs, response_obj, start_time, end_time):
        _emit(kwargs, response_obj, start_time, end_time, "success")

    def log_failure_event(self, kwargs, response_obj, start_time, end_time):
        _emit(kwargs, response_obj, start_time, end_time, "failure")

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        _emit(kwargs, response_obj, start_time, end_time, "success")

    async def async_log_failure_event(self, kwargs, response_obj, start_time, end_time):
        _emit(kwargs, response_obj, start_time, end_time, "failure")


proxy_handler_instance = ProxyObservabilityLogger()
