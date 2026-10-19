"""Runs the headless tests (and optionally the benchmark), from the repository root:
    python tools/test.py            # tests
    python tools/test.py --bench    # tests, then the benchmark

Re-registers class_name scripts first (`--import`): an open Godot editor rewrites the global
class cache from its own view, so headless runs would otherwise miss classes added since.
Uses $GODOT, else `godot` on the PATH.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def godot() -> str:
    exe = os.environ.get("GODOT") or shutil.which("godot")
    if not exe:
        sys.exit("Set GODOT to the Godot executable (the _console.exe on Windows), or put godot on the PATH")
    return exe


def run(args: list[str]) -> int:
    return subprocess.run([godot(), "--headless", "--path", str(ROOT), *args]).returncode


def main() -> int:
    subprocess.run([godot(), "--headless", "--path", str(ROOT), "--import"], capture_output=True)
    code = run(["-s", "res://tests/run_tests.gd"])
    if code == 0 and "--bench" in sys.argv:
        code = run(["-s", "res://tests/bench.gd"])
    return code


if __name__ == "__main__":
    sys.exit(main())
