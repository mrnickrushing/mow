#!/usr/bin/env bash
# Full verification gate: sourcemap -> typecheck -> tests -> place build.
#
# Requires three CLIs on PATH (or via LUAU_BIN / LUAU_LSP_BIN / ROJO_BIN):
#   luau      https://github.com/luau-lang/luau/releases
#   luau-lsp  https://github.com/JohnnyMorganz/luau-lsp/releases
#   rojo      https://github.com/rojo-rbx/rojo/releases
# `rokit install` fetches all three at the pinned versions.
#
# The Roblox API type definitions must match the luau-lsp version, so both are
# pinned to LSP_VERSION below.
set -uo pipefail
cd "$(dirname "$0")/.."

LSP_VERSION="1.49.1"
LUAU="${LUAU_BIN:-luau}"
ANALYZE="${LUAU_LSP_BIN:-luau-lsp}"
ROJO="${ROJO_BIN:-rojo}"
DEFS=".tools/globalTypes.d.luau"
SETTINGS=".tools/settings.json"
DEFS_URL="https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/${LSP_VERSION}/scripts/globalTypes.d.luau"

mkdir -p .tools
if [ ! -f "$DEFS" ]; then
	echo "== fetching Roblox type definitions (luau-lsp ${LSP_VERSION}) =="
	curl -sSfL -o "$DEFS" "$DEFS_URL" || { echo "  could not fetch $DEFS_URL"; exit 1; }
fi
[ -f "$SETTINGS" ] || echo '{ "luau-lsp.require.mode": "relativeToFile" }' > "$SETTINGS"

fail=0

echo "== sourcemap =="
if "$ROJO" sourcemap default.project.json -o sourcemap.json; then
	echo "  sourcemap ok"
else
	echo "  SOURCEMAP FAILED"
	exit 1
fi

echo "== typecheck =="
if "$ANALYZE" analyze \
	--definitions="$DEFS" \
	--sourcemap=sourcemap.json \
	--settings="$SETTINGS" \
	$(find src tests -path tests/.build -prune -o -name '*.luau' -print | sort); then
	echo "  types ok"
else
	echo "  TYPE ERRORS"
	fail=1
fi

echo "== tests =="
python3 scripts/build_tests.py || { echo "  TEST BUILD FAILED"; exit 1; }
if "$LUAU" tests/run.luau; then
	echo "  tests ok"
else
	echo "  TEST FAILURES"
	fail=1
fi

echo "== build =="
mkdir -p build
if "$ROJO" build default.project.json -o build/MowAllTheLawns.rbxl >/dev/null; then
	echo "  place builds ok"
else
	echo "  BUILD FAILED"
	fail=1
fi

if [ "$fail" -eq 0 ]; then echo; echo "ALL CHECKS PASSED"; fi
exit $fail
