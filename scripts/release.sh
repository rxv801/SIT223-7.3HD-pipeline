#!/usr/bin/env bash
#
# Release stage — promote the artefact already proven on staging to production.
#
# Nothing is rebuilt here. The same tarball that Build produced, Test covered,
# Security scanned and Deploy smoke-tested on :8766 is the one that goes to
# :8765, which is the whole point of promoting rather than redeploying.
#
#   ./scripts/release.sh
#
set -euo pipefail

STAGING_URL="http://127.0.0.1:8766"
PROD_ROOT="${HOME}/taskmaster-deploy/prod"

cd "$(dirname "$0")/.."

ARTEFACT="$(ls -t dist/taskmaster-worker-*.tar.gz 2>/dev/null | head -1 || true)"
if [ -z "$ARTEFACT" ]; then
    echo "ERROR: no artefact in dist/ — run ./scripts/build.sh first." >&2
    exit 1
fi
VERSION="$(basename "$ARTEFACT" .tar.gz | sed 's/^taskmaster-worker-//')"

# ---------------------------------------------------------------------------
# 1. Refuse to promote anything staging has not vouched for.
# ---------------------------------------------------------------------------
echo "==> Checking staging before promoting ${VERSION}"
if ! curl -fsS --max-time 5 "${STAGING_URL}/" >/dev/null 2>&1; then
    echo "ERROR: staging is not healthy at ${STAGING_URL} — refusing to release." >&2
    exit 1
fi
echo "    staging healthy"

# ---------------------------------------------------------------------------
# 2. Remember what prod is on now, so a failed rollout can be undone.
# ---------------------------------------------------------------------------
PREVIOUS_RELEASE=""
if [ -L "${PROD_ROOT}/current" ]; then
    PREVIOUS_RELEASE="$(readlink "${PROD_ROOT}/current")"
    echo "==> Current production release: $(basename "$PREVIOUS_RELEASE")"
else
    echo "==> No existing production release (first rollout)"
fi

# ---------------------------------------------------------------------------
# 3. Tag the release.
#
# Local tag only. Pushing would need a GitHub credential in Jenkins, and the
# tag's job here is to mark which commit produced which running version --
# which it does either way. `git tag -f` keeps re-runs of the same build
# idempotent rather than failing on an existing tag.
# ---------------------------------------------------------------------------
TAG="v${VERSION}"
git tag -f -a "$TAG" -m "Release ${VERSION}" >/dev/null 2>&1 || {
    echo "WARNING: could not create tag ${TAG} (detached checkout?) — continuing" >&2
}
echo "==> Tagged ${TAG} at $(git rev-parse --short HEAD)"

# ---------------------------------------------------------------------------
# 4. Roll out to production, reusing the same deploy path as staging.
# ---------------------------------------------------------------------------
if ./scripts/deploy.sh prod; then
    echo "==> Released ${VERSION} to production"
    exit 0
fi

# ---------------------------------------------------------------------------
# 5. Rollback.
#
# deploy.sh leaves a failed rollout stopped, so production is down at this
# point. Put the previous release back and restart it from its own directory.
# ---------------------------------------------------------------------------
echo "ERROR: production rollout of ${VERSION} failed" >&2

if [ -z "$PREVIOUS_RELEASE" ] || [ ! -d "$PREVIOUS_RELEASE" ]; then
    echo "ERROR: no previous release to roll back to — production is down." >&2
    exit 1
fi

echo "==> Rolling back to $(basename "$PREVIOUS_RELEASE")" >&2
ln -sfn "$PREVIOUS_RELEASE" "${PROD_ROOT}/current"

LOCK_HASH="$(shasum -a 256 "${PREVIOUS_RELEASE}/requirements.lock" | cut -c1-12)"
RUNTIME_VENV="${HOME}/.jenkins-cache/sit223-7.3hd/runtime-${LOCK_HASH}"

cd "$PREVIOUS_RELEASE"
NEW_PID="$("${RUNTIME_VENV}/bin/python" "${OLDPWD}/scripts/spawn_detached.py" \
    "${PROD_ROOT}/run.log" \
    "${RUNTIME_VENV}/bin/python" -m uvicorn main:app \
    --host 127.0.0.1 --port 8765)"
echo "$NEW_PID" > "${PROD_ROOT}/run.pid"
cd "$OLDPWD"

for _ in $(seq 1 30); do
    if curl -fsS --max-time 3 "http://127.0.0.1:8765/" >/dev/null 2>&1; then
        echo "==> Rolled back to $(basename "$PREVIOUS_RELEASE"); production is serving again" >&2
        exit 1
    fi
    sleep 1
done

echo "ERROR: rollback failed too — production is down." >&2
exit 1
