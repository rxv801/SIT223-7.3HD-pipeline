#!/usr/bin/env bash
#
# Test stage — run the suite, emit JUnit XML for Jenkins and coverage XML for
# SonarCloud, and fail the build if either the tests or the coverage floor
# are not met.
#
#   ./scripts/test.sh
#
set -euo pipefail

CACHE_DIR="${HOME}/.jenkins-cache/sit223-7.3hd"
COVERAGE_MIN=85

cd "$(dirname "$0")/.."

REQ_HASH="$(cat requirements.txt requirements-dev.txt \
    | sed -e 's/#.*//' -e '/^[[:space:]]*$/d' \
    | shasum -a 256 | cut -c1-12)"
VENV="${CACHE_DIR}/venv-${REQ_HASH}"

if [ ! -x "${VENV}/bin/pytest" ]; then
    echo "ERROR: no test environment at ${VENV}" >&2
    echo "       Run ./scripts/build.sh first — it creates the venv." >&2
    exit 1
fi

# The detectors load their models relative to the repo, so the models must
# already be staged. build.sh does that; say so plainly if it has not run.
for model in models/yolox_s.onnx models/face_landmarker.task; do
    if [ ! -f "$model" ]; then
        echo "ERROR: ${model} missing — run ./scripts/build.sh first." >&2
        exit 1
    fi
done

mkdir -p reports

# cv2 must be imported before coverage.py starts tracing, or its bootstrap
# leaves cv2.dnn incomplete and the import fails. sitecustomize runs at
# interpreter startup, which is early enough. See scripts/pythonpath/.
export PYTHONPATH="$(pwd)/scripts/pythonpath${PYTHONPATH:+:${PYTHONPATH}}"

echo "==> Running tests (coverage floor ${COVERAGE_MIN}%)"
"${VENV}/bin/pytest" \
    --junitxml=reports/junit.xml \
    --cov --cov-report=xml:reports/coverage.xml --cov-report=term \
    --cov-fail-under="${COVERAGE_MIN}" \
    -v

echo "==> Tests OK"
