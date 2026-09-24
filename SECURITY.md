# Security stage — findings and handling

Scope: the Taskmaster CV worker (`main.py`, `cv/`) and its dependencies.
Run by `scripts/security.sh` on every pipeline build.

## Tools

| Tool | Scans | Gate |
|---|---|---|
| Bandit 1.9.2 | our own Python source (SAST) | any HIGH fails the build |
| pip-audit 2.9.0 | `requirements.lock` — what Deploy installs | any finding fails the build |
| pip-audit 2.9.0 | the build/test venv | any finding fails the build |

Code Quality (SonarCloud) is a separate stage and deliberately not counted as
security: it measures code health, not exploitability.

## Findings

### 1. CVE-2025-71176 — pytest 8.4.2 — resolved

**What:** pytest through 9.0.2 creates temporary directories under the
predictable path `/tmp/pytest-of-{user}`. A local user can pre-create or
tamper with that directory to cause denial of service or potentially gain
privileges.

**Severity:** Moderate. Requires local access to the build machine, so it is
not remotely exploitable. It matters here because the Jenkins controller runs
as the same user the tests run as — anything that can write `/tmp` on the
build host could interfere with a build.

**Addressed:** upgraded to `pytest==9.0.3`. The full suite still passes at 92%
coverage, so the major-version bump cost nothing. Re-scan is clean.

### 2. CVE-2026-59890 — setuptools 82.0.1 — resolved

**What:** setuptools before 83.0.0 matched `MANIFEST.in` exclusion patterns
against on-disk filenames without Unicode normalisation. On macOS (APFS/HFS+)
a filename stored as NFD could slip past an NFC exclusion rule and be packaged
into a source distribution.

**Severity:** Low here, but the failure mode is unpleasant — files meant to be
excluded get published. This build runs on macOS APFS, which is exactly the
affected platform.

**Addressed:** pinned `setuptools>=83.0.0` in `requirements-dev.txt`. Nothing
in this project imports setuptools; it is present because every virtualenv
ships it, which is precisely why scanning the whole environment rather than
only the declared dependencies was worthwhile.

### 3. Application code — no findings

Bandit reports 0 high, 0 medium, 0 low across 714 lines of `main.py` and
`cv/`. No `# nosec` suppressions are in use, so that is a clean result rather
than a silenced one.

The worker's own attack surface is small by design: it binds to `127.0.0.1`
only, opens no camera, executes no subprocesses, and rejects frames above
`MAX_FRAME_BYTES` (5 MB) with WebSocket close code 1009 — which
`tests/test_api.py::test_websocket_rejects_oversized_frame` covers.

## Verifying the gates actually block

A gate that has never failed is not evidence of anything, so both were tested
against deliberately vulnerable input:

- `pip-audit` against `requests==2.19.1` reported **18** vulnerabilities across
  `requests`, `idna` and `urllib3`, and exited non-zero.
- Bandit against a file calling `subprocess.call(cmd, shell=True)` reported
  **B602 at HIGH severity**, which is the level that fails the build.

Neither test file is committed; both were scratch files used to confirm the
thresholds, then deleted.

## Residual risk

The scan is only as current as the advisory database at build time. A
dependency clean today can be vulnerable tomorrow with no code change, which
is why the pipeline polls SCM and re-scans on every build rather than treating
this as a one-off audit.
