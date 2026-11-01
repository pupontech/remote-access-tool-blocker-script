# Script-only handoff: Windows App Control integration

## Goal and boundaries

This is the primary no-GUI integration path for another Windows PowerShell script. `Install-RemoteAccessProtection` installs this project's App Control deny policy in Enforce mode with **T1A1S1R1** (TeamViewer, AnyDesk, Splashtop, and RustDesk blocked), creates shared-desktop **Allow Remote Access** and **Block Remote Access** controls before enforcement. There is no full WinForms window, service, scheduled task, or background auto-unblock.

Coverage is limited to the repository's signer and file-name rules. Unknown, unsigned, uncatalogued, or certificate-less tools may not be covered; do not claim universal coverage. Optional dual-use signers are excluded because they may sign legitimate software. See `policy/skipped-signers.csv` and `docs/how-it-works.md`.

App Control blocks **new process starts**, not applications already running. Blocking a support product can sever the administrator's remote session. Confirm a local recovery route before deployment. Some Windows versions require a restart after policy transitions.

This is an App Control block, not a software-removal feature. If the host is a ScreenConnect cleanup workflow, retain its existing removal boundary: remove ScreenConnect instances only and leave other remote-access products detect/report-only.

## Integration instructions

1. Keep the module, controller, policy engine, policy payload, attribution, and Windows-only emergency revert together. The preview bundle is `remote-access-tool-blocker-script-only-<VERSION>-preview.zip`; it is not a release. Build from a clean committed tree.
2. Integrate during the host script's elevated setup stage. Use **64-bit Windows PowerShell** on 64-bit Windows; direct module calls reject a 32-bit process because WOW64 can redirect App Control paths. The installed desktop controller uses Sysnative when needed. The raw controller does not self-elevate from a user-writable path. The explicitly launched `START-HERE.bat` setup wrapper displays a blocking warning, requires `BLOCK`, then requests administrator approval once.

   ```powershell
   Import-Module (Join-Path $PSScriptRoot 'integration\RemoteAccessProtection.psm1') -Force
   Install-RemoteAccessProtection
   ```

   For the flat integration ZIP, import `RemoteAccessProtection.psm1` from its package root. Installation copies the policy payload and support scripts under Program Files, creates the shared-desktop shortcut, enforces the policy, and verifies the resulting state. The shortcut is created first so failure does not leave an applied policy without its toggle.
3. Keep the desired variant explicit: pass `-Variant T1A1S1R1`. Do not copy the GUI defaults. Preserve the fixed policy ID `{2D13BFB7-4304-4847-9CDD-37820D3EE9B7}` so this deployment replaces only this project's policy.
4. Preserve distinct actions: **Allow Remote Access** launches the installed controller with `-Action Allow`; **Block Remote Access** uses `-Action Enable`. The removal engine and emergency recovery require `RemoteAccessSafety.psm1` and three exact phrases: `I VERIFIED THE PERSON`, `I UNDERSTAND THE RISK`, then `ALLOW REMOTE ACCESS`. Red warnings instruct users never to trust strangers/unexpected callers, to hang up and independently find and manually dial an official number, and never to share passwords/codes or bank while connected. Cancel/blank/incorrect/input-error answers refuse the change. Do not add auto-confirm flags or scheduled unblocking. Legacy Toggle uses the same guarded removal path.
5. Do not remove or overwrite unrelated App Control policies. Preserve the bundled Windows-only emergency revert as a local break-glass route.
6. Keep deployment synchronous. The host script must wait for installation, check its result, and fail setup if policy verification or shortcut creation fails. Do not report success merely because a child process launched.
7. Surface restart requirements on systems without the applicable `CiTool.exe` support. Do not claim a transition completed before the required restart. `Unknown` status must fail closed: show an error and make no state change.
8. Keep the scope limits visible: Windows App Control, new process starts only, possible remote-session loss, and limited signer coverage. Do not silently switch the requested Enforce default to Audit.

## Standalone commands

Run from an elevated PowerShell session in the extracted package:

```powershell
.\Invoke-RemoteAccessProtection.ps1 -Action Install  # default; all listed tools blocked, adds desktop toggle
.\Invoke-RemoteAccessProtection.ps1 -Action Status
.\Invoke-RemoteAccessProtection.ps1 -Action Enable  # restore all-blocked policy
```

Normal end users double-click `START-HERE.bat` for setup, then use the named desktop controls. `Allow Remote Access.bat` in the ZIP opens the installed controller, not an untrusted extracted copy. Administrator approval is not a substitute for independently verifying the person.

## Verification and acceptance

Portable checks do not change policy state:

```powershell
pwsh -NoProfile -File tests/Test-ScriptIntegration.ps1
pwsh -NoProfile -Command "`$t=`$null;`$e=`$null;[System.Management.Automation.Language.Parser]::ParseFile('integration/RemoteAccessProtection.psm1',[ref]`$t,[ref]`$e)|Out-Null;if(`$e.Count){`$e;exit 1}"
```

Build and verify from Git Bash (or Bash on Linux):

```bash
./build/build-script-integration.sh
python3 tests/verify-script-integration-package.py "dist/remote-access-tool-blocker-script-only-$(tr -d '\r\n' < VERSION)-preview.zip" --source-root .
```

Live acceptance remains pending on a disposable Windows 10/11 test PC (not a production support endpoint): install from elevated PowerShell; confirm the enforced policy and shared-desktop toggle; verify representative tool launches are blocked; test refusal at each of the three anti-scam confirmations; verify that only this project's policy is removed and can be restored; confirm any required restart transition. Capture CodeIntegrity evidence such as event 3077 for enforced blocks. Do not treat a portable test, package verifier, or CI run as proof of live policy behavior. The repository's existing safety verification gaps are outside this documentation handoff and are not represented as fixed here.
