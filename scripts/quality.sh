#!/usr/bin/env bash
#
# Code Quality stage — lint locally with ruff, then push a full analysis to
# SonarCloud. Focused on code health (smells, duplication, complexity), not
# security; security scanning is its own stage.
#
#   SONAR_TOKEN=xxx ./scripts/quality.sh
#
set -euo pipefail

CACHE_DIR="${HOME}/.jenkins-cache/sit223-7.3hd"
SCANNER_VERSION="7.3.0.5189"
SCANNER_PLATFORM="macosx-aarch64"

cd "$(dirname "$0")/.."

REQ_HASH="$(cat requirements.txt requirements-dev.txt \
    | sed -e 's/#.*//' -e '/^[[:space:]]*$/d' \
    | shasum -a 256 | cut -c1-12)"
VENV="${CACHE_DIR}/venv-${REQ_HASH}"

# ---------------------------------------------------------------------------
# 1. ruff — fast, local, no network.
#
# Runs first so an obvious lint failure stops the stage in about a second
# rather than after a full upload and server-side analysis.
# ---------------------------------------------------------------------------
if [ ! -x "${VENV}/bin/ruff" ]; then
    echo "ERROR: ruff not found in ${VENV} — run ./scripts/build.sh first." >&2
    exit 1
fi

echo "==> Linting with ruff"
"${VENV}/bin/ruff" check --output-format=concise .

# ---------------------------------------------------------------------------
# 2. SonarCloud.
#
# Needs reports/coverage.xml from the Test stage; without it Sonar reports 0%
# coverage and the quality gate fails for the wrong reason. Fail early and say
# so, rather than uploading a misleading analysis.
# ---------------------------------------------------------------------------
if [ ! -f reports/coverage.xml ]; then
    echo "ERROR: reports/coverage.xml missing — run ./scripts/test.sh first." >&2
    exit 1
fi

if [ -z "${SONAR_TOKEN:-}" ]; then
    echo "ERROR: SONAR_TOKEN is not set." >&2
    echo "       Jenkins injects it from the credential of the same name." >&2
    exit 1
fi

# Cache the scanner outside the workspace, same reasoning as the venv.
SCANNER_DIR="${CACHE_DIR}/sonar-scanner-${SCANNER_VERSION}-${SCANNER_PLATFORM}"
if [ ! -x "${SCANNER_DIR}/bin/sonar-scanner" ]; then
    echo "==> Downloading sonar-scanner ${SCANNER_VERSION}"
    mkdir -p "$CACHE_DIR"
    curl -fsSL --retry 3 -o "${CACHE_DIR}/scanner.zip" \
        "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SCANNER_VERSION}-${SCANNER_PLATFORM}.zip"
    unzip -q -o "${CACHE_DIR}/scanner.zip" -d "$CACHE_DIR"
    rm -f "${CACHE_DIR}/scanner.zip"
else
    echo "==> Reusing cached sonar-scanner"
fi

echo "==> Running SonarCloud analysis"
"${SCANNER_DIR}/bin/sonar-scanner" -Dsonar.token="${SONAR_TOKEN}"

# ---------------------------------------------------------------------------
# 3. Quality gate.
#
# The SonarQube Jenkins plugin (and its waitForQualityGate step) is not
# installed on this controller, so the gate is enforced by polling the web API
# directly.
#
# Three things the obvious implementation gets wrong, all found the hard way:
#   - api/ce/task returns 404 "Project doesn't exist" here, so the scanner's
#     task id is not a usable handle.
#   - SonarCloud rejects `curl -u <token>:` and answers with an empty body,
#     which a naive json.load reports as a confusing parse error. Use a Bearer
#     header, and check the HTTP status before parsing.
#   - Waiting for an analysis "newer than now" never succeeds: the analysis is
#     stamped when the scanner ran, which is before this check starts. Match on
#     the analysed git revision instead.
#
# Without this the stage would only ever *submit* an analysis and pass
# regardless of the verdict, which is the failure mode this pipeline exists to
# avoid.
# ---------------------------------------------------------------------------
SONAR_API="https://sonarcloud.io/api"
PROJECT_KEY="$(grep '^sonar.projectKey=' sonar-project.properties | cut -d= -f2-)"

sonar_get() {
    # Echo the body; return non-zero (and report) on any non-200.
    local path="$1"
    local body code
    body="$(curl -sS -w '\n%{http_code}' --max-time 30 \
        -H "Authorization: Bearer ${SONAR_TOKEN}" "${SONAR_API}/${path}")" || return 1
    code="${body##*$'\n'}"
    body="${body%$'\n'*}"
    if [ "$code" != "200" ]; then
        echo "ERROR: GET ${path} -> HTTP ${code}" >&2
        echo "       ${body}" >&2
        return 1
    fi
    printf '%s' "$body"
}

# Match on the analysed git revision, not on time. The analysis is stamped
# when the scanner ran, which is necessarily *before* this check starts, so a
# "newer than now" comparison can never succeed.
REVISION="$(git rev-parse HEAD)"

echo "==> Waiting for SonarCloud to process revision ${REVISION:0:8}"
ANALYSIS_FRESH=""
for _ in $(seq 1 40); do
    if ANALYSES="$(sonar_get "project_analyses/search?project=${PROJECT_KEY}&ps=5")"; then
        # Tolerate an empty or unparseable body: SonarCloud occasionally
        # answers 200 with nothing while it is still ingesting a report, and
        # a crash here would fail a build whose analysis is merely slow.
        if printf '%s' "$ANALYSES" | REVISION="$REVISION" python3 -c '
import json, os, sys

try:
    analyses = json.load(sys.stdin).get("analyses", [])
except (json.JSONDecodeError, ValueError):
    sys.exit(1)

wanted = os.environ["REVISION"]
sys.exit(0 if any(a.get("revision") == wanted for a in analyses) else 1)
'; then
            ANALYSIS_FRESH="yes"
            break
        fi
    fi
    sleep 5
done

if [ -z "$ANALYSIS_FRESH" ]; then
    echo "ERROR: no analysis for revision ${REVISION:0:8} appeared within ~3 minutes" >&2
    exit 1
fi

GATE_JSON="$(sonar_get "qualitygates/project_status?projectKey=${PROJECT_KEY}")"

printf '%s' "$GATE_JSON" | python3 - <<'PYGATE'
import json
import sys

status = json.load(sys.stdin)["projectStatus"]
print(f"==> Quality gate: {status['status']}")

for condition in status.get("conditions", []):
    mark = "ok  " if condition["status"] == "OK" else "FAIL"
    print(
        f"    [{mark}] {condition['metricKey']}: "
        f"{condition.get('actualValue', '?')} "
        f"(threshold {condition.get('comparator', '')} {condition.get('errorThreshold', '?')})"
    )

if status["status"] != "OK":
    sys.exit(1)
PYGATE

echo "==> Code quality OK"
