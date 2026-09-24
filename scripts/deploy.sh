#!/usr/bin/env bash
#
# Deploy stage — roll the artefact built in stage 1 out to an environment,
# then prove the result actually works.
#
#   ./scripts/deploy.sh staging     (port 8766, run by the Deploy stage)
#   ./scripts/deploy.sh prod        (port 8765, run by the Release stage)
#
set -euo pipefail

ENVIRONMENT="${1:-staging}"
case "$ENVIRONMENT" in
    staging) PORT=8766 ;;
    prod)    PORT=8765 ;;
    *) echo "ERROR: unknown environment '${ENVIRONMENT}' (use staging or prod)" >&2; exit 1 ;;
esac

DEPLOY_ROOT="${HOME}/taskmaster-deploy/${ENVIRONMENT}"
CACHE_DIR="${HOME}/.jenkins-cache/sit223-7.3hd"
PYTHON_BIN="/opt/homebrew/opt/python@3.11/bin/python3.11"
HEALTH_TIMEOUT=45

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

ARTEFACT="$(ls -t dist/taskmaster-worker-*.tar.gz 2>/dev/null | head -1 || true)"
if [ -z "$ARTEFACT" ]; then
    echo "ERROR: no artefact in dist/ — run ./scripts/build.sh first." >&2
    exit 1
fi
VERSION="$(basename "$ARTEFACT" .tar.gz | sed 's/^taskmaster-worker-//')"

echo "==> Deploying ${VERSION} to ${ENVIRONMENT} (port ${PORT})"

# ---------------------------------------------------------------------------
# 1. Unpack the artefact.
#
# Deliberately the tarball, not the checkout: this is how we know the thing
# now running is the exact bytes that were built, tested and scanned.
# ---------------------------------------------------------------------------
RELEASE_DIR="${DEPLOY_ROOT}/releases/${VERSION}"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
tar -xzf "$ARTEFACT" -C "$RELEASE_DIR"
echo "==> Unpacked to ${RELEASE_DIR}"

# ---------------------------------------------------------------------------
# 2. Runtime virtualenv, built from requirements.lock.
#
# The lock, not requirements.txt: floors like ">=" would let the deployed
# service drift from the versions the Security stage actually cleared. Cached
# by lock hash, so repeat deploys of the same dependency set are instant.
# ---------------------------------------------------------------------------
LOCK_HASH="$(shasum -a 256 "${RELEASE_DIR}/requirements.lock" | cut -c1-12)"
RUNTIME_VENV="${CACHE_DIR}/runtime-${LOCK_HASH}"

if [ -x "${RUNTIME_VENV}/bin/python" ]; then
    echo "==> Reusing runtime venv (lock ${LOCK_HASH})"
else
    echo "==> Building runtime venv (lock ${LOCK_HASH})"
    rm -rf "$RUNTIME_VENV"
    "$PYTHON_BIN" -m venv "$RUNTIME_VENV"
    "${RUNTIME_VENV}/bin/python" -m pip install --upgrade pip --quiet
    "${RUNTIME_VENV}/bin/pip" install --quiet -r "${RELEASE_DIR}/requirements.lock"
fi

# ---------------------------------------------------------------------------
# 3. Stop whatever is already running here.
# ---------------------------------------------------------------------------
PID_FILE="${DEPLOY_ROOT}/run.pid"
LOG_FILE="${DEPLOY_ROOT}/run.log"

if [ -f "$PID_FILE" ]; then
    OLD_PID="$(cat "$PID_FILE")"
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "==> Stopping previous instance (pid ${OLD_PID})"
        kill "$OLD_PID" 2>/dev/null || true
        for _ in $(seq 1 20); do
            kill -0 "$OLD_PID" 2>/dev/null || break
            sleep 0.5
        done
        kill -9 "$OLD_PID" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
fi

# ---------------------------------------------------------------------------
# 4. Point "current" at this release and start it.
#
# spawn_detached.py puts the server in its own session, so Jenkins does not
# reap it when the build step ends. macOS has no setsid(1), which is why this
# goes through Python rather than the shell.
# ---------------------------------------------------------------------------
ln -sfn "$RELEASE_DIR" "${DEPLOY_ROOT}/current"

cd "$RELEASE_DIR"
: > "$LOG_FILE"
NEW_PID="$("${RUNTIME_VENV}/bin/python" "${REPO_ROOT}/scripts/spawn_detached.py" \
    "$LOG_FILE" \
    "${RUNTIME_VENV}/bin/python" -m uvicorn main:app \
    --host 127.0.0.1 --port "$PORT")"
echo "$NEW_PID" > "$PID_FILE"
cd "$REPO_ROOT"
echo "==> Started pid ${NEW_PID}, logging to ${LOG_FILE}"

# ---------------------------------------------------------------------------
# 5. Health check, then a real smoke test.
# ---------------------------------------------------------------------------
BASE_URL="http://127.0.0.1:${PORT}"

report_failure() {
    echo "ERROR: ${ENVIRONMENT} deployment of ${VERSION} failed health checks" >&2
    echo "--- last 30 lines of ${LOG_FILE} ---" >&2
    tail -30 "$LOG_FILE" >&2 || true
    kill "$NEW_PID" 2>/dev/null || true
    rm -f "$PID_FILE"
    exit 1
}

echo "==> Waiting for ${BASE_URL} to answer"
HEALTHY=""
for _ in $(seq 1 "$HEALTH_TIMEOUT"); do
    if curl -fsS --max-time 3 "${BASE_URL}/" >/dev/null 2>&1; then
        HEALTHY="yes"
        break
    fi
    kill -0 "$NEW_PID" 2>/dev/null || { echo "ERROR: process exited during startup" >&2; report_failure; }
    sleep 1
done
[ -n "$HEALTHY" ] || report_failure

echo "==> Smoke testing ${ENVIRONMENT}"
"${RUNTIME_VENV}/bin/python" scripts/smoke_test.py \
    "$BASE_URL" "${RELEASE_DIR}/test_assets/phone_sample.jpg" || report_failure

echo "==> ${ENVIRONMENT} running ${VERSION} on port ${PORT}"
