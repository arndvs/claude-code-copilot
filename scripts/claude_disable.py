#!/usr/bin/env python3
"""
Remove the LiteLLM proxy configuration from Claude Code settings.
Restores direct Anthropic API access without touching other settings.

Usage: python3 scripts/claude_disable.py
"""
import json
import sys
from pathlib import Path

def main():
    settings_file = Path.home() / '.claude' / 'settings.json'

    if not settings_file.exists():
        print('✅ No settings file found — Claude Code already using defaults.')
        return

    try:
        with open(settings_file) as f:
            settings = json.load(f)

        if 'env' in settings:
            del settings['env']
            with open(settings_file, 'w') as f:
                json.dump(settings, f, indent=2)
                f.write('\n')
            print('✅ Proxy configuration removed.')
            print('   Claude Code will now use Anthropic API directly.')
        else:
            print('✅ No proxy configuration found — nothing to remove.')

    except Exception as e:
        print(f'❌ Error updating settings: {e}')
        sys.exit(1)

if __name__ == '__main__':
    main()
