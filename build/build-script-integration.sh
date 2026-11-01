#!/usr/bin/env bash
# Build the standalone, no-GUI integration payload from committed source files.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '\r\n' < "$ROOT/VERSION")"
if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ]; then
    echo 'ERROR: commit the intended source before building a script-integration preview.' >&2
    exit 1
fi
SOURCE_SHA="$(git -C "$ROOT" rev-parse HEAD)"
DIST="$ROOT/dist"
STAGE="$(mktemp -d)"
ZIP_NAME="remote-access-tool-blocker-script-only-$VERSION-preview.zip"
ZIP_PATH="$DIST/$ZIP_NAME"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$DIST" "$STAGE/policy"

if ! command -v zip >/dev/null 2>&1; then
    echo 'ERROR: zip is required to build the script integration package.' >&2
    exit 1
fi
PYTHON=""
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then PYTHON="$candidate"; break; fi
done
[ -n "$PYTHON" ] || { echo 'ERROR: Python 3 is required to verify the package.' >&2; exit 1; }

INSTALLER="$(find "$ROOT/src/appcontrol" -maxdepth 1 -type f -name 'Install-RmmAppControl.v*.ps1' -print | LC_ALL=C sort | tail -n 1)"
REVERT="$(find "$ROOT/revert" -maxdepth 1 -type f -name 'Revert-RemoteAccessBlock-WinOnly.v*.ps1' -print | LC_ALL=C sort | tail -n 1)"
[ -n "$INSTALLER" ] || { echo 'ERROR: no App Control installer found.' >&2; exit 1; }
[ -n "$REVERT" ] || { echo 'ERROR: no Windows-only revert script found.' >&2; exit 1; }

cp "$ROOT/integration/Invoke-RemoteAccessProtection.ps1" "$STAGE/"
cp "$ROOT/integration/RemoteAccessProtection.psm1" "$ROOT/integration/RemoteAccessSafety.psm1" "$ROOT/integration/Start-Here.ps1" "$ROOT/integration/START-HERE.bat" "$ROOT/integration/Allow Remote Access.bat" "$STAGE/"
cp "$INSTALLER" "$STAGE/"
cp "$REVERT" "$STAGE/"
cp "$ROOT/revert/Run-Revert.bat" "$STAGE/"
cp "$ROOT/docs/script-integration-handoff.md" "$STAGE/HANDOFF-FOR-IMPLEMENTING-AGENT.md"
cp "$ROOT/integration/PREVIEW-NOT-A-RELEASE.txt" "$STAGE/PREVIEW-NOT-A-RELEASE.txt"
printf '%s\n' "$SOURCE_SHA" > "$STAGE/SOURCE-COMMIT.txt"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$ROOT/VERSION" "$ROOT/README.md" "$STAGE/"
cp -R "$ROOT/policy/." "$STAGE/policy/"
rm -f "$STAGE/policy/summary.txt"
for mode in Enforce Audit; do
    for extension in cip xml; do
        cp "$ROOT/policy/variants/RmmBlock-$mode-T1A1S1R1.$extension" "$STAGE/policy/RmmBlock-$mode.$extension"
    done
done

rm -f "$ZIP_PATH" "$ZIP_PATH.sha256"
(
    cd "$STAGE"
    find . -type f -print | sed 's|^./||' | LC_ALL=C sort | zip -q -X "$ZIP_PATH" -@
)
(
    cd "$DIST"
    "$PYTHON" -c 'import hashlib, pathlib, sys; p = pathlib.Path(sys.argv[1]); print(hashlib.sha256(p.read_bytes()).hexdigest() + "  " + p.name)' "$ZIP_PATH" > "$ZIP_NAME.sha256"
)
"$PYTHON" "$ROOT/tests/verify-script-integration-package.py" "$ZIP_PATH" --source-root "$ROOT"
sha256sum "$ZIP_PATH"
echo "Built $ZIP_PATH"
