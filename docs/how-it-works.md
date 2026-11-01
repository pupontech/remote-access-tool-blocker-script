# How it works

This project applies Windows App Control (WDAC) deny rules for selected remote-access tools. The primary integration path is the no-GUI **T1A1S1R1** desktop toggle; the optional Windows-only GUI kit uses **T1A1S0R1** on a fresh install.

## Policy source and rules

The policy is based on Microsoft's `%windir%\\schemas\\CodeIntegrity\\ExamplePolicies\\AllowAll.xml` template, with user-mode code integrity enabled and script enforcement disabled. Deny rules target selected code-signing certificates in the user-mode signing scenario; kernel-mode and driver signing are outside scope.

The signer catalogue is hand-selected from LOLRMM data. Each applicable vendor certificate can produce a leaf rule for its certificate and a publisher rule for the issuing CA plus publisher name. The latter can continue to match after certificate renewal under the same CA. The RustDesk certificate is separately embedded from the vendor's official Windows build; it is not sourced from LOLRMM. A file-name rule also covers RustDesk custom-client builds.

The policy has the fixed ID `{2D13BFB7-4304-4847-9CDD-37820D3EE9B7}`. Reusing that ID replaces this project's policy; it does not authorize removing or replacing unrelated App Control policies. Do not change the ID without a migration that removes the old policy.

## Deployment paths and toggle variants

### Primary: no-GUI integration (`T1A1S1R1`)

The script integration installs the Enforce policy with TeamViewer, AnyDesk, Splashtop and RustDesk all blocked. It creates separate **Allow Remote Access** and **Block Remote Access** desktop controls before enforcing the policy. Allowing requires administrator approval and three native Windows anti-scam dialogs with an English/Hebrew selector. Only the first dialog asks you to type, and only one sentence: the exact sentence shown, in the selected language. Yes stays disabled until it matches and is revalidated on click; switching language clears the entry, locks Yes again and gives the dialog the right-to-left Hebrew reading direction without rebuilding the window. The second and third dialogs ask for nothing — they are plain Yes/No/Cancel confirmations, and the language choice carries forward. No remains the default button. Blocking reinstalls the policy directly, without typing or keyboard pauses. `START-HERE.bat` is the double-click setup entry point; the raw controller remains available for elevated integrations. This path has no full GUI, service, scheduled task, or automatic unblock. See [the integration handoff](script-integration-handoff.md).

### Optional: Windows-only GUI kit (`T1A1S0R1`)

The Windows-only kit at `kits/windows-only/` retains the GUI and defaults to TeamViewer, AnyDesk and RustDesk blocked, with Splashtop allowed. The four switches correspond to TeamViewer (T), AnyDesk (A), Splashtop (S), and RustDesk (R). Its defaults differ intentionally from the primary integration path. The policy variants encode toggle choices in the policy friendly name.

The checked-in policies include only selected signers. Optional dual-use publishers are excluded to reduce the chance of blocking legitimate software. Unknown, unsigned, uncatalogued, or certificate-less tools may not be covered; this is not universal coverage.

## Applying and removing policy

The installer supports Enforce, Audit, Remove, and Status operations. Audit mode records what would be blocked without enforcing the deny rules. App Control blocks new process starts; it does not stop an already-running application.

On supported Windows builds, `CiTool.exe` can apply or remove the policy immediately. Systems without the required `CiTool.exe` path may need a restart for changes to take effect. The Windows-only emergency revert is intended for local recovery; follow its included instructions. Do not rely on a successful command alone as evidence that the live policy state changed.

## Data and attribution

The signer inventory and policy rules are derived in part from the LOLRMM catalogue (Apache-2.0). The RustDesk signing certificate has separate provenance. Microsoft provides the example policy template and documents the block-rule layout. See [NOTICE](../NOTICE) for attribution and trademark details.
