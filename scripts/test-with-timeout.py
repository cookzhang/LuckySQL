#!/usr/bin/env python3
"""Run the built test suite with a bounded wait and native hang diagnostics."""

import os
from pathlib import Path
import signal
import subprocess
import sys


def main():
    subprocess.run(["swift", "build", "--build-tests"], check=True)
    env = dict(os.environ, NSUnbufferedIO="YES")
    process = subprocess.Popen(["swift", "test", "--skip-build"], env=env, start_new_session=True)
    try:
        return process.wait(timeout=180)
    except subprocess.TimeoutExpired:
        print("Tests exceeded 180 seconds; collecting native process samples.", flush=True)
        output = Path("test-diagnostics")
        output.mkdir(exist_ok=True)
        listing = subprocess.check_output(["ps", "-axo", "pid=,ppid=,comm="], text=True)
        (output / "processes.txt").write_text(listing)
        children = {}
        for line in listing.splitlines():
            pid, parent, command = line.strip().split(maxsplit=2)
            children.setdefault(int(parent), []).append((int(pid), command))
        pending = [process.pid]
        while pending:
            parent = pending.pop()
            for pid, command in children.get(parent, []):
                pending.append(pid)
                if "xctest" in command:
                    sample = output / f"xctest-{pid}.txt"
                    try:
                        subprocess.run(["sample", str(pid), "2", "-file", str(sample)], timeout=15, check=False)
                        if sample.exists():
                            print(sample.read_text()[:30000], flush=True)
                    except (OSError, subprocess.TimeoutExpired) as error:
                        print(f"Could not sample test process: {error}", flush=True)
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        return 124


if __name__ == "__main__":
    sys.exit(main())
