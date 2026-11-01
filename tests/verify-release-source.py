"""Verify Windows-only GUI ZIP against an exact Git commit and closed member set."""
import argparse
import hashlib
from pathlib import Path, PurePosixPath
import subprocess
import zipfile


def verify(archive, commit):
    tracked = subprocess.check_output(
        ['git', 'ls-tree', '-r', '--name-only', commit], text=True
    ).splitlines()
    mapping = {'START-HERE.bat': 'kits/windows-only/START-HERE.bat',
               'RemoteAccessSafety.psm1': 'integration/RemoteAccessSafety.psm1',
               'RemoteAccessSafety.i18n.json': 'integration/RemoteAccessSafety.i18n.json'}
    for path in tracked:
        if path.startswith('policy/'):
            mapping[path] = path
        elif path in ('VERSION', 'LICENSE', 'NOTICE', 'README.md'):
            mapping[path] = path
        elif (path.startswith('src/appcontrol/') or
              path.startswith('kits/windows-only/') and path.endswith('.ps1') or
              path.startswith('revert/Revert-RemoteAccessBlock-WinOnly.v') or
              path == 'revert/Run-Revert.bat'):
            mapping[PurePosixPath(path).name] = path
    with zipfile.ZipFile(archive) as bundle:
        names = bundle.namelist()
        assert bundle.testzip() is None, 'ZIP corruption'
        assert len(names) == len(set(names)), 'duplicate ZIP members'
        assert set(names) == set(mapping), ('member set mismatch', set(names) ^ set(mapping))
        for name, source in mapping.items():
            expected = subprocess.check_output(['git', 'show', commit + ':' + source])
            assert bundle.read(name) == expected, ('source mismatch', name, source)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    assert archive.with_suffix('.zip.sha256').read_text().split() == [digest, archive.name], 'checksum mismatch'
    print(f'PASS: {len(names)} Windows-only members exactly match {commit}; SHA256 {digest}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--commit', default='HEAD')
    args = parser.parse_args()
    verify(args.archive, args.commit)
