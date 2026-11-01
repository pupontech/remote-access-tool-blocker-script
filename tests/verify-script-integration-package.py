#!/usr/bin/env python3
"""Verify the standalone script-integration ZIP and its source parity."""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import re
import subprocess
import sys
import zipfile
from pathlib import Path, PurePosixPath
from typing import NoReturn


def fail(message: str) -> NoReturn:
    raise SystemExit(f"FAIL: {message}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("--source-root", type=Path, required=True)
    args = parser.parse_args()
    archive = args.archive.resolve()
    source_root = args.source_root.resolve()
    if not archive.is_file():
        fail(f"archive not found: {archive}")
    if not archive.name.endswith("-preview.zip"):
        fail("script integration builds must be labelled preview, not as the current stable release")

    with zipfile.ZipFile(archive) as zf:
        names = zf.namelist()
        if len(names) != len(set(names)):
            fail("duplicate ZIP members")
        if bad_member := zf.testzip():
            fail(f"CRC failure in {bad_member}")
        for name in names:
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or "\\" in name:
                fail(f"unsafe member path: {name}")

        required = {
            "Invoke-RemoteAccessProtection.ps1",
            "RemoteAccessProtection.psm1",
            "RemoteAccessSafety.psm1",
            "RemoteAccessSafety.i18n.json",
            "Start-Here.ps1",
            "START-HERE.bat",
            "Allow Remote Access.bat",
            "Run-Revert.bat",
            "HANDOFF-FOR-IMPLEMENTING-AGENT.md",
            "PREVIEW-NOT-A-RELEASE.txt",
            "SOURCE-COMMIT.txt",
            "VERSION",
            "LICENSE",
            "NOTICE",
            "README.md",
            "policy/RmmBlock-Enforce.cip",
            "policy/RmmBlock-Audit.cip",
            "policy/signers.csv",
            "policy/skipped-signers.csv",
            "policy/variants/RmmBlock-Enforce-T1A1S1R1.cip",
            "policy/variants/RmmBlock-Enforce-T1A1S1R1.xml",
        }
        missing = sorted(required - set(names))
        if missing:
            fail(f"required members missing: {', '.join(missing)}")

        try:
            catalog = json.loads(zf.read("RemoteAccessSafety.i18n.json").decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            fail(f"localized warning catalog is not valid UTF-8 JSON: {error}")
        fields = ("LanguageName", "Title", "Yes", "No", "Cancel", "LanguageLabel", "Instruction")
        for language in ("en", "he"):
            entry = catalog.get(language, {})
            if any(not isinstance(entry.get(field), str) or not entry[field].strip() for field in fields):
                fail(f"missing localized dialog labels for {language}")
            stages = entry.get("Stages")
            if not isinstance(stages, list) or len(stages) != 3:
                fail(f"expected three localized warning stages for {language}")
            for stage in stages:
                if any(not isinstance(stage.get(field), str) or not stage[field].strip() for field in ("Warning", "Phrase")):
                    fail(f"missing localized warning/phrase for {language}")
                if language == "he" and any(not any(0x0590 <= ord(c) <= 0x05FF for c in stage[field]) for field in ("Warning", "Phrase")):
                    fail("Hebrew warnings and phrases must contain Hebrew text")

        installers = [n for n in names if re.fullmatch(r"Install-RmmAppControl\.v[^/]+\.ps1", n)]
        reverts = [n for n in names if re.fullmatch(r"Revert-RemoteAccessBlock-WinOnly\.v[^/]+\.ps1", n)]
        if len(installers) != 1:
            fail(f"expected one installer script, found {len(installers)}")
        if len(reverts) != 1:
            fail(f"expected one Windows-only emergency revert script, found {len(reverts)}")
        if any("kits/" in n or n.startswith("Block-The-") or "Remote-Tools-Block-Windows" in n for n in names):
            fail("full-GUI kit files leaked into the script-only package")
        if "policy/summary.txt" in names:
            fail("stale upstream summary.txt would describe the wrong default variant")
        version = zf.read("VERSION").decode("ascii").strip()
        expected_name = f"remote-access-tool-blocker-script-only-{version}-preview.zip"
        if archive.name != expected_name:
            fail(f"archive name does not match embedded VERSION: expected {expected_name}")
        preview_notice = zf.read("PREVIEW-NOT-A-RELEASE.txt").decode("ascii")
        if "NOT A RELEASE" not in preview_notice or "not been validated on a live Windows endpoint" not in preview_notice:
            fail("in-archive preview warning is missing or incomplete")
        source_commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=source_root, check=True, capture_output=True, text=True).stdout.strip()
        packaged_commit = zf.read("SOURCE-COMMIT.txt").decode("ascii").strip()
        if packaged_commit != source_commit:
            fail(f"package source commit {packaged_commit} does not match checkout {source_commit}")
        worktree = subprocess.run(["git", "status", "--porcelain", "--untracked-files=all"], cwd=source_root, check=True, capture_output=True, text=True).stdout
        if worktree.strip():
            fail("source checkout is dirty; refuse to attest a commit-only preview package")

        expected_variants = {
            f"policy/variants/RmmBlock-{mode}-T{t}A{a}S{s}R{r}.{ext}"
            for mode in ("Enforce", "Audit")
            for t in (0, 1)
            for a in (0, 1)
            for s in (0, 1)
            for r in (0, 1)
            for ext in ("cip", "xml")
        }
        if not expected_variants.issubset(set(names)):
            fail("one or more of the 32 policy variants is missing")

        enforce_xml = zf.read("policy/variants/RmmBlock-Enforce-T1A1S1R1.xml").decode("utf-8-sig")
        if "Enforce [T1A1S1R1]" not in enforce_xml:
            fail("the all-blocked policy XML does not identify variant T1A1S1R1")
        for mode in ("Enforce", "Audit"):
            for extension in ("cip", "xml"):
                baseline = f"policy/RmmBlock-{mode}.{extension}"
                variant = f"policy/variants/RmmBlock-{mode}-T1A1S1R1.{extension}"
                if zf.read(baseline) != zf.read(variant):
                    fail(f"script-only baseline is not all-blocked: {baseline}")
        signer_rows = csv.DictReader(io.StringIO(zf.read("policy/signers.csv").decode("utf-8-sig")))
        signer_tiers = {row.get("Tier") for row in signer_rows}
        missing_tiers = sorted({f"toggle-{key}" for key in "TASR"} - signer_tiers)
        if missing_tiers:
            fail(f"all-blocked policy is missing switchable signer tiers: {missing_tiers}")
        module = zf.read("RemoteAccessProtection.psm1")
        entry = zf.read("Invoke-RemoteAccessProtection.ps1")
        for member, data in (("RemoteAccessProtection.psm1", module), ("Invoke-RemoteAccessProtection.ps1", entry)):
            if b"New-Object Windows.Forms.Form" in data or b"ShowDialog" in data:
                fail(f"full GUI dependency found in {member}")
        if b"T1A1S1R1" not in module or b"CommonDesktopDirectory" not in module or b"Allow Remote Access" not in module:
            fail("all-blocked default or shared desktop toggle contract is missing")
        for marker in (
            b"Set-RemoteAccessProtection -State Blocked",
            b"Invoke-RemoteAccessProtectionInstaller -Mode Enforce",
            b"Invoke-RemoteAccessProtectionAllow",
            b"New-RemoteAccessProtectionShortcut -InstallRoot $InstallRoot",
            b"Set-RemoteAccessProtectionPolicyDefaults -SourcePolicyDir $source.PolicyDir -TargetPolicyDir $targetPolicy",
            b"Enable-RemoteAccessProtection",
            b"Is64BitOperatingSystem",
        ):
            if marker not in module:
                fail(f"required install/toggle behavior missing: {marker.decode('ascii')}")
        if b"Sysnative" not in entry:
            fail("controller does not protect 64-bit App Control paths from WOW64 redirection")
        if b"[string]$InstallRoot" in entry:
            fail("controller accepts a caller-controlled install root across UAC")
        for marker in (
            b"Toggle is available only from the protected Program Files controller",
            b"will not self-elevate from a user-writable path",
        ):
            if marker not in entry:
                fail(f"controller elevation boundary missing: {marker.decode('ascii')}")
        if b"Enable' { Enable-RemoteAccessProtection }" not in entry:
            fail("controller references an unexported or missing enable command")
        if b"Action = 'Install'" not in entry:
            fail("controller does not default to Install")

        mappings = {
            "Invoke-RemoteAccessProtection.ps1": "integration/Invoke-RemoteAccessProtection.ps1",
            "RemoteAccessProtection.psm1": "integration/RemoteAccessProtection.psm1",
            "RemoteAccessSafety.psm1": "integration/RemoteAccessSafety.psm1",
            "RemoteAccessSafety.i18n.json": "integration/RemoteAccessSafety.i18n.json",
            "Start-Here.ps1": "integration/Start-Here.ps1",
            "START-HERE.bat": "integration/START-HERE.bat",
            "Allow Remote Access.bat": "integration/Allow Remote Access.bat",
            "Run-Revert.bat": "revert/Run-Revert.bat",
            "HANDOFF-FOR-IMPLEMENTING-AGENT.md": "docs/script-integration-handoff.md",
            "PREVIEW-NOT-A-RELEASE.txt": "integration/PREVIEW-NOT-A-RELEASE.txt",
            "SOURCE-COMMIT.txt": None,
            "VERSION": "VERSION",
            "LICENSE": "LICENSE",
            "NOTICE": "NOTICE",
            "README.md": "README.md",
        }
        for name in installers:
            mappings[name] = f"src/appcontrol/{name}"
        for name in reverts:
            mappings[name] = f"revert/{name}"
        for name in names:
            if name.startswith("policy/"):
                mappings[name] = name
        for mode in ("Enforce", "Audit"):
            for extension in ("cip", "xml"):
                member = f"policy/RmmBlock-{mode}.{extension}"
                mappings[member] = f"policy/variants/RmmBlock-{mode}-T1A1S1R1.{extension}"
        if set(mappings) != set(names):
            fail(f"unexpected or unmapped members: {sorted(set(names) - set(mappings))}")

        for member, source_rel in mappings.items():
            if source_rel is None:
                continue
            source = source_root / source_rel
            if not source.is_file():
                fail(f"source member missing: {source_rel}")
            if zf.read(member) != source.read_bytes():
                fail(f"package bytes differ from source: {member} != {source_rel}")

        for name in names:
            if name.endswith((".ps1", ".psm1", ".bat")):
                data = zf.read(name)
                if data.startswith(b"\xef\xbb\xbf") or any(byte > 127 for byte in data):
                    fail(f"non-ASCII or BOM in {name}")
                if name.endswith(".bat") and data.count(b"\n") != data.count(b"\r\n"):
                    fail(f"batch file is not CRLF-only: {name}")

    sidecar = archive.with_name(archive.name + ".sha256")
    if not sidecar.is_file():
        fail(f"checksum sidecar not found: {sidecar}")
    parts = sidecar.read_text(encoding="ascii").strip().split()
    if len(parts) != 2 or parts[1] != archive.name:
        fail("checksum sidecar must name this archive with a relative filename")
    actual_hash = hashlib.sha256(archive.read_bytes()).hexdigest()
    if parts[0].lower() != actual_hash:
        fail("checksum sidecar digest does not match archive")

    print(f"PASS: {archive.name} ({len(names)} members; exact source parity; all-blocked variant and no-GUI contracts verified)")
    print(f"SHA256: {actual_hash}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
