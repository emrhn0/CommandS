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
- RDP sessions run through the OS's own client (`mstsc` / Microsoft Remote
  Desktop) but are embedded directly in a tab, not a separate window —
  credential prompts and the unsigned-`.rdp` security warning are handled
  automatically.
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
