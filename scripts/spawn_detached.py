"""Start a long-running process detached from this one, and print its PID.

macOS ships no setsid(1), and a plain `nohup ... &` leaves the child in
Jenkins' process group — Jenkins reaps that group when the build step ends, so
the service dies seconds after the pipeline calls the deploy a success.

subprocess.Popen(start_new_session=True) calls setsid(2) in the child, which
puts it in its own session.

That alone is not enough under Jenkins. Its ProcessTreeKiller does not walk the
process tree — it scans every process on the machine for the build's
JENKINS_NODE_COOKIE in the environment and kills whatever matches, so a new
session hides nothing. The deployed server survived its smoke test and was then
shut down cleanly moments later, which is exactly what that looks like. The
documented escape is to drop the cookie from the child's environment.

    python scripts/spawn_detached.py <logfile> <command> [args...]
"""

import os
import subprocess
import sys

log_path, command = sys.argv[1], sys.argv[2:]

if not command:
    raise SystemExit("usage: spawn_detached.py <logfile> <command> [args...]")

environment = os.environ.copy()
for variable in ("JENKINS_NODE_COOKIE", "JENKINS_SERVER_COOKIE", "BUILD_ID"):
    environment.pop(variable, None)

with open(log_path, "ab", buffering=0) as log:
    process = subprocess.Popen(
        command,
        stdout=log,
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
        cwd=os.getcwd(),
        env=environment,
    )

print(process.pid)
