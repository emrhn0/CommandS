# AGENTS.md

Notes for anyone working on CommandS, people and coding agents (Claude Code,
Codex, Cursor...) alike. The README says what the app does. This file says how
the code is organised, which decisions are deliberate, and the rules that keep
a public repo safe.

## The project

CommandS is a Flutter desktop app (Windows first, macOS second) that manages
SSH, RDP and serial connections. It runs real clients rather than
reimplementing protocols:

- **SSH:** OpenSSH inside a pseudo-terminal.
- **RDP:** Microsoft's own ActiveX control.
- **Serial:** the Win32 comm API.

State lives in one `ChangeNotifier` (`AppState`, through Provider) and is
saved with `shared_preferences`.

## Commands

```sh
flutter pub get
flutter analyze lib test           # no warnings or errors: CI runs it (info notes allowed), and a release is not built otherwise
flutter test                       # unit + widget tests, all must pass
flutter run -d windows             # debug run
flutter build windows --release
flutter test integration_test/<file> -d windows   # real-window tests, Windows only
packages/commands_rdp_mac/tool/build_freerdp.sh   # once, before a macOS build (needs cmake, ninja, Xcode)
flutter run -d macos
```

## Map

| Path | What |
|---|---|
| `lib/providers/app_state.dart` | All app state: connections, folders, tabs, split groups, layouts, settings. Its duplicate-check keys join values with `\u0000`; write that escape, never a raw NUL byte, so the file stays plain text. |
| `lib/services/backup_service.dart`, `lib/widgets/backups_panel.dart` | Backups of the saved connections: daily and before big changes, newest 30 daily and 20 others kept, restored from Settings > Connections. A store that cannot be read is never saved over (`StorageService.loadFailed`). |
| `lib/models/models.dart` | `SavedConnection`, `ConnectionFolder`, `DeviceKind`, JSON. New fields need a default and must be optional in `fromJson` (old saves have to keep loading). |
| `lib/widgets/credential_profiles.dart` | Credential profiles: a user name and password shared by connections (`SavedConnection.credentialProfileId`). `AppState.resolved` gives the login a connection uses; the saved connection keeps its own fields. |
| `lib/widgets/terminal_search.dart` | Search in a terminal (magnifier, Ctrl+Shift+F), marking matches with xterm highlights. |
| `lib/widgets/quick_search.dart` | Quick search over connections and folders (title bar, Ctrl+K outside a terminal, Ctrl+Shift+K inside one: Ctrl+K belongs to the session). |
| `lib/services/host_keys.dart` | Forgets a changed SSH host key with `ssh-keygen -R`, after the user says so from the bar. |
| `lib/services/pty_session.dart` | SSH session: OpenSSH (plink fallback) in ConPTY/forkpty, reach check, `login as:` prompt, output batching, device detection hook. |
| `lib/services/device_detect.dart` | Works out the device kind (Linux, VMware, Palo Alto, Fortinet, Cisco, Aruba, Huawei, Windows) from the SSH identification line and the first output. |
| `lib/services/serial_session.dart` | Serial console via the Win32 comm API in an isolate (9600 8N1 default). macOS uses `screen`. |
| `lib/services/rdp_session.dart`, `windows/runner/rdp_*.cpp` | Embedded RDP (ActiveX host). |
| `lib/services/mac_rdp_session.dart`, `mac_rdp_channel.dart`, `lib/widgets/mac_rdp_view.dart` | macOS RDP, drawn in the tab. Falls back to launching FreeRDP or Microsoft's client in a build without the engine. |
| `packages/commands_rdp_mac` | The macOS RDP engine: FreeRDP linked statically (`tool/build_freerdp.sh` makes `FreeRDP.xcframework`, not in git), a C layer (`rdp_mac.c`) and a Swift plugin painting into a Flutter texture. macOS only; the Windows build does not see it. |
| `lib/services/rdp_keymap.dart` | Mac keys to PC scancodes, Cmd as Ctrl, RDP mouse flags. |
| `lib/services/storage_service.dart`, `rdm_import.dart` | Persistence, import/export (JSON, XML, CSV). |
| `lib/services/password_vault.dart` | AES-GCM for remembered passwords; the key lives in DPAPI (Windows) or the Keychain (macOS). |
| `lib/services/feedback_service.dart` | Anonymous feedback to a Google Form. |
| `lib/services/update_service.dart` | In-app updater (GitHub releases, SHA256 check). |
| `lib/widgets/connection_tree.dart` | The left-hand tree: selection, double click, drag and drop, folder order, selection bar. |
| `lib/widgets/terminal_tabs.dart` | Tabs, split panes, the terminal view. |
| `lib/widgets/device_icon.dart`, `assets/devices/*.svg` | Device logos in the tree. |
| `tool/make_icons.py` | Draws the app icon (a folded-paper lightning bolt) into `assets/icon/commands_mark.svg` (one mark for every theme), `app_icon.ico` and the macOS `AppIcon` PNGs. Change the icon there and rerun it. |
| `lib/l10n/strings.dart`, `lib/l10n/tr.dart` | Translations. |
| `release-notes/vX.Y.Z.md` | User-facing notes per release (see Releasing). |
| `windows/installer.iss` | Inno Setup installer. |

## Decisions that look odd but are deliberate

Do not "simplify" these without reading why.

- **OpenSSH, not plink, on Windows.** Run inside ConPTY, plink dropped arrow
  keys, always asked for 80x24 and never sent window-change, so split panes
  wrapped wrongly. OpenSSH (`System32\OpenSSH\ssh.exe`) is used; plink is only
  the fallback.
  - **Passwords** go through `SSH_ASKPASS`: a small script reads an env var.
    Nothing secret is written to disk or put on a command line. "(yes/no)"
    prompts are answered yes.
  - **Known hosts** are kept in the app's own file under `%APPDATA%\CommandS`.
  - **Host and username** are checked against strict patterns before they go
    into the batch launcher.
- **A login question that reaches the terminal gets a bar** (`LoginWatcher`).
  Normally askpass answers it. The saved password is typed only at OpenSSH's
  own `(user@host)` prompt, once, after such a question, early in the session,
  as a logged-in device can print anything.
- **The reach check comes before `login as:`.** A TCP connect to the SSH port
  runs first, so an address with nothing behind it fails clearly instead of
  showing a prompt. The same connect reads the server's `SSH-2.0-...` line for
  device detection; nothing is ever sent to the device. UI tests set
  `PtySessionController.checkReachability = false`.
- **Device detection is passive.** It only reads what the device prints. A kind
  picked by hand (`deviceManual`) is never overwritten. RDP is always shown as
  Windows.
- **RDP is an ActiveX control in an owned top-level window, not a child.**
  - DWM composites Flutter's DirectComposition surface above child HWNDs, so a
    child session window got painted over.
  - Because the window is owned, it has to be hidden while Flutter dialogs are
    open (`RdpModalObserver`).
  - Nothing Flutter draws inside the pane is visible, so session actions live
    in the tab's right-click menu.
  - While hidden, the pane shows a still picture of the session
    (`RdpChannel.holdSuspended`), so a menu does not turn it black. The picture
    stays in memory only.
  - Ctrl+Alt+Del goes through `IMsRdpClientNonScriptable::SendKeys`.
    `SendRemoteAction` has no such action; its value 0 means Charms.
  - The clipboard is handed across on `WM_ACTIVATE` through
    `IMsRdpClientNonScriptable7::Clipboard` (`SyncClipboard`): in this window
    the control did not follow it on its own.
- **macOS RDP links FreeRDP into the app** instead of opening another
  program. AppKit does not let one app place another app's window in a tab,
  and macOS has no RDP component to embed, so the session has to be spoken
  in-process (Remote Desktop Manager does the same).
  - Built static, with OpenSSL, for both architectures, so the app loads
    nothing from Homebrew. No ffmpeg, audio, X11 or device redirection.
  - Frames are copied out of FreeRDP's GDI buffer into a fresh
    `CVPixelBuffer` per paint, so Flutter never reads a half-written frame.
  - Keys are sent as scancodes; the server's layout picks the character.
    Command with another key is Ctrl (Cmd+C copies), tapped alone it is the
    Windows key. Apple ISO keyboards swap two keys, which are swapped back.
  - Certificates: first one trusted and remembered under Application
    Support/CommandS/freerdp, a changed one stops the connection.
  - No saved password: the pane asks, and the answer stays in that tab.
- **Tree clicks work like Explorer.** One click selects, a double click opens.
  - Double clicks are detected from pointer-down timestamps in a `Listener`,
    not with a double-tap recognizer, which would delay every single click.
  - The click memory is static, keyed by row id, because rows rebuild between
    the two clicks.
- **Dragging in the tree** uses `_ThresholdDragRecognizer`.
  - A drag starts only after 6 px of movement. When the recognizer is the
    arena's only member, it wins at pointer-down, so the start is deferred
    until the threshold.
  - The dragged row is dimmed in place. Do not use `childWhenDragging`: it
    rebuilt the row and broke double click.
- **RDP sessions hide during a tab drag** (`RdpTabDrag`). Their native window
  would cover the drop targets and swallow the drag.
- **Remembered passwords are encrypted only in storage.** `saveConnections`
  writes `passwordEnc`. If encryption fails the password stays as it was, and
  a value that cannot be opened is saved back untouched: never lose one.
  Under `flutter test` the key store is in memory, so tests cannot reach the
  real key.
- **The SFTP file manager's own window** (`sftp_window.dart`) is a second
  engine through `desktop_multi_window`: same process, same taskbar button.
  It gets what it needs to connect as launch arguments, in memory only, and
  registers the generated plugins but not the RDP one.
- **Updates are checked every minute from the releases feed**
  (`releases.atom`), not the API. Unauthenticated API calls are limited to 60
  an hour per network, which an office checking that often would use up; the
  API is asked only once something newer has turned up.
- **Typing into several sessions** (the tick on a split pane's bar) repeats
  only what the keyboard types or pastes (`PtySessionController.onTyped`),
  never what an agent sends through MCP (`sendInput`).
- **Terminal output is batched** (about one flush per 16 ms) and decoded as one
  UTF-8 stream. Drawing every chunk made busy sessions stutter.
- **Keyboard** behaves as in PuTTY.
  - `TerminalView` gets empty shortcuts so Ctrl+A and Ctrl+V reach the session.
  - Copy and paste are Ctrl+Insert and Shift+Insert, select-to-copy, and
    right-click paste.
  - Selecting with the mouse past the edge auto-scrolls.

## Translations

- UI text goes through `tr('English text')`, and the English text is the key.
  Add the Turkish line to `lib/l10n/tr.dart`.
- `test/l10n_test.dart` fails on any `tr()` string without a translation.
- Don't wrap brand or product names in `tr()`.

## Tests

- Every change ships with tests. Every bug fix gets a test that fails on the
  old code.
- Widget tests that click or drag must `pump` between pointer events, or they
  miss rebuild bugs.
  - In tests every pointer event has `timeStamp` zero.
- For real mouse input on Windows, an integration test can post
  `WM_LBUTTONDOWN` and similar messages to its own `FLUTTERVIEW` window, with
  `shouldPropagateDevicePointerEvents = true`.
- On Windows, setting `APPDATA` does **not** isolate a launched app's
  preferences (the known-folder API ignores it), so it loads the real saved
  connections. For fake data, use tests with
  `SharedPreferences.setMockInitialValues`, not a launched build.

## Privacy rules (the repo is public)

- Never commit real hosts, IP addresses, usernames, passwords, customer,
  company, folder or connection names. That covers code, tests, comments,
  commit messages, release notes, screenshots and exports.
  - Use the documentation ranges `192.0.2.x` and `198.51.100.x`, and names like
    `CUSTOMER-A` and `DEVICE-01`.
- Never commit preference files, exports, logs or anything copied from a
  machine's real connection list.
- Integration tests with local paths stay untracked: list them in
  `.git/info/exclude`.
- Commit with your GitHub noreply address, not a personal email.
- Review the full diff for any of the above before pushing.

## Releasing

1. Bump `appVersion` in `lib/app_version.dart`, following
   [Semantic Versioning 2.0.0](https://semver.org/) (`MAJOR.MINOR.PATCH`).
   For an app, the "public API" is what other versions and tools rely on:
   saved connections and settings, the export/import formats, the MCP tools
   an agent calls, and the systems it runs on.
   - **PATCH** (`1.2.0` to `1.2.1`): backward-compatible bug fixes only.
   - **MINOR** (`1.2.1` to `1.3.0`, PATCH back to 0): new backward-compatible
     functionality, such as a feature, setting or language, or marking
     something as deprecated. Fixes released alongside go in the same bump.
   - **MAJOR** (`1.3.0` to `2.0.0`, MINOR and PATCH back to 0): an
     incompatible change, such as saved data or an export an older version
     cannot read, an MCP tool removed or changed in a breaking way, or a
     supported OS dropped.
   - A released version is never changed; any change ships as a new one.
   - A beta is a SemVer pre-release of the version it leads to:
     `v1.3.0-beta.1`, `-beta.2`... It ranks below `v1.3.0`.
   - **Stay on one beta line until it is released.** The version number is
     picked when a beta cycle starts. While that version has no normal
     release yet, every further change, fix or feature, goes out as the
     next beta of the same version (`v1.4.0-beta.2`, `-beta.3`...), never as
     a beta of a newer version. Only when the normal release is out does the
     next change pick a new number by the rules above. Jumping ahead skips a
     version on GitHub, because a normal release removes the betas before
     it (v1.4.0 was skipped this way; that is the one exception).
2. Write `release-notes/vX.Y.Z.md`: a short list of user-facing changes and
   fixes in plain English. It is shown in the app's update dialog, so it
   matters.
3. Run `flutter analyze` and `flutter test`, then commit and push to `master`.
4. Tag `vX.Y.Z` and push the tag. `.github/workflows/release.yml` then:
   - builds the Windows installer, the portable zip and the macOS zip onto a
     draft release;
   - writes `SHA256SUMS.txt` (the updater checks it);
   - publishes the release. Normal releases are all kept; the betas of a
     version (and older ones) are removed once its normal release is out.
5. Installed apps list the app as "CommandS vX.Y.Z" (`AppVerName` in
   `installer.iss`).

A `vX.Y.Z-beta.N` tag publishes a GitHub prerelease, without changing the
latest release. A beta is the same app at a newer version: it installs over
the normal one and keeps its connections, settings and password key. It is
taken by hand (its download, or Settings > Updates with Beta picked). The
automatic check offers normal releases only, so a beta install moves on to
the next normal release.
