# Remote Access Tool Blocker

## For humans

Windows 10/11 PowerShell scripts that block covered **TeamViewer, AnyDesk and RustDesk** launches. **Splashtop is allowed.** No ESET, website filtering or software removal.

**Testing preview, not production-ready.** Unknown or unsigned tools may escape these rules. Keep local access: blocking a support tool can disconnect your remote session.

### Download and use

[Download the script ZIP](https://github.com/pupontech/remote-access-tool-blocker-script/releases/download/v0.1.8-preview.1/remote-access-tool-blocker-script-only-0.1.8-preview.zip) · [Release notes](https://github.com/pupontech/remote-access-tool-blocker-script/releases/tag/v0.1.8-preview.1)

1. Extract the whole ZIP into a new folder.
2. Double-click **START-HERE.bat** and approve Windows administrator access. Rerun setup on each PC when upgrading.
3. Use **Allow Remote Access** on the desktop for verified support. Type `trust` in English or `אמון` in Hebrew, then choose **Trust / אמון** on all three prompts. **Enter approves the second and third dialogs.** No, Cancel or Escape refuses.
4. Use **Block Remote Access** to block again. Close running remote tools before testing new launches; restart when instructed.

### Stop or restart automatic desktop icons

The icons are shared by all users, including new accounts. If restoration was configured successfully, deleted or changed icons return at the next Windows startup.

Open File Explorer and paste this into the address bar:

```text
C:\RemoteAccessToolBlocker\DesktopIcons
```

- **Stop Restoring Icons.bat** removes the scheduled task. Existing icons stay in place.
- **Start Restoring Icons.bat** recreates the task and runs it once to restore the icons.

Approve the administrator prompt. **These files only control icon restoration; they do not block or allow remote access.** If the folder is missing, run **START-HERE.bat** from the current ZIP; if setup reports an icon-restoration warning, that step did not complete successfully.

**Never trust an unexpected support caller.** Hang up and call an independently verified official number. Never share passwords or codes, or bank while connected.

---

## For AI agents

### Scope and required reading

Maintain the **script-only Windows App Control package**, not an EXE application. Read this section, [`docs/script-integration-handoff.md`](https://github.com/pupontech/remote-access-tool-blocker-script/blob/main/docs/script-integration-handoff.md), [`docs/testing.md`](https://github.com/pupontech/remote-access-tool-blocker-script/blob/main/docs/testing.md) and [`docs/CHANGELOG.md`](https://github.com/pupontech/remote-access-tool-blocker-script/blob/main/docs/CHANGELOG.md) before changes. Read the relevant source; documentation is not proof of runtime behavior.

- Keep ESET integration, website filtering, software removal, services and automatic unblocking out of this project.
- Keep the human section short. Put implementation details, verification commands and maintenance instructions here or in linked docs.
- Preserve unrelated working-tree changes. Check the branch, remotes and current published release before editing; use an isolated worktree when needed. Do not push to the older `remote-access-tool-blocker` repository by mistake.

### Code map

| Path | Responsibility |
|---|---|
| `integration/START-HERE.bat`, `Start-Here.ps1` | One-click setup and elevation |
| `integration/Invoke-RemoteAccessProtection.ps1` | Installed controller and action routing |
| `integration/RemoteAccessProtection.psm1` | Installation, state, desktop controls and icon restore task |
| `integration/RemoteAccessSafety.psm1`, `RemoteAccessSafety.i18n.json` | Native English/Hebrew consent dialogs and translations |
| `src/appcontrol/Install-RmmAppControl.v*.ps1` | Policy application/removal and recovery installation |
| `policy/variants/` | Compiled policies and matching XML |
| `revert/` | Windows-only local recovery |
| `tests/`, `.github/workflows/powershell-ci.yml` | Portable and Windows verification |
| `build/build-script-integration.sh` | Script-only ZIP builder and package verification |

The optional source kit under `kits/windows-only/` is not the script-only download. Do not substitute its GUI package for the requested ZIP.

### Preserve these contracts

1. **Policy identity:** retain `{2D13BFB7-4304-4847-9CDD-37820D3EE9B7}`. Change only this project's policy, never unrelated policies. Default variant is **T1A1S0R1**: covered TeamViewer, AnyDesk and RustDesk blocked; Splashtop allowed. App Control blocks new starts, not already-running processes. Do not claim universal signer coverage.
2. **Setup and consent:** blocking needs no typed confirmation. Allow requires administrator approval, the exact word `trust` / `אמון` on dialog 1, then two further native confirmations. The Trust / אמון approval button is centered and default, but disabled on dialog 1 until the word matches. No, Cancel, Escape, close or UI failure refuses. Never add consent-bypass flags or unattended removal.
3. **Languages:** preserve English/Hebrew switching, clear the word and disable Trust when switching, and carry the selected language through the dialogs. Keep the modal form and selector direction fixed. Defer rendering with `BeginInvoke`; apply RTL to text controls, not runtime form/selector direction changes. The latter caused Windows PowerShell 5.1 hard exits.
4. **Desktop restoration:** the only scheduled task is `\RemoteAccessToolBlocker\Restore desktop icons`, SYSTEM SID `S-1-5-18`, **AtStartup only**. Its action copies only the two named shortcuts with `cmd.exe`; it must never change policy. Lock and read back recovery-folder permissions, check shared-desktop safety before registration, and preserve the Stop/Start helpers. Icon-restore failure warns while blocking setup continues.
5. **Compatibility:** support Windows PowerShell 5.1 and 64-bit Windows paths. Keep `.ps1`/`.psm1` ASCII and `.bat` ASCII/CRLF. Keep translated text in the UTF-8 JSON catalog. Preserve attribution and license files.

Required first-dialog words, matched exactly in the selected language:

- English: `trust`
- Hebrew: `אמון`

### Verify before shipping

From the repository root, run the portable scope and integration checks:

```bash
python3 tests/test_windows_only_repository.py
pwsh -NoProfile -File tests/Test-ScriptIntegration.ps1
pwsh -NoProfile -File tests/Test-WindowsOnlyRecovery.ps1
pwsh -NoProfile -File tests/Test-RemoteAccessSafety.ps1
pwsh -NoProfile -File tests/Test-AllowRemoteAccessRouting.ps1
pwsh -NoProfile -File tests/Test-AllowCancellation.ps1
pwsh -NoProfile -File tests/Test-RemovalConsentBoundary.ps1
pwsh -NoProfile -File tests/Test-OneClickLaunchers.ps1
pwsh -NoProfile -File tests/Test-AdministratorShortcut.ps1
```

Require the Windows workflow to pass under **Windows PowerShell 5.1 and PowerShell 7** on the exact source commit. It also runs the desktop-icon test, native popup proof, packaged launcher test, encoding/parser audit and policy/package inventory. A Linux skip is not Windows proof. CI does not install a live App Control policy.

Build from a clean committed checkout:

```bash
bash build/build-script-integration.sh
python3 tests/verify-script-integration-package.py "dist/remote-access-tool-blocker-script-only-$(tr -d '\r\n' < VERSION)-preview.zip" --source-root .
```

For a release, update `VERSION`, changelog and download links together. Publish a new testing prerelease with the script-only ZIP and relative-filename checksum sidecar; do not overwrite published tags or assets. Prefer the exact-source workflow-dispatch artifact: a PR artifact can be stamped with GitHub's synthetic merge commit. Check `SOURCE-COMMIT.txt`, package members and source parity, then download the published asset back and compare its bytes and checksum. Keep the short operator README inside the ZIP. A later README edit does not change an already-published ZIP.

### Evidence limits and open concerns

Windows CI covers synthetic policy/consent routing, recovery-copy fixtures, real shortcut bytes, the icon-copy command, native English/Hebrew dialogs and packaged launchers with an inert controller. Do not present those as proof of live enforcement or complete installation security.

Owner testing on a spare PC must still cover actual tool blocking/Splashtop allowance, UAC, SYSTEM task registration, standard-user permissions, new-user shortcuts, restart restoration, Stop/Start helpers and policy removal/reboot transitions. Capture actual CodeIntegrity events where applicable: 3076 for Audit and 3077 for Enforce.

Known concerns remain around policy-state/variant verification, staged-versus-active reporting on older Windows, removal error reporting, exact recovery backups and Program Files installation-folder trust. Reproduce each before claiming a fix; recovery-folder permission checks do not resolve them all. Keep local recovery access and preserve the testing-preview warning.

### Attribution

LOLRMM supplies catalogue-derived signer data ([repository](https://github.com/magicsword-io/LOLRMM), Apache-2.0). Microsoft supplies the example policy layout. RustDesk certificate provenance is recorded in [`NOTICE`](https://github.com/pupontech/remote-access-tool-blocker-script/blob/main/NOTICE). Retain [`LICENSE`](https://github.com/pupontech/remote-access-tool-blocker-script/blob/main/LICENSE) and NOTICE in every package. This project is provided as-is and is not endorsed by the named vendors.
