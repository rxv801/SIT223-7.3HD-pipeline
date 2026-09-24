"""Print a pip-audit JSON report readably and exit non-zero if it found anything.

pip-audit's own exit code does not distinguish "vulnerable" from "could not
reach the advisory database", so the report is parsed here instead.
"""

import json
import sys

report_path, label = sys.argv[1], sys.argv[2]

with open(report_path) as handle:
    report = json.load(handle)

findings = [
    (dep, vuln)
    for dep in report.get("dependencies", [])
    for vuln in dep.get("vulns", [])
]

if not findings:
    scanned = len(report.get("dependencies", []))
    print(f"    {scanned} {label} packages scanned, no known vulnerabilities")
    sys.exit(0)

for dep, vuln in findings:
    aliases = ", ".join(vuln.get("aliases", [])) or vuln["id"]
    fixes = ", ".join(vuln.get("fix_versions", [])) or "no fix published"
    print(f"    [VULN] {dep['name']} {dep['version']} — {aliases}")
    print(f"           fixed in: {fixes}")

print(f"    FAIL: {len(findings)} vulnerability(ies) in {label} dependencies")
sys.exit(1)
