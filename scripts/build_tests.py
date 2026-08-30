#!/usr/bin/env python3
"""
Mirror src/ into tests/.build/ with Roblox-style requires rewritten to the
relative-path form the standalone `luau` CLI understands.

    require(script.Parent.Foo)              ->  require("./Foo")
    require(script.Parent.Parent.Types)     ->  require("../Types")
    require(script.Parent.Config.GameConfig)->  require("./Config/GameConfig")

`script` is the ModuleScript, so `script.Parent` is its own directory. N leading
Parents therefore means going up N-1 directories, then descending through the
remaining names.

This exists only so the pure-logic modules (Grid, ChunkCodec, Balance, config
tables) can be unit tested outside Studio. Roblox itself loads src/ directly.
"""

import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
OUT = ROOT / "tests" / ".build"

REQUIRE = re.compile(r"require\(\s*script((?:\.[A-Za-z_][A-Za-z0-9_]*)+)\s*\)")


def rewrite(match: re.Match) -> str:
    parts = match.group(1).lstrip(".").split(".")
    ups = 0
    while ups < len(parts) and parts[ups] == "Parent":
        ups += 1
    rest = parts[ups:]
    if ups == 0:
        # `require(script.Something)` — a child of the module itself.
        prefix = "./"
    else:
        prefix = "./" if ups == 1 else "../" * (ups - 1)
    return 'require("{}{}")'.format(prefix, "/".join(rest))


def main() -> int:
    if not SRC.is_dir():
        print(f"no src directory at {SRC}", file=sys.stderr)
        return 1

    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)

    count = 0
    for path in sorted(SRC.rglob("*.luau")):
        target = OUT / path.relative_to(SRC)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(REQUIRE.sub(rewrite, path.read_text()))
        count += 1

    print(f"  mirrored {count} modules into tests/.build")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
