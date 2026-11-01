# Changelog

Notable project changes. Historical dates refer to the versioning dates carried in script filenames.

## 0.1.2-preview.1 — Direct blocking and native warning popups

- Remove the typed BLOCK confirmation and keyboard pauses from the one-click blocking/setup path. Windows administrator consent remains required when needed.
- Keep the existing anti-scam warning text, but replace console typing with three native Windows Yes/No/Cancel popups. No is the default; only three explicit Yes choices approve removal.
- Remove keyboard pauses from the installed controller and compatibility recovery launcher. Do not fall back to console consent when native UI is unavailable.
- Test the real native popups on Windows: refusals at each stage, Cancel, window close, three Yes approvals, default No, and captured screenshots. Exercise packaged blocking with stdin closed and an inert controller, never a real policy install.
- Earlier policy-state/recovery/ACL findings and live enforcement/UAC/reboot acceptance remain pending.

## 0.1.1-preview.1 — Start Here and anti-scam safeguards

- Add `START-HERE.bat` for interactive setup and `Allow Remote Access.bat` for the installed control.
- Replace the ambiguous desktop toggle with **Allow Remote Access** and **Block Remote Access** shortcuts.
- Require three exact phrases before policy removal, with repeated red scam warnings, independent callback instructions, and cancellation on any invalid/missing input.
- Apply the same consent gate to the low-level removal engine and emergency recovery. Copy the required safety module with installed recovery files; label its launcher **Allow Remote Access**.
- Add confirmation/routing/removal-boundary tests and a native Windows packaged-launcher cancellation check. Earlier policy-state/recovery/ACL findings remain open; this is still a testing prerelease.

## 0.1.0-preview.1 — Windows App Control only (testing prerelease)

- Replace the unpublished calendar-version preview label with semantic version 0.1.0, published only as prerelease `v0.1.0-preview.1`.
- Include the operator README in the script-only ZIP, with download links, installation steps, and explicit known limitations.

- Remove the website-list and HIPS generators, website GUI, antivirus-specific recovery scripts, experimental archive, and their tests and import guides.
- Build only Windows App Control packages; recovery selects only the Windows-only variant.
- Add repository-scope and scratch-only recovery-copy regressions for both source and flat package layouts.

### Documentation

- Remove ESET-specific instructions, features, and combined-kit descriptions from the operator documentation.
- Document the no-GUI **T1A1S1R1** desktop-toggle integration as the primary path and retain the optional `kits/windows-only/` GUI kit with its **T1A1S0R1** fresh-install default.
- Clarify limited signer coverage, Windows-only recovery, and that live policy, UAC, and reboot acceptance checks remain pending.
- Preserve LOLRMM, RustDesk, and Microsoft attribution in `NOTICE`.

## 2026.10.11 — Windows App Control baseline

- Add a Windows App Control policy based on Microsoft's `AllowAll.xml` example template, with selected signer deny rules and a fixed policy ID.
- Add Audit, Enforce, Remove, and Status operations and policy-variant toggles for TeamViewer, AnyDesk, Splashtop, and RustDesk.
- Add the Windows-only GUI kit and a local emergency revert/restore tool.
- Keep the signer catalogue hand-selected; optional dual-use signers are excluded by default.

The repository's test notes and acceptance status are in [`testing.md`](testing.md). This changelog does not assert that current live Windows policy, UAC, desktop-toggle, or reboot acceptance has been completed.
