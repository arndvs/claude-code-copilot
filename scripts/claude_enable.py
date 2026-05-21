#!/usr/bin/env python3
"""
Enable the LiteLLM proxy in Claude Code settings.
Writes proxy env vars to ~/.claude/settings.json without touching other settings.

Usage: python3 scripts/claude_enable.py <master_key> [port]
"""
import json
import sys
from pathlib import Path

def main():
    if len(sys.argv) < 2:
        print("Usage: claude_enable.py <master_key> [port]")
        sys.exit(1)

    master_key = sys.argv[1]
    port = sys.argv[2] if len(sys.argv) > 2 else "4000"

    claude_dir = Path.home() / '.claude'
    settings_file = claude_dir / 'settings.json'

    claude_dir.mkdir(mode=0o700, exist_ok=True)
    claude_dir.chmod(0o700)

    # Load existing settings or start fresh
    settings = {}
    if settings_file.exists():
        try:
            with open(settings_file) as f:
                settings = json.load(f)
        except (json.JSONDecodeError, IOError):
            settings = {}

    # Inject proxy env vars — merges into existing env dict
    settings.setdefault('$schema', 'https://json.schemastore.org/claude-code-settings.json')
    env = settings.get('env', {})
    env.update({
        'ANTHROPIC_BASE_URL': f'http://localhost:{port}',
        'ANTHROPIC_AUTH_TOKEN': master_key,
        # Required — Copilot doesn't support extended thinking
        'CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS': '1',
    })
    settings['env'] = env

    with open(settings_file, 'w') as f:
        json.dump(settings, f, indent=2)
        f.write('\n')
    settings_file.chmod(0o600)

    print(f'✅ Claude Code configured to use proxy at http://localhost:{port}')
    print(f'   Settings: {settings_file}')
    print(f'   Run ./start_proxy.sh in a separate terminal, then launch claude.')

if __name__ == '__main__':
    main()
