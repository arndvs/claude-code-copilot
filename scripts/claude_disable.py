#!/usr/bin/env python3
"""
Remove the LiteLLM proxy configuration from Claude Code settings.
Restores direct Anthropic API access without touching other settings.

Usage: python3 scripts/claude_disable.py
"""
import json
import os
import sys
import tempfile
from pathlib import Path

def main():
    settings_file = Path.home() / '.claude' / 'settings.json'

    if not settings_file.exists():
        print('✅ No settings file found — Claude Code already using defaults.')
        return

    try:
        with open(settings_file) as f:
            settings = json.load(f)

        proxy_keys = [
            'ANTHROPIC_BASE_URL',
            'ANTHROPIC_AUTH_TOKEN',
            'CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS',
        ]
        env = settings.get('env', {})
        removed = [k for k in proxy_keys if k in env]
        for k in removed:
            del env[k]

        if removed:
            if env:
                settings['env'] = env
            else:
                del settings['env']
            fd, tmp_path = tempfile.mkstemp(
                dir=str(settings_file.parent), suffix='.tmp', prefix='settings_'
            )
            try:
                with os.fdopen(fd, 'w') as f:
                    json.dump(settings, f, indent=2)
                    f.write('\n')
                os.replace(tmp_path, str(settings_file))
            except BaseException:
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
                raise
            settings_file.chmod(0o600)
            print('✅ Proxy configuration removed.')
            print('   Claude Code will now use Anthropic API directly.')
        else:
            print('✅ No proxy configuration found — nothing to remove.')

    except json.JSONDecodeError as e:
        print(
            f'❌ Invalid JSON in {settings_file}: {e}. '
            'Please fix the file contents or remove it and try again.',
            file=sys.stderr,
        )
        sys.exit(1)
    except OSError as e:
        print(
            f'❌ Error accessing {settings_file}: {e}. '
            'Please check file permissions and try again.',
            file=sys.stderr,
        )
        sys.exit(1)
    except Exception as e:
        print(f'❌ Unexpected error updating settings: {e}', file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    main()
