#!/usr/bin/env python3
import json
import re
import sys

data = json.load(sys.stdin)
env = data.get("env", {})
pattern = re.compile(r"(?:^|_)(?:TOKEN|KEY|SECRET|PASSWORD|CREDENTIAL|AUTH)(?:$|_)", re.I)
for key in list(env):
    if pattern.search(key):
        env[key] = "<redacted>"
json.dump(data, sys.stdout, indent=2)
print()
