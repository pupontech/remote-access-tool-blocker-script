# Windows App Control remote-access blocker

Applies Windows App Control (WDAC) deny rules to selected remote-access tools. Coverage is limited to the signers and file-name rules in this repository; unknown or unsigned tools may not be covered. This is not universal coverage.

Blocking a support tool can sever remote access. Have a local recovery route and test on a disposable Windows machine before deployment.

## Download — testing preview, not production-ready

[Download the Windows App Control script ZIP](https://github.com/pupontech/remote-access-tool-blocker-script/releases/download/v0.1.0-preview.1/remote-access-tool-blocker-script-only-0.1.0-preview.zip) · [SHA-256 checksum](https://github.com/pupontech/remote-access-tool-blocker-script/releases/download/v0.1.0-preview.1/remote-access-tool-blocker-script-only-0.1.0-preview.zip.sha256) · [Release notes](https://github.com/pupontech/remote-access-tool-blocker-script/releases/tag/v0.1.0-preview.1)

This is a **Windows PowerShell script package**, not an EXE installer or antivirus. It installs Windows App Control rules to block new starts of covered remote-access software and adds an on/off desktop shortcut. **There is no ESET integration, website filtering, or software removal in this repository.** The download contains the scripts, compiled policy variants, Windows-only emergency recovery, and `HANDOFF-FOR-IMPLEMENTING-AGENT.md` for embedding it into another script. The optional GUI kit in the source tree is not part of this script-only ZIP.

### Run the downloaded package

1. Extract the entire ZIP; keep its scripts and `policy` folder together.
2. On a disposable Windows 10/11 test PC, open **64-bit Windows PowerShell as administrator** in the extracted folder.
3. Run:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-RemoteAccessProtection.ps1 -Action Install
   ```

4. Use **Remote access protection** on the shared desktop afterward. Turning blocking off requires administrator approval and typing `UNBLOCK`. Close already-running remote tools before testing new launches. Restart when instructed.

**Needs testing:** both Windows PowerShell 5.1 and PowerShell 7 CI exercise parsing, synthetic logic, recovery-copy fixtures, and ZIP verification—not live policy enforcement, UAC, or reboot transitions. Known review concerns remain around policy-state/variant verification, staged-versus-active state on older Windows, removal error reporting, exact recovery backups, and installation-folder trust. These are not claimed fixed in this preview. Do not deploy to production or rely on it as your only protection; keep local recovery access.

## Primary integration: no-GUI desktop toggle

For embedding in another Windows PowerShell script, see [`docs/script-integration-handoff.md`](docs/script-integration-handoff.md). The integration path creates the shared-desktop **Remote access protection** toggle before enforcing **T1A1S1R1** (TeamViewer, AnyDesk, Splashtop, and RustDesk blocked). Disabling requires UAC approval and typing `UNBLOCK`; enabling reinstalls the policy. It removes only this project's fixed policy ID. No full GUI, scheduled task, service, or automatic unblock is involved.

Build the standalone preview package from a clean committed checkout:

```bash
./build/build-script-integration.sh
```

The preview ZIP is not a release. Consult the handoff for integration commands, architecture constraints, package verification, and Windows acceptance steps.

## Optional Windows-only GUI kit

The optional Windows GUI kit is `kits/windows-only/`. On a fresh install it uses **T1A1S0R1**: TeamViewer, AnyDesk and RustDesk blocked; Splashtop allowed. This default intentionally differs from the primary integration path. The GUI offers Audit/Test, Enforce/Block, Remove/Undo, and status functions. Use the kit's `START-HERE.bat` on Windows and follow its prompts.

## How the policy works

The policy uses selected signer deny rules in the user-mode App Control scenario, based on Microsoft's example `AllowAll.xml` policy layout. Script enforcement and kernel/driver restrictions are not enabled. App Control blocks new process starts; it does not terminate already-running tools. A fixed policy ID allows this project to replace its own policy without changing unrelated policies.

The signer list is hand-selected from LOLRMM catalogue data. Optional dual-use publishers are excluded because they also sign legitimate software. Rules may not cover unsigned, self-signed, uncatalogued, or certificate-less tools. See [`docs/how-it-works.md`](docs/how-it-works.md) and [`policy/signers.csv`](policy/signers.csv).

## Safety and recovery

Use Audit mode first where practical, then examine CodeIntegrity events on the target PC before enforcing. Event 3076 denotes a would-be block in Audit mode; 3077 denotes an enforced block. These events are not evidence unless observed on the tested Windows machine.

The Windows-only emergency revert is included for local recovery. Depending on Windows build, a policy transition may require a restart. Live policy application, UAC behavior, desktop toggle behavior, and reboot transitions remain acceptance checks; portable tests do not establish them. See [`docs/testing.md`](docs/testing.md).

## Rebuilding

The committed `policy/` payload supports ordinary use without rebuilding. To regenerate policies from current catalogue data, use Windows 10/11 with the required ConfigCI tooling and PowerShell, following the build script's help and repository workflow. Validate the resulting package and test on a disposable Windows system before deployment.

## Credits and license

- **LOLRMM** ([site](https://lolrmm.io), [repository](https://github.com/magicsword-io/LOLRMM), Apache-2.0): source for catalogue-derived signer data.
- **Microsoft**: example policy template and documented block-rule layout.
- **RustDesk**: signing certificate provenance is documented separately in [`NOTICE`](NOTICE).

See [`NOTICE`](NOTICE) for details. This project is provided as-is, without warranty, and is not affiliated with or endorsed by the vendors named. Licensed under Apache License 2.0; see [`LICENSE`](LICENSE).
