#!/usr/bin/env python3
"""
gen-toolkit-releases.py — owner of the releases-library convention.

Two jobs, run over every toolkits/<name>/manifest.org:

  1. Ensure each toolkit declares a per-toolkit version. The canonical source is
     the `#+VERSION:` file keyword (default 0.1.0 if absent). This mirrors that
     value into a `:VERSION:` property inside the first `:toolkit:` PROPERTIES
     drawer (right after `:ID:`) so the runtime's drawer-based `view/1` can
     surface it natively. Idempotent — never clobbers other props; if a drawer
     `:VERSION:` already exists it is re-synced to the `#+VERSION:` keyword.

  2. Regenerate toolkits/releases.json — the generated index
     { toolkit -> { version, updated } } — built from the manifests. `updated`
     is the manifest's last git-commit ISO date (falls back to file mtime).

Usage:  python3 scripts/gen-toolkit-releases.py
        python3 scripts/gen-toolkit-releases.py --check   # CI: fail if drift

The versioning scheme + tag format + release/rollback flow live in
toolkits/RELEASES.md. This script is what CI runs to keep releases.json honest.
"""
from __future__ import annotations

import datetime as dt
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOLKITS = ROOT / "toolkits"
INDEX = TOOLKITS / "releases.json"
DEFAULT_VERSION = "0.1.0"

KW_RE = re.compile(r"^#\+VERSION:\s*(.+?)\s*$", re.M)
# First :toolkit: drawer: the :ID: line, capturing its leading indent + spacing.
ID_RE = re.compile(r"^(?P<indent>[ \t]*):ID:(?P<gap>\s+)(?P<id>\S+)[ \t]*$", re.M)
DRAWER_VER_RE = re.compile(r"^[ \t]*:VERSION:[ \t]*.*$", re.M)


def keyword_version(text: str) -> str:
    m = KW_RE.search(text)
    return m.group(1).strip() if m else DEFAULT_VERSION


def ensure_drawer_version(text: str, version: str) -> str:
    """Mirror `version` into the first PROPERTIES drawer as :VERSION:."""
    id_m = ID_RE.search(text)
    if not id_m:
        return text  # no drawer to anchor onto; keyword is still authoritative

    indent, gap = id_m.group("indent"), id_m.group("gap")
    ver_line = f"{indent}:VERSION:{gap}{version}"

    existing = DRAWER_VER_RE.search(text)
    if existing:
        # Re-sync existing drawer :VERSION: to the keyword value.
        return text[: existing.start()] + ver_line + text[existing.end() :]

    # Insert a :VERSION: line directly after the :ID: line.
    insert_at = id_m.end()
    return text[:insert_at] + "\n" + ver_line + text[insert_at:]


def git_iso_date(path: Path) -> str:
    try:
        out = subprocess.run(
            ["git", "-C", str(ROOT), "log", "-1", "--format=%cI", "--", str(path)],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        if out:
            return out[:10]  # YYYY-MM-DD
    except Exception:
        pass
    ts = path.stat().st_mtime
    return dt.datetime.utcfromtimestamp(ts).date().isoformat()


def main() -> int:
    check = "--check" in sys.argv[1:]
    manifests = sorted(TOOLKITS.glob("*/manifest.org"))
    index: dict[str, dict[str, str]] = {}
    drift = False

    for manifest in manifests:
        name = manifest.parent.name
        text = manifest.read_text()
        version = keyword_version(text)
        new_text = ensure_drawer_version(text, version)

        if new_text != text:
            if check:
                drift = True
                print(f"DRIFT: {name}/manifest.org missing/stale :VERSION: drawer property")
            else:
                manifest.write_text(new_text)
                print(f"updated {name}/manifest.org :VERSION: -> {version}")

        index[name] = {
            "version": version,
            "versions": [version],
            "updated": git_iso_date(manifest),
        }

    # Schema note: top-level keys are toolkit ids -> {version, versions[], updated}.
    # This is exactly what runtime/host/toolkits.ex `releases/1` consumes (it reads
    # `releases(root)[id]["versions"]`), so the generated index doubles as the
    # release index the `wbx toolkit versions/rollback` verbs read. Do NOT nest the
    # toolkits under a "toolkits" key — the runtime reads them at the top level.
    payload = {k: index[k] for k in sorted(index)}
    rendered = json.dumps(payload, indent=2) + "\n"

    if check:
        current = INDEX.read_text() if INDEX.exists() else ""
        if current != rendered:
            drift = True
            print("DRIFT: releases.json out of date — run scripts/gen-toolkit-releases.py")
        return 1 if drift else 0

    INDEX.write_text(rendered)
    print(f"wrote {INDEX.relative_to(ROOT)} ({len(index)} toolkits)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
