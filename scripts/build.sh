#!/usr/bin/env bash
#
# Build stage — prepare the environment and produce a deployable artefact.
#
# Runs the same way locally and under Jenkins. Jenkins supplies BUILD_NUMBER;
# a local run falls back to "dev" so you can test without a job.
#
#   ./scripts/build.sh
#
set -euo pipefail

VERSION="1.0.${BUILD_NUMBER:-dev}"
CACHE_DIR="${HOME}/.jenkins-cache/sit223-7.3hd"
DIST_DIR="dist"

# Both detector models are gitignored (*.onnx, *.task) because they are large
# binaries. Each entry is "filename|url|minimum plausible size in bytes".
# Same sources as the project's own setup.sh.
MODELS=(
  "yolox_s.onnx|https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/yolox_s.onnx|30000000"
  "face_landmarker.task|https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/latest/face_landmarker.task|3000000"
)

cd "$(dirname "$0")/.."
echo "==> Build ${VERSION}"

# ---------------------------------------------------------------------------
# 1. Pin the interpreter.
#
# MediaPipe publishes no wheels for Python 3.13/3.14 (see requirements.txt),
# and the system default here is 3.14 — so resolving "python3" from PATH would
# fail at pip install. Pin 3.11 explicitly and fail early with a fixable message.
# ---------------------------------------------------------------------------
PYTHON_BIN="/opt/homebrew/opt/python@3.11/bin/python3.11"
if [ ! -x "$PYTHON_BIN" ]; then
    echo "ERROR: Python 3.11 not found at ${PYTHON_BIN}" >&2
    echo "       MediaPipe has no wheels for 3.13/3.14, so 3.11 is required." >&2
    echo "       Install it with: brew install python@3.11" >&2
    exit 1
fi
echo "==> Interpreter: $("$PYTHON_BIN" -V)"

# ---------------------------------------------------------------------------
# 2. Virtualenv, cached outside the workspace.
#
# Kept in CACHE_DIR rather than the workspace so the ws-cleanup plugin can't
# force a ~500MB MediaPipe reinstall on every build. The requirements hash is
# part of the path, so changing a dependency builds a fresh venv automatically
# and leaves the old one untouched.
# ---------------------------------------------------------------------------
REQ_HASH="$(shasum -a 256 requirements.txt | cut -c1-12)"
VENV="${CACHE_DIR}/venv-${REQ_HASH}"

if [ -x "${VENV}/bin/python" ]; then
    echo "==> Reusing cached venv (requirements ${REQ_HASH})"
else
    echo "==> Building venv (requirements ${REQ_HASH}) — first run downloads ~500MB"
    mkdir -p "$CACHE_DIR"
    rm -rf "$VENV"
    "$PYTHON_BIN" -m venv "$VENV"
    "${VENV}/bin/python" -m pip install --upgrade pip --quiet
    "${VENV}/bin/pip" install -r requirements.txt
fi

# ---------------------------------------------------------------------------
# 3. Detector models.
#
# Both are gitignored, so a fresh clone has neither: phone detection needs
# yolox_s.onnx and gaze detection needs face_landmarker.task. Fetch once, cache
# them, and size-check each so a truncated download or an HTML error page can't
# masquerade as a model.
# ---------------------------------------------------------------------------
mkdir -p models "$CACHE_DIR"
for entry in "${MODELS[@]}"; do
    IFS='|' read -r NAME URL MIN_BYTES <<< "$entry"
    CACHED="${CACHE_DIR}/${NAME}"

    if [ -f "$CACHED" ] && [ "$(stat -f%z "$CACHED")" -ge "$MIN_BYTES" ]; then
        echo "==> Reusing cached ${NAME}"
    else
        echo "==> Downloading ${NAME}"
        curl -fsSL --retry 3 -o "${CACHED}.tmp" "$URL"
        SIZE="$(stat -f%z "${CACHED}.tmp")"
        if [ "$SIZE" -lt "$MIN_BYTES" ]; then
            rm -f "${CACHED}.tmp"
            echo "ERROR: ${NAME} download was only ${SIZE} bytes — expected >= ${MIN_BYTES}" >&2
            exit 1
        fi
        mv "${CACHED}.tmp" "$CACHED"
    fi

    cp "$CACHED" "models/${NAME}"
    echo "==> Staged models/${NAME} ($(stat -f%z "models/${NAME}") bytes)"
done

# ---------------------------------------------------------------------------
# 4. Compile check — the actual build gate for an interpreted project.
# ---------------------------------------------------------------------------
echo "==> Compiling sources"
"${VENV}/bin/python" -m compileall -q main.py cv

# ---------------------------------------------------------------------------
# 5. Lock resolved versions.
#
# requirements.txt uses floors (>=), so the same file resolves differently over
# time. The lock records what this build actually installed — it's what the
# security stage scans and what Deploy installs, so all three agree.
# ---------------------------------------------------------------------------
echo "==> Freezing dependency versions"
"${VENV}/bin/pip" freeze > requirements.lock

# ---------------------------------------------------------------------------
# 6. Artefact.
#
# Source + model + lock, so a deploy needs no network. Excludes the venv, caches
# and any previous dist output.
# ---------------------------------------------------------------------------
ARTEFACT="${DIST_DIR}/taskmaster-worker-${VERSION}.tar.gz"
echo "==> Packaging ${ARTEFACT}"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

cat > VERSION <<EOF
version=${VERSION}
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
python=$("$PYTHON_BIN" -V 2>&1)
EOF

tar --exclude='./dist' \
    --exclude='./.git' \
    --exclude='./__pycache__' \
    --exclude='*.pyc' \
    --exclude='./build' \
    -czf "$ARTEFACT" \
    main.py cv models requirements.txt requirements.lock test_assets VERSION

echo "==> Artefact: ${ARTEFACT} ($(stat -f%z "$ARTEFACT") bytes)"
echo "==> Build ${VERSION} OK"
