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

from proxy_endpoint import resolve_proxy_endpoint
from proxy_status import PROXY_ENV_KEYS, classify_proxy, validate_proxy_url


def resolve_settings_file():
    override = os.environ.get('CLAUDE_SETTINGS_FILE', '').strip()
    if override:
        return Path(os.path.expandvars(override)).expanduser()
    return Path.home() / '.claude' / 'settings.json'


def resolve_base_url(port):
    # Canonical precedence: PROXY_BASE_URL -> LITELLM_PORT -> default 4000.
    # (ANTHROPIC_BASE_URL from settings is intentionally not consulted here —
    # this script is what writes it, so reading it back would be circular.)
    return resolve_proxy_endpoint(env_file=".env").url


def validate_base_url(base_url, port):
    if not validate_proxy_url(base_url):
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
    base_url = resolve_base_url(port).rstrip('/')
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

    # Inject proxy env vars — merges into existing env dict. Uses only keys from
    # the PROXY_ENV_KEYS manifest so claude_disable.py removes exactly what we
    # write (single source of truth, see CONTEXT.md §1).
    settings.setdefault('$schema', 'https://json.schemastore.org/claude-code-settings.json')
    env = settings.get('env', {})
    if not isinstance(env, dict):
        env = {}
    # Build the exact dict of keys this script writes, then validate it against
    # the manifest before merging — a runtime check (not `assert`, which is
    # skipped under `python -O`) so an undeclared key fails loudly instead of
    # silently leaving claude_disable.py unable to remove it.
    proxy_env = {
        'ANTHROPIC_BASE_URL': base_url,
        'ANTHROPIC_AUTH_TOKEN': master_key,
        # Keeps behavior consistent across providers (disables extended thinking)
        'CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS': '1',
    }
    undeclared = set(proxy_env) - set(PROXY_ENV_KEYS)
    if undeclared:
        raise RuntimeError(
            "claude_enable.py writes keys not declared in PROXY_ENV_KEYS: "
            f"{sorted(undeclared)} — update the manifest in proxy_status.py "
            "(CONTEXT.md §1)."
        )
    env.update(proxy_env)
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
        try:
            os.unlink(tmp_path)
        except FileNotFoundError:
            pass
        except OSError as cleanup_err:
            print(
                f"⚠️  Could not remove temp settings file {tmp_path}: {cleanup_err}. "
                "It may contain sensitive values — remove it manually.",
                file=sys.stderr,
            )
        raise
    settings_file.chmod(0o600)

    print(f'✅ Claude Code configured to use proxy at {base_url}')
    print(f'   Settings: {settings_file}')
    if classify_proxy(base_url) == "local":
        print(f'   Run ./start_proxy.sh in a separate terminal, then launch claude.')
    else:
        print(f'   Ensure the hosted proxy is reachable, then launch claude.')

if __name__ == '__main__':
    main()
