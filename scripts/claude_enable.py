#!/usr/bin/env python3
"""
Enable the LiteLLM proxy in Claude Code settings.
Writes proxy env vars to ~/.claude/settings.json without touching other settings.

Reads LITELLM_MASTER_KEY from the environment (never from command-line arguments).
Optional: LITELLM_PORT (default 4000).
Tests may set CLAUDE_SETTINGS_FILE to isolate writes from real user config.

Usage: python3 scripts/claude_enable.py
"""
import json
import os
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlparse


def resolve_settings_file():
    override = os.environ.get('CLAUDE_SETTINGS_FILE', '').strip()
    if override:
        return Path(override).expanduser()
    return Path.home() / '.claude' / 'settings.json'


def resolve_base_url(port):
    return (
        os.environ.get('PROXY_BASE_URL', '').strip()
        or os.environ.get('ANTHROPIC_BASE_URL', '').strip()
        or f'http://localhost:{port}'
    )


def is_local_base_url(base_url):
    host = urlparse(base_url).hostname
    return host in {'localhost', '127.0.0.1', '::1'}


def validate_base_url(base_url, port):
    parsed = urlparse(base_url)
    if parsed.scheme not in {'http', 'https'} or not parsed.netloc:
        print(
            f"❌ Invalid proxy base URL: {base_url!r}. Expected an absolute "
            f"http(s) URL (e.g. 'http://localhost:{port}' or "
            "'https://proxy.example.com').",
            file=sys.stderr,
        )
        sys.exit(1)


def main():
    master_key = os.environ.get('LITELLM_MASTER_KEY', '').strip()
    if not master_key:
        print(
            "❌ LITELLM_MASTER_KEY is not set in the environment.\n"
            "   Source your .env first: set -a && . ./.env && set +a",
            file=sys.stderr,
        )
        sys.exit(1)

    port = os.environ.get('LITELLM_PORT', '').strip() or "4000"
    base_url = resolve_base_url(port)
    validate_base_url(base_url, port)

    settings_file = resolve_settings_file()
    claude_dir = settings_file.parent

    claude_dir.mkdir(mode=0o700, exist_ok=True)
    claude_dir.chmod(0o700)

    # Load existing settings or start fresh
    settings = {}
    if settings_file.exists():
        try:
            with open(settings_file) as f:
                settings = json.load(f)
        except json.JSONDecodeError as e:
            print(
                f"❌ {settings_file} contains invalid JSON: {e}",
                file=sys.stderr,
            )
            print(
                "Please fix or remove the file and run claude_enable.py again.",
                file=sys.stderr,
            )
            sys.exit(1)
        except OSError as e:
            print(
                f"❌ Could not read {settings_file}: {e}",
                file=sys.stderr,
            )
            print(
                "Please fix the file permissions or remove the file and try again.",
                file=sys.stderr,
            )
            sys.exit(1)

    # Inject proxy env vars — merges into existing env dict
    settings.setdefault('$schema', 'https://json.schemastore.org/claude-code-settings.json')
    env = settings.get('env', {})
    env.update({
        'ANTHROPIC_BASE_URL': base_url,
        'ANTHROPIC_AUTH_TOKEN': master_key,
        # Required — Copilot doesn't support extended thinking
        'CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS': '1',
    })
    settings['env'] = env

    fd, tmp_path = tempfile.mkstemp(
        dir=str(claude_dir), suffix='.tmp', prefix='settings_'
    )
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(settings, f, indent=2)
            f.write('\n')
        os.replace(tmp_path, str(settings_file))
    except BaseException:
        os.unlink(tmp_path)
        raise
    settings_file.chmod(0o600)

    print(f'✅ Claude Code configured to use proxy at {base_url}')
    print(f'   Settings: {settings_file}')
    if is_local_base_url(base_url):
        print(f'   Run ./start_proxy.sh in a separate terminal, then launch claude.')
    else:
        print(f'   Ensure the hosted proxy is reachable, then launch claude.')

if __name__ == '__main__':
    main()
