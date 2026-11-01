# Windows App Control remote-access blocker

Applies Windows App Control (WDAC) deny rules to selected remote-access tools. Coverage is limited to the signers and file-name rules in this repository; unknown or unsigned tools may not be covered. This is not universal coverage.

Blocking a support tool can sever remote access. Have a local recovery route and test on a disposable Windows machine before deployment.

## Primary integration: no-GUI desktop toggle

For embedding in another Windows PowerShell script, see [`docs/script-integration-handoff.md`](docs/script-integration-handoff.md). The integration path installs the Enforce policy using **T1A1S1R1** (TeamViewer, AnyDesk, Splashtop, and RustDesk blocked), then adds a shared-desktop **Remote access protection** toggle. Disabling requires UAC approval and typing `UNBLOCK`; enabling reinstalls the policy. It removes only this project's fixed policy ID. No full GUI, scheduled task, service, or automatic unblock is involved.

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
