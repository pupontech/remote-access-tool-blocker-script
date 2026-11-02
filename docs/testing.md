# Testing

This guide describes checks for the Windows App Control paths. No live policy, UAC, desktop-toggle, or reboot acceptance result is asserted here. Those checks remain pending on a disposable Windows test machine.

## Portable checks

The repository's portable tests and package checks can validate script parsing, synthetic state handling, and package contents. They cannot establish that Windows installed or enforced a policy. Run the commands documented in [the script integration handoff](script-integration-handoff.md) from the repository root when validating that integration package.

## Windows acceptance checks — pending

Use a disposable Windows 10/11 test PC, not a production support endpoint. Keep a local recovery route available: enforcing a deny rule can cut off remote access, and the policy blocks new process starts rather than terminating running programs.

For the primary no-GUI integration path, acceptance should include:

1. Install from an elevated 64-bit PowerShell host and confirm the resulting policy state and shared-desktop toggle.
2. Confirm the `T1A1S0R1` policy blocks representative TeamViewer, AnyDesk and RustDesk starts and does NOT block Splashtop. Capture the relevant CodeIntegrity event evidence.
3. Confirm the `\RemoteAccessToolBlocker\Restore desktop icons` task exists and runs as SYSTEM at startup, `C:\RemoteAccessToolBlocker` is not writable by a standard user, deleted/changed icons return after a restart, and `Stop Restoring Icons.bat` / `Start Restoring Icons.bat` remove and restore the task.
4. Exercise the toggle's UAC prompt, cancellation behavior, the first dialog's exact English/Hebrew sentence and two further native confirmations, and restoration path. Confirm only this project's fixed policy ID is removed or restored.
5. On a Windows build that requires restart, verify the actual state transition after reboot.

For the optional `kits/windows-only/` GUI kit, verify its fresh-install `T1A1S0R1` defaults separately and exercise its Audit/Enforce/Remove and status controls. Do not infer GUI behavior from parser or synthetic tests.

## Interpreting CodeIntegrity events

Event **3076** indicates a would-be block in Audit mode; **3077** indicates a block in Enforce mode. Find them in:

**Event Viewer → Applications and Services Logs → Microsoft → Windows → CodeIntegrity → Operational**

Events identify the policy by GUID, not friendly name. Search for:

```
2d13bfb7-4304-4847-9cdd-37820d3ee9b7
```

Use those events as evidence only when captured from the target Windows machine during the test. A passing portable test, package verifier, or CI job is not live enforcement evidence.

## Known limits

Unsigned, self-signed, unknown, or uncatalogued tools may not be covered. The optional dual-use signer tier is excluded. Windows edition and build differences can affect policy application; systems without the applicable `CiTool.exe` support may require a restart. Confirm behavior on the actual target configuration before relying on enforcement.
