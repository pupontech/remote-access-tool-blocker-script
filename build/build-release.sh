#!/usr/bin/env bash
# Build only the optional Windows App Control GUI kit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '\r\n' < "$ROOT/VERSION")"
export ROOT VERSION
python3 - <<'PY'
import hashlib, os, pathlib, zipfile
root = pathlib.Path(os.environ['ROOT'])
version = os.environ['VERSION']
files = {'START-HERE.bat': root / 'kits/windows-only/START-HERE.bat'}
for folder, patterns in (
    ('kits/windows-only', ['Remote-Tools-Block-Windows.v*.ps1']),
    ('src/appcontrol', ['Build-RmmAppControl.v*.ps1', 'Install-RmmAppControl.v*.ps1', 'Run-RmmAppControl.bat']),
    ('revert', ['Revert-RemoteAccessBlock-WinOnly.v*.ps1', 'Run-Revert.bat']),
):
    for pattern in patterns:
        matches = sorted((root / folder).glob(pattern))
        if len(matches) != 1:
            raise SystemExit(f'Expected exactly one {folder}/{pattern}; found {len(matches)}')
        files[matches[0].name] = matches[0]
for name in ('VERSION', 'LICENSE', 'NOTICE', 'README.md'):
    files[name] = root / name
for path in (root / 'policy').rglob('*'):
    if path.is_file():
        files[path.relative_to(root).as_posix()] = path
out = root / 'dist' / f'remote-tools-block-windows-{version}.zip'
out.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(out, 'w', compression=zipfile.ZIP_DEFLATED) as z:
    for name, source in sorted(files.items()):
        info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(info, source.read_bytes())
digest = hashlib.sha256(out.read_bytes()).hexdigest()
out.with_name(out.name + '.sha256').write_text(digest + '  ' + out.name + '\n', encoding='ascii')
print(f'Built {out} ({len(files)} members)\nSHA256: {digest}')
PY
