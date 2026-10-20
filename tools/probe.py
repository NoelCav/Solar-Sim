"""SimProbe headless: build a test scenario (or the saved site), trace its light, run commands.

    python tools/probe.py power_farm --hour 12 state objects
    python tools/probe.py edge_optics 'truth {"x0": 30, "x1": 50}' 'symmetry {"about": -24}'
    python tools/probe.py saved 'tile {"x": 40, "y": 20}'          # the player's site, unchanged
    python tools/probe.py demo help                                 # every command

Each command is a name, optionally followed by its JSON arguments in the same argument. Prints
one JSON answer per command (pretty, unless --raw). Commands run in order on one world, so edits
(place, move, time, step) affect the commands after them. Uses $GODOT, else `godot` on the PATH.
"""

import json
import subprocess
import sys

from test import ROOT, godot


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    site, rest = args[0], args[1:]
    hour = ""
    raw = False
    cmds = []
    k = 0
    while k < len(rest):
        a = rest[k]
        if a == "--hour":
            hour = rest[k + 1]
            k += 2
            continue
        if a == "--raw":
            raw = True
        else:
            name, _, js = a.partition(" ")
            cmds.append([name, json.loads(js) if js.strip() else {}])
        k += 1
    if not cmds:
        cmds = [["state", {}]]
    user = [f"--site={site}", f"--cmds={json.dumps(cmds)}"] + ([f"--hour={hour}"] if hour else [])
    out = subprocess.run([godot(), "--headless", "--path", str(ROOT), "-s", "res://debug/probe_cli.gd", "--", *user],
                         capture_output=True, text=True, encoding="utf-8", errors="replace")
    code = 0
    for line in out.stdout.splitlines():
        if not line.startswith("{"):
            continue
        data = json.loads(line)
        if "error" in data or "error" in data.get("result", {}):
            code = 1
        print(line if raw else json.dumps(data, indent=1))
    errors = [line for line in out.stderr.splitlines() if "ERROR" in line or "SCRIPT" in line]
    for line in errors:
        print(line, file=sys.stderr)
    return code or (1 if errors else 0)


if __name__ == "__main__":
    sys.exit(main())
