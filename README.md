# Windows App Control remote-access blocker

Applies Windows App Control (WDAC) deny rules to selected remote-access tools. Coverage is limited to the signers and file-name rules in this repository; unknown or unsigned tools may not be covered. This is not universal coverage.

Blocking a support tool can sever remote access. Have a local recovery route and test on a disposable Windows machine before deployment.

## Download — testing preview, not production-ready

[Download the Windows App Control script ZIP](https://github.com/pupontech/remote-access-tool-blocker-script/releases/download/v0.1.7-preview.1/remote-access-tool-blocker-script-only-0.1.7-preview.zip) · [SHA-256 checksum](https://github.com/pupontech/remote-access-tool-blocker-script/releases/download/v0.1.7-preview.1/remote-access-tool-blocker-script-only-0.1.7-preview.zip.sha256) · [Release notes](https://github.com/pupontech/remote-access-tool-blocker-script/releases/tag/v0.1.7-preview.1)

This is a **Windows PowerShell script package**, not an EXE installer or antivirus. It installs Windows App Control rules to block new starts of covered remote-access software and adds separate **Allow Remote Access** and **Block Remote Access** desktop shortcuts. **There is no ESET integration, website filtering, or software removal in this repository.** The download contains the scripts, compiled policy variants, Windows-only emergency recovery, and `HANDOFF-FOR-IMPLEMENTING-AGENT.md` for embedding it into another script. The optional GUI kit in the source tree is not part of this script-only ZIP.

### What changed in 0.1.7-preview.1

- **Splashtop is allowed.** The script now selects **T1A1S0R1**, blocking covered TeamViewer, AnyDesk and RustDesk starts.
- **Desktop icons return at startup.** Setup saves the two shortcuts and configures a SYSTEM startup task to copy only those shortcuts back. It does not re-enable or remove the policy.
- **Centered confirmation buttons, Yes default.** The first Allow dialog still requires the exact sentence; Enter approves dialogs 2 and 3. No, Cancel, Escape and closing the dialog still refuse.
- **Recovery-folder permissions are checked.** Setup locks the recovery/icon source folder to Administrators and SYSTEM, with Users read/execute, and checks the shared desktop before registering the restore task. This does not resolve the separate Program Files installation-folder review item.

**Upgrading from an earlier preview:** extract into a new folder and rerun **START-HERE.bat on every PC already set up**. Downloading this ZIP alone does not update installed scripts, shortcuts or policies. Restart when instructed. Keep local access throughout; setup can interrupt an existing remote-support connection.

### Run the downloaded package

1. Extract the entire ZIP; keep its scripts and `policy` folder together.
2. On a disposable Windows 10/11 test PC, double-click **START-HERE.bat**. It applies blocking directly after any required Windows administrator approval. No typing or extra confirmation is needed.
3. After setup, **Allow Remote Access** removes this project's blocking only after administrator approval, one typed sentence, and two further native Windows confirmations. The ZIP also includes `Allow Remote Access.bat`, which opens the installed control; run setup first.
4. Use the desktop **Block Remote Access** shortcut to restore blocking. Close already-running remote tools before testing new launches. Restart when instructed.
5. Both icons are on the shared desktop, so every account sees them, including new ones. When the restore task is installed successfully, a deleted or changed icon comes back at the next startup—not immediately. Setup prints a red warning if automatic restoration cannot be configured; blocking setup still continues. To stop restoring icons, run `C:\RemoteAccessToolBlocker\DesktopIcons\Stop Restoring Icons.bat`; `Start Restoring Icons.bat` turns it back on. These helpers require administrator approval and do not change whether tools are blocked.

### STOP: never give a stranger remote access

Remote access can let someone see your screen, steal files and passwords, or take money. **An unexpected caller claiming to be Microsoft, your bank, a government office, or technical support is not proof of identity. Caller ID can be faked.** Hang up. Independently find the organisation's official number on a trusted website, your bill, or the back of your card, and dial it yourself. Do not use a number or link the caller supplies, or a search advertisement. Never share passwords or one-time codes, and do not use banking while someone is connected.

Allowing access displays three native Windows warning dialogs with an **English / עברית** selector. The warning text, buttons and required sentence change together, and switching language keeps the window alive instead of rebuilding it. Your language choice carries through all three dialogs.

**Only the first dialog asks you to type, and only one sentence.** Type it exactly, in the language currently shown, and Yes unlocks:

| Language | Sentence to type |
|---|---|
| English | `I checked this person myself and I trust them` |
| עברית | `בדקתי את האדם הזה בעצמי ואני סומך עליו` |

Switching language on that dialog clears the box and locks Yes again, so a sentence typed in one language never unlocks the other. Matching is case-sensitive and extra spaces do not count.

The second and third dialogs ask **nothing** to be typed — they are plain **Yes / No / Cancel** confirmations (Hebrew: **כן / לא / ביטול**). **Yes** is the default button and the buttons are centered. On the first dialog Yes stays disabled until the sentence matches, so Enter does nothing before that; on the second and third dialogs Enter means Yes. Escape always cancels. **Blocking still requires no typing at all.**

Choosing No, Cancel, or closing a popup leaves the policy unchanged. These prompts ask **you** to verify the person; the tool cannot verify their identity. Removing this block does not itself start a support session or make a caller trustworthy.

## Verification and remaining endpoint checks

The release CI runs under **Windows PowerShell 5.1 and PowerShell 7**. It covers parsing/encoding, synthetic policy and consent routing, recovery-copy fixtures, real Windows shortcut bytes, the exact icon-copy command, native English/Hebrew dialogs, packaged launchers with an inert controller, and ZIP/source verification. It **never installs an App Control policy on the runner**.

Before relying on this preview, test these on a spare Windows PC with local recovery access:

- Run setup and confirm Splashtop works while covered TeamViewer, AnyDesk and RustDesk new launches are blocked; restart if requested.
- Confirm both shared-desktop shortcuts work and appear for a new user.
- Delete/change an icon, restart and verify restoration; test the Stop/Start helpers. Confirm the recovery folder cannot be changed by a standard user.
- Exercise English/Hebrew switching and the typed sentence in the installed Allow flow; confirm No/Cancel/Escape leaves blocking unchanged, and Block restores it.
- Check interactive UAC, actual policy state, removal and reboot transitions. These are not proven by synthetic CI.

Known review concerns remain around policy-state/variant verification, staged-versus-active state on older Windows, removal error reporting, exact recovery backups, and Program Files installation-folder trust. The new recovery-folder permission checks do not close all installation-trust concerns. **This is a testing prerelease, not production-ready or a complete security boundary.** Keep local recovery access and do not rely on it as your only protection.

## Primary integration: no-GUI desktop toggle

For embedding in another Windows PowerShell script, see [`docs/script-integration-handoff.md`](docs/script-integration-handoff.md). The integration path creates the shared-desktop **Allow Remote Access** and **Block Remote Access** controls before enforcing **T1A1S0R1** (TeamViewer, AnyDesk and RustDesk blocked; Splashtop allowed). Disabling requires administrator approval, one typed sentence and two confirmations; blocking reinstalls the policy. It removes only this project's fixed policy ID. There is no full application window, service, or automatic unblock; the only scheduled task restores the two desktop icons at startup and never changes the block. The allow warnings use native Windows popups.

Build the standalone preview package from a clean committed checkout:

```bash
./build/build-script-integration.sh
```

The preview ZIP is not a release. Consult the handoff for integration commands, architecture constraints, package verification, and Windows acceptance steps.

## Optional Windows-only GUI kit

The optional Windows GUI kit is `kits/windows-only/`. On a fresh install it uses **T1A1S0R1**: TeamViewer, AnyDesk and RustDesk blocked; Splashtop allowed. This matches the primary integration path. The GUI offers Audit/Test, Enforce/Block, Remove/Undo, and status functions. Use the kit's `START-HERE.bat` on Windows and follow its prompts.

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
