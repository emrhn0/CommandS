# CommandS

An original, native SSH/RDP connection manager for Windows and macOS. No
WebView: built with Flutter, rendered natively.

## Features

- Full folder tree always visible on the left, collapsed by default,
  virtualized for large lists. Add connections through a popup dialog, not
  an always-open form.
- SSH sessions run through **PuTTY's `plink`**, inside a real
  pseudo-terminal (ConPTY on Windows) rendered by our own
  [xterm.dart](https://pub.dev/packages/xterm) view — not a hand-rolled SSH
  client. Network gear (Cisco, Aruba, older firmware) negotiates auth
  methods and algorithms a young pure-Dart client trips over; plink already
  handles all of it.
- Tabbed sessions — each tab is independent and live; switching tabs never
  drops the connection. Drag a tab to an edge of the terminal area to
  split the view, Windows-Snap style.
- RDP sessions on Windows are drawn **inside a tab**, through Microsoft's own
  Remote Desktop ActiveX control (`mstscax.dll`) hosted in-process — the same
  engine `mstsc.exe` is a shell over, so fidelity, input and performance are
  the real client's. Credentials go straight to the control (nothing is
  written to Windows Credential Manager), there is no `.rdp` file and so no
  "unknown publisher" warning, and resizing a pane renegotiates the remote
  desktop at its exact pixel size instead of stretching the old one.
  Ctrl+Alt+Del can be sent from the session bar.
- RDP on macOS opens in the best client installed. FreeRDP
  (`brew install freerdp`) is preferred and is handed the whole connection
  including the saved password, so nothing is typed; otherwise the Microsoft
  client ("Windows App", or the older "Microsoft Remote Desktop") is launched
  with the host and username filled in, and the tab offers the password for
  pasting. Either way the session is its own window: macOS has no embeddable
  RDP component, and AppKit does not let one app place another app's window
  inside its own, so drawing the session in the tab means speaking RDP
  in-process — planned, not here yet.
- PuTTY-style in-terminal `login as:` / `password:` prompts when a
  connection is opened with host only.
- Folder-organized saved connections (create/rename/delete folders;
  deleting a folder keeps its connections, just unfiled). Multi-select
  with Ctrl/Shift-click for bulk move/delete, and cloning a connection.
- Import your own JSON/XML/CSV export, or an export from other popular
  connection managers (nested groups become folders; some of those tools
  encrypt saved passwords with their own vault key that can't be
  decrypted from the exported file alone and must be re-entered — a CSV
  export with credentials visible, where the source tool offers one,
  carries them across intact).
- Customizable terminal colors, saved per install.
- Monochrome, sharp-edged theme — black on white in light mode, white on black in dark mode.

## Development

```
flutter pub get
flutter run -d windows   # or -d macos
```

Windows builds need `plink.exe` on `PATH` or next to `CommandS.exe`
(installed with [PuTTY](https://www.putty.org/); the release installer
bundles it). macOS/Linux use the system `ssh`.

The macOS build ships **without App Sandbox**. An SSH client has to open
outbound connections and read the user's own `~/.ssh` (keys, `known_hosts`,
`config`, the agent socket); a sandboxed build gets a private container
instead and connects to nothing. Releases go out through GitHub, not the Mac
App Store, so the sandbox costs everything and buys nothing here. Upgrading
from 1.0.23 or earlier moves saved connections out of the old container
automatically, once, on first launch.

## Releases

Push a `vX.Y.Z` tag to trigger `.github/workflows/release.yml`, which builds
Windows (installer + portable zip, `plink.exe` bundled) and macOS (zipped
.app) and publishes a GitHub Release.

```
git tag v0.1.0
git push origin v0.1.0
```

## Third-party

PuTTY's `plink.exe` is bundled with the Windows installer/portable build,
under the MIT licence — see `third_party/PUTTY-LICENCE.txt`.
