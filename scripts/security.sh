#!/usr/bin/env bash
#
# Security stage — static analysis of the worker's own code, plus a CVE scan of
# its dependencies. Distinct from Code Quality, which is about code health:
# this stage is about what an attacker could do.
#
#   ./scripts/security.sh
#
set -euo pipefail

CACHE_DIR="${HOME}/.jenkins-cache/sit223-7.3hd"
BANDIT_FAIL_ON="high"          # severity at which the build goes red

cd "$(dirname "$0")/.."

REQ_HASH="$(cat requirements.txt requirements-dev.txt \
    | sed -e 's/#.*//' -e '/^[[:space:]]*$/d' \
    | shasum -a 256 | cut -c1-12)"
VENV="${CACHE_DIR}/venv-${REQ_HASH}"

if [ ! -x "${VENV}/bin/bandit" ]; then
    echo "ERROR: bandit not found in ${VENV} — run ./scripts/build.sh first." >&2
    exit 1
fi

mkdir -p reports
FAILED=0

# ---------------------------------------------------------------------------
# 1. Bandit — SAST over the code we wrote.
#
# Reports everything for the record, but only HIGH severity stops the build.
# Medium and low are listed in the console and kept in the JSON artefact so a
# reviewer can see them without a noisy gate blocking unrelated work.
# ---------------------------------------------------------------------------
echo "==> Bandit (SAST)"
"${VENV}/bin/bandit" -r main.py cv \
    -f json -o reports/bandit.json \
    --quiet || true

BANDIT_FAIL_ON="$BANDIT_FAIL_ON" python3 - <<'PYBANDIT' || FAILED=1
import json
import os
import sys

with open("reports/bandit.json") as handle:
    report = json.load(handle)

results = report.get("results", [])
counts = {"HIGH": 0, "MEDIUM": 0, "LOW": 0}

for issue in results:
    severity = issue["issue_severity"].upper()
    counts[severity] = counts.get(severity, 0) + 1
    print(
        f"    [{severity}] {issue['test_id']} "
        f"{issue['filename']}:{issue['line_number']} — {issue['issue_text']}"
    )

total_lines = report.get("metrics", {}).get("_totals", {}).get("loc", "?")
print(
    f"    scanned {total_lines} lines: "
    f"{counts['HIGH']} high, {counts['MEDIUM']} medium, {counts['LOW']} low"
)

threshold = os.environ["BANDIT_FAIL_ON"].upper()
blocking = counts["HIGH"] if threshold == "HIGH" else sum(counts.values())
if blocking:
    print(f"    FAIL: {blocking} issue(s) at or above {threshold}")
    sys.exit(1)
PYBANDIT

# ---------------------------------------------------------------------------
# 2. pip-audit over what actually ships.
#
# requirements.lock is the exact set Deploy installs, so a finding here is a
# vulnerability in the running service. Any finding fails the build.
# ---------------------------------------------------------------------------
echo "==> pip-audit (runtime dependencies)"
"${VENV}/bin/pip-audit" -r requirements.lock \
    --progress-spinner off \
    -f json -o reports/pip-audit-runtime.json || true
python3 scripts/summarise_audit.py reports/pip-audit-runtime.json "runtime" || FAILED=1

# ---------------------------------------------------------------------------
# 3. pip-audit over the build environment.
#
# These packages never reach production, but they run against the source and
# hold the credentials the pipeline uses, so a compromise here is a supply
# chain problem. Gated too — it is what caught CVE-2025-71176 in pytest and
# CVE-2026-59890 in setuptools.
# ---------------------------------------------------------------------------
echo "==> pip-audit (build/test tooling)"
"${VENV}/bin/pip-audit" \
    --progress-spinner off \
    -f json -o reports/pip-audit-tooling.json || true
python3 scripts/summarise_audit.py reports/pip-audit-tooling.json "tooling" || FAILED=1

if [ "$FAILED" -ne 0 ]; then
    echo "==> Security checks FAILED — see reports/ for full output" >&2
    exit 1
fi

echo "==> Security OK"
