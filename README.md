# CommandS

A connection manager for SSH, RDP and serial consoles, for Windows and macOS.
Keep every device in one folder tree and open it in a tab with a double click.

It is built to be fast and to stay out of the way. It is a native app, not a
web page in a window. Busy terminals scroll without stutter, even with
several sessions side by side, and a tree of thousands of connections stays
quick. Underneath it uses the clients that have proven themselves for
years: OpenSSH for SSH, and Microsoft's own Remote Desktop engine for RDP.
Connections behave the way you already know from those clients, without
their quirks.

**[Download the latest release](https://github.com/emrhn0/CommandS/releases/latest)**

| | |
|---|---|
| Windows 10 / 11 | `CommandS_x.y.z_windows_Setup.exe`, or the portable zip |
| macOS | `CommandS_x.y.z_macOS.zip`: unzip and drag to Applications |

The app checks for updates itself. On Windows it installs them with one
click; on macOS it opens the download page.

## What it does

- **SSH** in tabs, through the OpenSSH client your system already has.
  Works with old network gear too. The keyboard, copy and paste behave as in
  PuTTY.
- **RDP** runs inside a tab, on Windows and on macOS. The window size is the
  desktop size, and clipboard text goes both ways.
- **Serial consoles**: type the COM port number in quick connect (`3` for
  COM3, `3:115200` for another speed).
- **Split view**: several sessions side by side, each with its own small tab
  bar. Save an arrangement as a layout and open it again later.
- **Folder tree** that works like Explorer: click to select, double click to
  connect, drag to reorganise.
- **SFTP file manager** next to any SSH session.
- **Session logs**: record a session to a plain text file, and open it from
  the message shown when recording stops.
- **Import** from JSON, XML or CSV, including exports from Remote Desktop
  Manager. **Export** whenever you like.
- **Search** inside a terminal (Ctrl+Shift+F), and **quick search** over all
  connections and folders (Ctrl+K).
- **Type into several sessions at once** in split view: tick the panes that
  should get what you type.
- **Credential profiles**: one user name and password shared by many
  connections, changed in one place.
- **Favorites** for the connections you open most.
- **Backups** of your connections every day and before big changes, restored
  with one click from Settings.
- **Themes**, terminal fonts and colours. English, Turkish and German.

## What's different

Things you will not find in most SSH and RDP managers:

- **AI agents in your sessions (MCP).** Let Claude, ChatGPT, Cursor or
  another AI assistant read output and run commands on the connections you
  pick, and nothing else. Commands that change something wait for your
  approval in CommandS. See [AI agents](#ai-agents-mcp).
- **Clean session logs.** A recording keeps what the session showed, as
  plain text: no colour codes, and no letters you typed and then erased.
  Each command is logged as it stood when you pressed Enter.
- **The device recognises itself.** CommandS reads what a device prints when
  you connect and shows its logo in the tree (Cisco, Fortinet, Palo Alto,
  Aruba, Huawei, VMware, Linux, Windows). A connection saved without a name
  takes the device's hostname. Nothing is ever sent to the device for this.
- **RDP in a tab, with nothing left behind.** No `.rdp` files, no
  "unknown publisher" warning, nothing stored in Windows Credential Manager.
  Resizing the pane resizes the remote desktop to fit exactly, instead of
  stretching it.
- **Verified file transfers.** The SFTP file manager checks every transfer
  with SHA-256, so a copied backup or image is known to be intact.
- **sudo without typing the password.** When a server asks for the sudo
  password, CommandS offers to fill in the saved one.
- **Split view that remembers.** Arrange several sessions on one screen and
  save the arrangement as a layout, to bring the same sessions back in the
  same places later.
- **Free**, with no account, no sign-in and no subscription.

## Passwords and privacy

- Saved passwords are encrypted on your computer (Windows DPAPI, macOS
  Keychain). They are never written to a command line or a temporary file.
- Your connections are kept only on your computer. The app goes online
  only to check GitHub for updates, and when you send feedback, which is
  anonymous: only your message, the app version and the operating system.

## AI agents (MCP)

CommandS can let an AI assistant work in your SSH sessions: Claude, ChatGPT,
Cursor, or any app that supports MCP servers over HTTP.

1. Open **Settings > MCP integration** and turn it on.
2. Tick the connections the agent may use. Nothing else is shown to it.
3. Add the URL shown there to your AI app as an MCP server. For example, in
   Claude Code:

   ```
   claude mcp add --transport http commands <URL from Settings>
   ```

- Off by default, and reachable only from your own computer.
- The default MCP server port is 8765. Change it in **Settings > MCP
  integration**, then update the URL in your MCP client or tunnel.
- The agent sees each allowed connection's name, address, port and
  username, never its password.
- On network devices, `show` and `display` commands run at once. Every
  other command asks you first.
- Terminal output is sent to the agent as it is.
- Keep the URL private: any program on your computer that has it can use
  the allowed connections. **New address** in Settings replaces it.

## Beta versions

Pick **Beta** in **Settings > Updates** to try new features early. A beta
installs over the normal version and keeps your connections and settings.

## Feedback

Use **Settings > Support & feedback**, or
[open an issue](https://github.com/emrhn0/CommandS/issues).

## Building from source

```
flutter pub get
flutter run -d windows   # or -d macos
```

See [AGENTS.md](AGENTS.md) for how the code is organised and how releases
are made.

## Third-party

The Windows build bundles PuTTY's `plink.exe` as a fallback SSH client,
under the MIT licence: see [third_party/PUTTY-LICENCE.txt](third_party/PUTTY-LICENCE.txt).
