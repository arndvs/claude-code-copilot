#!/usr/bin/env python3
import json
import re
import sys

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    # Avoid printing potentially sensitive file contents; let the caller decide how to handle the failure.
    sys.exit(1)

env = data.get("env", {})
if not isinstance(env, dict):
    env = {}
    data["env"] = env

pattern = re.compile(r"(?:^|_)(?:TOKEN|KEY|SECRET|PASSWORD|CREDENTIAL|AUTH)(?:$|_)", re.I)
for key in list(env):
    if pattern.search(key):
        env[key] = "<redacted>"
json.dump(data, sys.stdout, indent=2)
print()
