#!/usr/bin/env python3
"""Response classification for the proxy completion probe.

Extracts the response-parsing and outcome-classification logic from
``.sandcastle/scripts/probe_completion.sh`` into a testable, stdlib-only Python
module (refs #112). The bash script becomes a thin curl-retry loop that calls
this module for each response.

Two pure functions:

- ``classify_response(http_code, body)`` — classify a single probe response into
  a structured result: whether it has content, its format (sse/json/unknown),
  whether it is a hard error, and a human-readable detail.
- ``resolve_outcome(attempts, retries)`` — fold a list of per-attempt results
  into the final ok / degraded / fail verdict, replacing the implicit
  ``got/hard/empty_seen`` state machine in the bash script.

stdlib-only. No network, no subprocess.
"""

from __future__ import annotations

import json
from typing import List, Optional


def _is_sse(body: str) -> bool:
    """True if the body looks like an SSE stream (event:/data:/: lines)."""
    head = body[:128]
    for line in head.splitlines():
        stripped = line.lstrip()
        if stripped.startswith(("event:", "data:", ":")):
            return True
    return False


def _sse_has_content(body: str) -> bool:
    """True if an SSE body contains a content_block_delta with text."""
    for line in body.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("data:") and stripped.rstrip("\r\n") not in (
            "data: [DONE]",
            "data:[DONE]",
        ):
            raw = stripped[5:].lstrip(" ")
            try:
                d = json.loads(raw)
            except Exception:
                continue
            if (
                d.get("type") == "content_block_delta"
                and d.get("delta", {}).get("text")
            ):
                return True
    return False


def _json_has_content(body: str) -> bool:
    """True if a JSON body has non-empty content."""
    try:
        d = json.loads(body)
    except Exception:
        return False
    return bool(d.get("content"))


def _error_type(body: str) -> str:
    """Extract the upstream error type from a JSON error body, if present."""
    try:
        d = json.loads(body)
    except Exception:
        return ""
    return str(d.get("error", {}).get("type", ""))


def classify_response(http_code: str, body: str) -> dict:
    """Classify a single probe response.

    Returns a dict with keys:
      has_content   bool   — whether the response carried completion content
      format        str    — "sse" | "json" | "unknown"
      is_hard_error bool   — whether this is a hard (non-retryable) error
      error_detail  str    — human-readable detail for hard errors / malformed
    """
    result = {
        "has_content": False,
        "format": "unknown",
        "is_hard_error": False,
        "error_detail": "",
    }

    if http_code == "200":
        if _is_sse(body):
            result["format"] = "sse"
            result["has_content"] = _sse_has_content(body)
        else:
            # Non-streaming JSON path — a non-JSON, non-SSE 200 is a hard bug.
            try:
                json.loads(body)
            except Exception:
                result["is_hard_error"] = True
                result["error_detail"] = (
                    "200 but response body was not valid JSON — "
                    "proxy/upstream serving malformed completions"
                )
                return result
            result["format"] = "json"
            result["has_content"] = _json_has_content(body)
        return result

    etype = _error_type(body)
    etype_suffix = f" (type={etype})" if etype else ""

    if http_code in ("401", "403"):
        result["is_hard_error"] = True
        result["error_detail"] = (
            f"auth error HTTP {http_code}{etype_suffix} — "
            "master key likely wrong/mismatched"
        )
        return result
    if http_code == "400":
        result["is_hard_error"] = True
        result["error_detail"] = (
            f"HTTP 400{etype_suffix} — e.g. no_db_connection / bad request"
        )
        return result
    if http_code == "000":
        result["is_hard_error"] = True
        result["error_detail"] = "connection failed — proxy unreachable"
        return result
    if http_code.startswith("5"):
        result["is_hard_error"] = True
        result["error_detail"] = f"upstream HTTP {http_code}{etype_suffix}"
        return result

    # Any other code (e.g. 429, 408) is retryable — not a hard error.
    return result


def resolve_outcome(attempts: List[dict], retries: int) -> dict:
    """Fold per-attempt classifications into the final verdict.

    ``attempts`` is a list of dicts as returned by ``classify_response`` (one
    per attempt, in order). ``retries`` is the configured max attempts.

    Returns a dict with keys:
      status  str  — "ok" | "degraded" | "fail"
      detail  str  — human-readable explanation
    """
    for attempt in attempts:
        if attempt.get("is_hard_error"):
            return {
                "status": "fail",
                "detail": attempt.get("error_detail", "hard error"),
            }
        if attempt.get("has_content"):
            return {"status": "ok", "detail": "completion succeeded"}

    if attempts:
        # All attempts returned 200 with empty content.
        return {
            "status": "degraded",
            "detail": (
                "proxy up and authenticating, but upstream returned empty "
                f"completions across {retries} retries"
            ),
        }

    if retries == 0:
        return {
            "status": "fail",
            "detail": "no probe attempts made (PROBE_MAX_RETRIES=0)",
        }

    return {
        "status": "fail",
        "detail": (
            "persistent non-200/non-hard responses across "
            f"{retries} retries — proxy not serving completions"
        ),
    }


def main(argv: Optional[List[str]] = None) -> int:
    """CLI entry point: read http_code + body from argv/stdin, print verdict.

    Usage: python3 probe_parser.py <http_code> < <body_file>
    Prints ``status=<s>`` and ``detail=<d>`` lines to stdout.
    """
    import sys

    argv = argv if argv is not None else sys.argv
    if len(argv) < 2:
        print("status=fail", file=sys.stderr)
        print("detail=probe_parser: http_code argument required", file=sys.stderr)
        return 1
    http_code = argv[1]
    body = sys.stdin.read()
    result = classify_response(http_code, body)
    # status=yes|no matches the bash script's convention (has content or not).
    print(f"status={'yes' if result['has_content'] else 'no'}")
    print(f"format={result['format']}")
    print(f"hard={str(result['is_hard_error']).lower()}")
    if result["error_detail"]:
        # Flatten CR/LF so a hostile upstream error type cannot inject extra
        # key=value lines into the probe's stdout (output-injection guard).
        detail = result["error_detail"].replace("\r", " ").replace("\n", " ")
        print(f"detail={detail}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
