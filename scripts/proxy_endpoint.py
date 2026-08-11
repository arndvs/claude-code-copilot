#!/usr/bin/env python3
"""Canonical proxy-endpoint resolver (refs #110, #128).

Owns the question "what URL will the proxy be reachable at?" — unifying the
divergent port/URL resolution that used to live independently in
``start_proxy.sh``, the Makefile, ``proxy_status.py``, and ``claude_enable.py``.

Precedence chain (highest wins):
    1. ``PROXY_BASE_URL`` (full URL override)
    2. ``ANTHROPIC_BASE_URL`` (from settings — already-configured state)
    3. ``http://localhost:{LITELLM_PORT}`` (from env or .env file)
    4. ``http://localhost:4000`` (hardcoded default)

stdlib-only. Consumers import ``resolve_proxy_endpoint`` and call it with the
same inputs so every path resolves an identical URL for the same environment.

Refs #110, #128
"""

from __future__ import annotations

import os
from collections import namedtuple
from pathlib import Path
from urllib.parse import urlparse

# Loopback hosts that mean "the proxy runs on this machine".
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1"}
DEFAULT_PORT = "4000"

ProxyEndpoint = namedtuple("ProxyEndpoint", ["url", "port", "kind"])


def _read_env_port(env_file: str, default: str = DEFAULT_PORT) -> str:
    """Read ``LITELLM_PORT`` from a .env file, defaulting when absent/unreadable.

    Tolerates a non-UTF-8 .env and matches only the exact ``LITELLM_PORT``
    assignment, not lookalikes like ``LITELLM_PORTAL``.
    """
    try:
        lines = Path(env_file).read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return default
    for line in lines:
        key, sep, value = line.strip().partition("=")
        if sep and key.strip() == "LITELLM_PORT":
            value = value.strip().strip('"').strip("'")
            if value:
                return value
    return default


def _classify(url: str) -> str:
    """Classify a proxy URL as ``local`` (loopback) or ``hosted``."""
    host = urlparse(url).hostname
    return "local" if host in LOCAL_HOSTS else "hosted"


def resolve_proxy_endpoint(
    env_file: str = ".env",
    settings: dict | None = None,
) -> ProxyEndpoint:
    """Resolve the effective proxy endpoint for the current environment.

    ``settings`` is an optional parsed Claude settings mapping (with an ``env``
    dict) used to honor an already-configured ``ANTHROPIC_BASE_URL``. It is only
    consulted when explicitly passed — claude_enable.py deliberately passes none
    (it writes that key, so reading it back would be circular). Returns a
    ``ProxyEndpoint(url, port, kind)``.
    """
    # 1. PROXY_BASE_URL — full URL override (highest precedence).
    proxy_base = os.environ.get("PROXY_BASE_URL", "").strip()
    if proxy_base:
        url = proxy_base.rstrip("/")
        return ProxyEndpoint(url=url, port=_port_from_url(url), kind=_classify(url))

    # 2. ANTHROPIC_BASE_URL from settings — only when a settings mapping is
    #    explicitly passed (already-configured state). Never consulted for the
    #    launch/enable path, which passes no settings.
    if isinstance(settings, dict):
        env = settings.get("env")
        if isinstance(env, dict):
            anthropic = env.get("ANTHROPIC_BASE_URL")
            if isinstance(anthropic, str) and anthropic.strip():
                url = anthropic.strip().rstrip("/")
                return ProxyEndpoint(url=url, port=_port_from_url(url), kind=_classify(url))

    # 3. LITELLM_PORT from env or .env file.
    port = os.environ.get("LITELLM_PORT", "").strip() or _read_env_port(env_file)
    url = f"http://localhost:{port}"
    return ProxyEndpoint(url=url, port=port, kind="local")


def _port_from_url(url: str) -> str:
    """Extract the port from a URL, defaulting to 4000 when absent."""
    parsed = urlparse(url)
    if parsed.port:
        return str(parsed.port)
    return DEFAULT_PORT


def main(argv: list[str] | None = None) -> int:
    """CLI: print the resolved proxy URL (and port/kind) for the current env.

    Usage:
        python3 scripts/proxy_endpoint.py [env_file]
    """
    import sys

    env_file = argv[1] if argv and len(argv) > 1 else ".env"
    ep = resolve_proxy_endpoint(env_file=env_file)
    print(ep.url)
    print(f"port={ep.port}")
    print(f"kind={ep.kind}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
