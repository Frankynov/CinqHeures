#!/usr/bin/env python3
"""CI health check: prints the UDID of an available "iPhone" or "iPad" simulator on the newest iOS
runtime installed, preferring the models listed here."""
import json
import re
import subprocess
import sys

family = sys.argv[1]
preferred = {
    "iPhone": ["iPhone 17 Pro", "iPhone 17", "iPhone 16 Pro", "iPhone 16"],
    "iPad": ["iPad Pro 13-inch (M5)", "iPad Pro 13-inch (M4)", "iPad Air 13-inch (M3)", "iPad Pro 11-inch (M4)"],
}[family]
listing = json.loads(subprocess.run(["xcrun", "simctl", "list", "devices", "available", "-j"],
                                    capture_output=True, text=True, check=True).stdout)


def version(runtime):
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    return tuple(int(x) for x in match.groups()) if match else None


runtimes = sorted((version(r), r) for r in listing["devices"] if version(r))
for _, runtime in reversed(runtimes):
    devices = [d for d in listing["devices"][runtime] if d["name"].startswith(family)]
    if not devices:
        continue
    chosen = next((d for name in preferred for d in devices if d["name"] == name), devices[0])
    print(chosen["udid"])
    print(f"{family}: {chosen['name']} on {runtime}", file=sys.stderr)
    sys.exit(0)
sys.exit(f"No {family} simulator available")
