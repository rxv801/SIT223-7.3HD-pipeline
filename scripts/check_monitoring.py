"""Inspect a running Prometheus: print its alert rules, or check a job is up.

Kept as a file rather than inlined in monitoring.sh because the f-strings need
quotes that fight with shell quoting.

    python scripts/check_monitoring.py rules <prometheus-url>
    python scripts/check_monitoring.py scraped <prometheus-url> <job>
"""

import json
import sys
import urllib.parse
import urllib.request


def fetch(url: str):
    with urllib.request.urlopen(url, timeout=15) as response:
        return json.load(response)


def show_rules(base_url: str) -> int:
    groups = fetch(f"{base_url}/api/v1/rules")["data"]["groups"]
    rules = [rule for group in groups for rule in group["rules"]]

    if not rules:
        print("    FAIL: Prometheus loaded no alert rules")
        return 1

    for rule in rules:
        name = rule["name"]
        duration = rule.get("duration", 0)
        state = rule.get("state", "?")
        severity = rule.get("labels", {}).get("severity", "-")
        print(f"    {name:22} for={duration:>4.0f}s  severity={severity:<8} state={state}")

    return 0


def check_scraped(base_url: str, job: str) -> int:
    query = urllib.parse.quote(f'up{{job="{job}"}}')
    result = fetch(f"{base_url}/api/v1/query?query={query}")["data"]["result"]

    if not result:
        print(f"    {job}: no 'up' series — Prometheus does not know this target")
        return 1

    value = result[0]["value"][1]
    if value != "1":
        print(f"    {job}: up={value} — target is registered but not answering")
        return 1

    print(f"    {job}: up=1, being scraped")
    return 0


def main() -> int:
    action, base_url = sys.argv[1], sys.argv[2].rstrip("/")

    if action == "rules":
        return show_rules(base_url)
    if action == "scraped":
        return check_scraped(base_url, sys.argv[3])

    print(f"unknown action: {action}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
