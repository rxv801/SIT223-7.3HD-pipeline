# SIT223 7.3HD — Jenkins DevOps pipeline

Saatvik Sharma (225158822)

A seven stage Jenkins pipeline built around the computer vision worker from
[Taskmaster](https://github.com/rxv801/taskmaster), a desktop focus tracker.
The worker takes webcam frames over a WebSocket and returns two results per
frame: whether a phone is visible, and whether the user is looking at the
screen.

The worker code was extracted from the Taskmaster repository with
`git subtree split`, so the commit history for it is preserved here.

## The pipeline

Defined in [`Jenkinsfile`](Jenkinsfile). Each stage is one line calling a
script in [`scripts/`](scripts), so any stage can be run from a terminal
without starting a Jenkins build.

| Stage | Script | What it does | What fails the build |
|---|---|---|---|
| Build | `build.sh` | pins Python 3.11, fetches both models, compiles, writes `requirements.lock`, builds a versioned tarball | syntax error, missing or truncated model |
| Test | `test.sh` | 17 pytest tests, unit and integration | any failure, or coverage under 85% |
| Code Quality | `quality.sh` | ruff, then SonarQube Cloud analysis | lint error, or a red quality gate |
| Security | `security.sh` | Bandit on the source, pip-audit on the lock and on the build venv | any HIGH from Bandit, any CVE |
| Deploy | `deploy.sh staging` | unpacks the artefact to port 8766, health check, smoke test | service does not start, or no detection |
| Release | `release.sh` | tags the version, promotes the same artefact to port 8765 | unhealthy staging, or failed rollout |
| Monitoring | `monitoring.sh` | validates and publishes Prometheus config, reloads, checks prod is scraped | invalid rules, or prod not being scraped |

No stage swallows failures. There is no `|| true` anywhere in the pipeline.

## Running it

Requires macOS with Homebrew, Python 3.11, Jenkins LTS and Prometheus.

```bash
brew install python@3.11 jenkins-lts prometheus
```

Each stage runs standalone:

```bash
./scripts/build.sh                 # produces dist/taskmaster-worker-1.0.dev.tar.gz
./scripts/test.sh                  # needs build.sh first, for the venv and models
SONAR_TOKEN=xxx ./scripts/quality.sh
./scripts/security.sh
./scripts/deploy.sh staging        # serves on 127.0.0.1:8766
./scripts/release.sh               # promotes to 127.0.0.1:8765
./scripts/monitoring.sh            # needs Prometheus running
```

In Jenkins, create a Pipeline job with:

- Definition: Pipeline script from SCM
- SCM: Git, this repository URL, branch `*/main`
- Script path: `Jenkinsfile`
- Build trigger: Poll SCM, `H/5 * * * *`

The only credential needed is a SonarQube Cloud token stored as `SONAR_TOKEN`.
Polling is used rather than a webhook because the Jenkins controller listens on
`127.0.0.1`, which GitHub cannot reach.

## Two models are downloaded, not committed

`yolox_s.onnx` (36 MB) for phone detection and `face_landmarker.task` (3.8 MB)
for gaze. Both are gitignored, so a fresh clone has neither. `build.sh` fetches
and caches them, and checks the size of each so a truncated download or an HTML
error page cannot be saved as a model.

## Security

Findings and how each was handled are in [`SECURITY.md`](SECURITY.md).

## About the worker itself

The browser owns the camera and sends frames to Python, so Python never opens a
camera. That keeps the detectors as pure functions and lets the whole service
run headless, which is what makes it testable in CI.

- `main.py` — FastAPI app, `/` health check, `/ws` detection socket, `/metrics`
- `cv/phone_detector.py` — YOLOX-S via ONNX Runtime
- `cv/gaze_detector.py` — MediaPipe FaceLandmarker head pose
- `cv/camera.py`, `cv/detection_loop.py` — used by the desktop app, not by the service

MediaPipe is pinned to 0.10.35. Version 1.0.x aborts the interpreter when the
face detector subgraph initialises Metal in a headless process.
