"""Project consistency checks (docs/style.md): gdlint plus the mechanical house rules.

Run from the repository root before committing, next to the tests:
    python tools/check.py

Exits non-zero on any finding. Each rule names the style-guide section it enforces.
"""

import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CODE_DIRS = ["sim", "render", "ui", "debug", "scenes", "tests"]
# Layers that sim/ must never depend on (D5: the sim is pure data; render and UI read it).
PRESENTATION_DIRS = ["render", "ui", "scenes", "debug"]

# One home per formula (style.md "One source of truth"): a pattern that may only appear in its
# home file (or a tuple of homes: one per language, when C# can't read the GDScript constant). Add an entry whenever a formula is centralized, so copies can't creep back.
ONE_HOME = [
    (r"surface_absorptivity\[\w+\]\s*\*\s*Spectrum\.AM15_SHARE", "sim/material_db.gd",
     "sun-weighted absorptivity: use MaterialDB.sun_absorptivity"),
    (r"time_of_day\(\)\s*-\s*0\.25", "sim/environment_system.gd",
     "arc angle from the clock: use world.sun_arc_angle / moon_arc_angle"),
    (r"power_scale\([^)]*\)\s*/\s*\(?\s*SimConst\.TILE_M", "sim/light/light_system.gd",
     "tile watts to W/m²: use LightSystem.irradiance_scale"),
    (r"MOON_FULL_RATIO\s*(?:if|\))", "render/display_light.gd",
     "night exposure: use DisplayLight.exposure"),
    (r"\"UV %s · visible %s · IR %s\"", "ui/readout.gd", "band readout: use Readout.bands"),
    (r"TILE_PX\s*/\s*(?:SimConst\.)?TILE_M", "sim/constants.gd", "pixels per meter: use SimConst.PX_PER_M"),
    (r"size_m\s*\*\s*SimConst\.DEPTH_M", "sim/objects/object_def.gd", "face area: use ObjectDef.face_area_m2"),
    (r"86400\.0\s*/\s*(?:SimConst\.)?DAY_LENGTH_S|DAY_LENGTH_S\s*/\s*86400", "sim/constants.gd",
     "game day to real time: use SimConst.DAY_COMPRESSION"),
    (r"5\.670\d*e-8", ("sim/constants.gd", "sim/thermal/HeatKernel.cs"),
     "Stefan–Boltzmann: use SimConst.STEFAN_BOLTZMANN (C#: HeatKernel.StefanBoltzmann)"),
]


def code_files(exts=(".gd",)):
    for d in CODE_DIRS:
        for p in sorted((ROOT / d).rglob("*")):
            if p.suffix in exts and p.is_file():
                yield p


def rel(p: Path) -> str:
    return p.relative_to(ROOT).as_posix()


def strip_comments_and_strings(line: str) -> str:
    """Code only: string literals blanked, comments removed (good enough for these rules)."""
    line = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)
    line = re.sub(r"'(?:[^'\\]|\\.)*'", "''", line)
    line = re.sub(r"//.*$", "", line)  # C#
    return re.sub(r"#.*$", "", line)


def read(p: Path) -> str:
    return p.read_bytes().decode("utf-8")


def check_gdlint(findings):
    exe = shutil.which("gdlint")
    if exe is None:
        findings.append("gdlint not found: pip install 'gdtoolkit==4.*'")
        return
    result = subprocess.run([exe, *CODE_DIRS], cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        for line in (result.stdout + result.stderr).splitlines():
            if "Error" in line:
                findings.append("gdlint: " + line.strip())


def class_names(dirs, exts=(".gd", ".cs")):
    names = set()
    for d in dirs:
        for p in (ROOT / d).rglob("*"):
            if p.suffix not in exts or not p.is_file():
                continue
            text = read(p)
            names.update(re.findall(r"^class_name\s+(\w+)", text, re.M))
            names.update(re.findall(r"^public (?:partial )?class\s+(\w+)", text, re.M))
    return names


def check_layering(findings):
    presentation = class_names(PRESENTATION_DIRS)
    for p in (ROOT / "sim").rglob("*"):
        if p.suffix not in (".gd", ".cs"):
            continue
        for n, line in enumerate(read(p).splitlines(), 1):
            code = strip_comments_and_strings(line)
            for name in presentation:
                if re.search(r"\b%s\b" % name, code):
                    findings.append(f"{rel(p)}:{n}: sim uses presentation class {name} (layering, D5)")


def check_private_access(findings):
    for p in code_files():
        text = read(p)
        own = set(re.findall(r"^\s*(?:static\s+)?(?:var|const|func|signal)\s+(_\w+)", text, re.M))
        own.update(re.findall(r"^enum\s+(_\w+)", text, re.M))
        for n, line in enumerate(text.splitlines(), 1):
            code = strip_comments_and_strings(line)
            for m in re.finditer(r"(\w|\)|\])\._([a-z]\w*)", code):
                name = "_" + m.group(2)
                receiver = code[: m.start() + 1]
                if receiver.endswith("self") or name in own:
                    continue
                findings.append(f"{rel(p)}:{n}: uses another class's private {name} (privacy)")


def check_one_home(findings):
    for p in code_files((".gd", ".cs", ".gdshader")):
        text = read(p)
        for pattern, home, why in ONE_HOME:
            if rel(p) in (home if isinstance(home, tuple) else (home,)):
                continue
            for n, line in enumerate(text.splitlines(), 1):
                if re.search(pattern, line):
                    findings.append(f"{rel(p)}:{n}: {why} (one source of truth)")


def check_class_docs(findings):
    for p in code_files():
        head = read(p).splitlines()[:4]
        if not any(line.startswith("##") for line in head):
            findings.append(f"{rel(p)}:1: missing ## doc comment under extends (docs)")


def check_mid_line_tabs(findings):
    """A tab after code on a line is a continuation (`\\` + newline) that got joined."""
    for p in code_files((".gd", ".gdshader")):
        for n, line in enumerate(read(p).splitlines(), 1):
            if re.search(r"\S *\t", strip_comments_and_strings(line).rstrip()):
                findings.append(f"{rel(p)}:{n}: tab inside a line (a joined line continuation?)")


def check_line_endings(findings):
    for p in code_files((".gd", ".cs", ".gdshader")):
        data = p.read_bytes()
        crlf = data.count(b"\r\n")
        lf = data.count(b"\n") - crlf
        if crlf and lf:
            findings.append(f"{rel(p)}: mixed line endings ({crlf} CRLF, {lf} LF)")


def main() -> int:
    findings: list[str] = []
    for rule in (check_gdlint, check_layering, check_private_access, check_one_home,
                 check_class_docs, check_mid_line_tabs, check_line_endings):
        rule(findings)
    for f in findings:
        print(f)
    print(f"{len(findings)} finding(s)" if findings else "All checks passed")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
