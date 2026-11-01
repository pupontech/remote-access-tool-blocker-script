# Script-only handoff: remote-access protection

## Goal and boundaries

This package is the no-GUI integration path for another Windows PowerShell script. Calling `Install-RemoteAccessProtection` installs the project's App Control deny policy in **Enforce** mode with the all-blocked variant `T1A1S1R1`, then creates a shared-desktop shortcut named **Remote access protection**. TeamViewer, AnyDesk, Splashtop and RustDesk are all set to blocked; the policy's other listed remote-access signers remain blocked too. There is no full WinForms window, no service, no scheduled task and no background auto-unblock.

"Everything" means the remote-access tools represented by this repository's signer/file-name rules, not every remote-control program that could ever exist. Unsigned or uncatalogued tools and entries with no usable signing data may not be covered. The inherited policy also deliberately leaves out the optional dual-use signer tier (for example, some GoTo, Zoho, NetSupport and Veyon products) because those publishers also sign legitimate software; see `policy/skipped-signers.csv` and `docs/how-it-works.md`. Do not claim universal coverage. The policy is derived from the LOLRMM catalogue and the checked-in `policy/signers.csv`; the optional ESET website list is not installed or controlled by this script-only component.

The policy blocks **new process starts**, not already-running applications. Blocking a support product can sever the administrator's remote session. Confirm a local recovery route before deployment. On Windows versions where `CiTool.exe` is unavailable, enabling/removing the policy file requires a restart.

This is an App Control block, not a software-removal feature. If the host is a ScreenConnect cleanup workflow, keep its existing removal boundary: remove ScreenConnect instances only and leave other remote-access products detect/report-only; this component must not turn them into uninstall candidates.

## Handoff instructions for the implementation agent

1. Keep the integration component and its policy payload together. The preview bundle is `remote-access-tool-blocker-script-only-<VERSION>-preview.zip`; do not copy only the controller `.ps1`. It includes the policy variants, policy engine, Windows-only emergency revert, attribution, this handoff, a `PREVIEW-NOT-A-RELEASE.txt` warning, and the exact source SHA in `SOURCE-COMMIT.txt`. Build it only from a clean committed tree.
2. Integrate at the host script's elevated setup/install stage, after the host has its required administrator context. Use **64-bit Windows PowerShell** on 64-bit Windows; direct module calls refuse a 32-bit process because WOW64 can redirect App Control system paths. The installed desktop controller uses `Sysnative` to reach 64-bit Windows PowerShell when needed. The extracted installer deliberately does not self-elevate from a user-writable path. For a source checkout, import the module from `integration`; for the flat integration ZIP, use the module at the package root:

   ```powershell
   Import-Module (Join-Path $PSScriptRoot 'integration\RemoteAccessProtection.psm1') -Force
   Install-RemoteAccessProtection
   ```

   If the package is extracted beside the host script, change the module path to `RemoteAccessProtection.psm1`. `Install-RemoteAccessProtection` copies the complete policy payload and support scripts under Program Files, creates the shared-desktop shortcut, enforces the all-blocked variant, and verifies the result. The shortcut is created first so an installation failure cannot leave a successfully installed policy without its on/off control.
3. Do not add the full WinForms GUI or hand-copy its checkbox defaults. The desired default is explicit: all four switchable tools are blocked (`T1A1S1R1`) and the base rules block the remaining catalogued tools. Installation rewrites the protected Program Files Enforce/Audit defaults from `T1A1S1R1`, so an omitted `-Variant` cannot accidentally select the upstream `T1A1S0R1` default; the preview bundle also ships those all-blocked root defaults. Still pass `-Variant T1A1S1R1` explicitly. Keep the exact fixed policy GUID `{2D13BFB7-4304-4847-9CDD-37820D3EE9B7}` so this deployment replaces the project's existing policy rather than stacking another one.
4. Preserve the on/off behavior. The desktop shortcut launches `Invoke-RemoteAccessProtection.ps1 -Action Toggle`, obtains administrator consent, and checks the installed state. If blocking is active, the user must type `UNBLOCK` to remove this project's policy; if it is inactive, clicking the icon reinstalls the all-blocked policy. The shortcut targets the shared Windows desktop so it is visible to all users. Do not schedule a task that removes or weakens the policy.
5. Do not remove or overwrite unrelated Windows App Control policies. Enabling replaces only this project's fixed policy ID; disabling removes only that ID. Preserve the bundled Windows-only emergency revert as a break-glass recovery route for local administrators.
6. Keep deployment synchronous. The host script must wait for installation, check its result, and fail its own setup if the policy cannot be verified or if shortcut creation fails. Do not report success from a spawned process that was merely launched.
7. Surface the restart requirement on systems without `CiTool.exe`. Do not claim a tool was unblocked before the required restart. A status of `Unknown` must fail closed: show an error and make no state change.
8. Keep these scope limits visible to operators: this is Windows App Control, it blocks new starts rather than killing running tools, and it can cut off remote support. Do not silently switch to Audit mode; the requested default is enforcement.

## Standalone commands

Run from an elevated PowerShell session in the extracted package:

```powershell
.\Invoke-RemoteAccessProtection.ps1 -Action Install  # default action; blocks all listed tools and adds the desktop toggle
.\Invoke-RemoteAccessProtection.ps1 -Action Status
.\Invoke-RemoteAccessProtection.ps1 -Action Enable  # restore the all-blocked policy
```

Normal end users use the desktop shortcut, not a second GUI. Clicking it while blocked asks for the exact word `UNBLOCK`; canceling leaves the block active. Clicking while unblocked applies the block. Administrative UAC approval is required for policy changes.

## Verification and acceptance

Portable tests (no policy changes):

```powershell
pwsh -NoProfile -File tests/Test-ScriptIntegration.ps1
pwsh -NoProfile -Command "`$t=`$null;`$e=`$null;[System.Management.Automation.Language.Parser]::ParseFile('integration/RemoteAccessProtection.psm1',[ref]`$t,[ref]`$e)|Out-Null;if(`$e.Count){`$e;exit 1}"
./build/build-script-integration.sh
python3 tests/verify-script-integration-package.py "dist/remote-access-tool-blocker-script-only-$(tr -d '\r\n' < VERSION)-preview.zip"
```

Acceptance on a disposable Windows 10/11 test PC (not a production support endpoint): install from an elevated script; confirm the policy is enforced and the shared-desktop shortcut exists; close any already-running remote tools; confirm new launches of representative AnyDesk, TeamViewer, Splashtop and RustDesk builds are blocked; click the shortcut and cancel once to confirm state remains blocked; click again and type `UNBLOCK` to remove only this project's policy; verify state and, where necessary, restart; click again to restore all four blocks. Keep event IDs 3077 (blocked) or 3076 (audit-only) as evidence. The repository CI is static/synthetic and must not install a WDAC policy on its runner.

## Evidence status

The package's policy variants already exist in the source repository. The controller's policy-state parser is covered by portable synthetic tests; package contents are checked by the build verifier. A passing Linux/CI parse or package test does **not** prove a live Windows policy install, UAC prompt, desktop shortcut, App Control block, or restart transition. The implementation agent must record those separately as Windows acceptance evidence.
