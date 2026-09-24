"""Start a long-running process detached from this one, and print its PID.

macOS ships no setsid(1), and a plain `nohup ... &` leaves the child in
Jenkins' process group — Jenkins reaps that group when the build step ends, so
the service dies seconds after the pipeline calls the deploy a success.

subprocess.Popen(start_new_session=True) calls setsid(2) in the child, which
puts it in its own session and detaches it from Jenkins entirely.

    python scripts/spawn_detached.py <logfile> <command> [args...]
"""

import os
import subprocess
import sys

log_path, command = sys.argv[1], sys.argv[2:]

if not command:
    raise SystemExit("usage: spawn_detached.py <logfile> <command> [args...]")

with open(log_path, "ab", buffering=0) as log:
    process = subprocess.Popen(
        command,
        stdout=log,
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
        cwd=os.getcwd(),
    )

print(process.pid)
