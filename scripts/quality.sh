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
# directly. The scanner leaves the background task id in report-task.txt;
# wait for that task to finish, then read the gate status off the analysis.
#
# Without this the stage would only ever *submit* an analysis and pass
# regardless of the result, which is the failure mode this pipeline exists to
# avoid.
# ---------------------------------------------------------------------------
REPORT_TASK=".scannerwork/report-task.txt"
if [ ! -f "$REPORT_TASK" ]; then
    echo "ERROR: ${REPORT_TASK} not written — scanner did not submit an analysis." >&2
    exit 1
fi

CE_TASK_ID="$(grep '^ceTaskId=' "$REPORT_TASK" | cut -d= -f2-)"
SONAR_URL="$(grep '^serverUrl=' "$REPORT_TASK" | cut -d= -f2-)"

echo "==> Waiting for analysis ${CE_TASK_ID} to finish"
ANALYSIS_ID=""
for _ in $(seq 1 60); do
    TASK_JSON="$(curl -fsS -u "${SONAR_TOKEN}:" "${SONAR_URL}/api/ce/task?id=${CE_TASK_ID}")"
    STATUS="$(printf '%s' "$TASK_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["task"]["status"])')"

    case "$STATUS" in
        SUCCESS)
            ANALYSIS_ID="$(printf '%s' "$TASK_JSON" \
                | python3 -c 'import json,sys; print(json.load(sys.stdin)["task"].get("analysisId",""))')"
            break
            ;;
        FAILED|CANCELED)
            echo "ERROR: SonarCloud analysis ${STATUS}" >&2
            exit 1
            ;;
    esac
    sleep 5
done

if [ -z "$ANALYSIS_ID" ]; then
    echo "ERROR: analysis did not complete within 5 minutes" >&2
    exit 1
fi

GATE_JSON="$(curl -fsS -u "${SONAR_TOKEN}:" \
    "${SONAR_URL}/api/qualitygates/project_status?analysisId=${ANALYSIS_ID}")"

printf '%s' "$GATE_JSON" | python3 - <<'PY'
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
PY

echo "==> Code quality OK"
