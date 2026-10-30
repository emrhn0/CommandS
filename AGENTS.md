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
flutter analyze lib test           # must be clean (two old infos in pty_session.dart are known)
flutter test                       # unit + widget tests, all must pass
flutter run -d windows             # debug run
flutter build windows --release
flutter test integration_test/<file> -d windows   # real-window tests, Windows only
```

## Map

| Path | What |
|---|---|
| `lib/providers/app_state.dart` | All app state: connections, folders, tabs, split groups, layouts, settings. **Contains a few NUL bytes**, so some tools treat it as binary. Edit it with byte-safe tools and check the NUL count is unchanged. |
| `lib/models/models.dart` | `SavedConnection`, `ConnectionFolder`, `DeviceKind`, JSON. New fields need a default and must be optional in `fromJson` (old saves have to keep loading). |
| `lib/services/pty_session.dart` | SSH session: OpenSSH (plink fallback) in ConPTY/forkpty, reach check, `login as:` prompt, output batching, device detection hook. |
| `lib/services/device_detect.dart` | Works out the device kind (Linux, VMware, Palo Alto, Fortinet, Cisco, Aruba, Huawei, Windows) from the SSH identification line and the first output. |
| `lib/services/serial_session.dart` | Serial console via the Win32 comm API in an isolate (9600 8N1 default). macOS uses `screen`. |
| `lib/services/rdp_session.dart`, `windows/runner/rdp_*.cpp` | Embedded RDP (ActiveX host). |
| `lib/services/mac_rdp_session.dart` | macOS RDP: launches FreeRDP or Microsoft's client. |
| `lib/services/storage_service.dart`, `rdm_import.dart` | Persistence, import/export (JSON, XML, CSV). |
| `lib/services/feedback_service.dart` | Anonymous feedback to a Google Form. |
| `lib/services/update_service.dart` | In-app updater (GitHub releases, SHA256 check). |
| `lib/widgets/connection_tree.dart` | The left-hand tree: selection, double click, drag and drop, folder order, selection bar. |
| `lib/widgets/terminal_tabs.dart` | Tabs, split panes, the terminal view. |
| `lib/widgets/device_icon.dart`, `assets/devices/*.svg` | Device logos in the tree. |
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
  - Nothing Flutter draws inside the pane is visible, so session controls live
    in a bar above it.
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

1. Bump `appVersion` in `lib/app_version.dart`.
2. Write `release-notes/vX.Y.Z.md`: a short list of user-facing changes and
   fixes in plain English. It is shown in the app's update dialog, so it
   matters.
3. Run `flutter analyze` and `flutter test`, then commit and push to `master`.
4. Tag `vX.Y.Z` and push the tag. `.github/workflows/release.yml` then:
   - builds the Windows installer, the portable zip and the macOS zip onto a
     draft release;
   - writes `SHA256SUMS.txt` (the updater checks it);
   - publishes the release and keeps the latest five.
5. Installed apps list the app as "CommandS vX.Y.Z" (`AppVerName` in
   `installer.iss`).
