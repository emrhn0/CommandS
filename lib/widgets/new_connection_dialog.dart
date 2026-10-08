import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../providers/app_state.dart';
import 'folder_picker.dart';

/// RDM-style session popup — connections are never edited in an inline
/// panel, only through this dialog. Opened from the "+ New Connection"
/// toolbar button (optionally pre-filled with a target folder), or from a
/// connection's "Edit" menu entry.
Future<void> showNewConnectionDialog(BuildContext context, {String? folderId}) {
  return showDialog(
    context: context,
    builder: (_) => _ConnectionDialog(initialFolderId: folderId),
  );
}

/// Edit an existing connection in place: same form, pre-filled, saving back
/// onto the same id instead of creating a second entry.
Future<void> showEditConnectionDialog(BuildContext context, SavedConnection conn) {
  return showDialog(
    context: context,
    builder: (_) => _ConnectionDialog(existing: conn),
  );
}

class _ConnectionDialog extends StatefulWidget {
  const _ConnectionDialog({this.initialFolderId, this.existing});
  final String? initialFolderId;
  final SavedConnection? existing;

  @override
  State<_ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<_ConnectionDialog> {
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _domain = TextEditingController();
  bool _obscure = true;
  String? _folderId;
  ConnectionProtocol _protocol = ConnectionProtocol.ssh;
  bool _rdpClipboard = true;
  bool _rdpWallpaper = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing != null) {
      _name.text = existing.name;
      _host.text = existing.host;
      _port.text = '${existing.port}';
      _username.text = existing.username;
      _password.text = existing.password;
      _domain.text = existing.domain ?? '';
      _folderId = existing.folderId;
      _protocol = existing.protocol;
      _rdpClipboard = existing.rdpClipboard;
      _rdpWallpaper = existing.rdpWallpaper;
    } else {
      _folderId = widget.initialFolderId;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _domain.dispose();
    super.dispose();
  }

  void _setProtocol(ConnectionProtocol p) {
    setState(() {
      _protocol = p;
      final defaultPort = p == ConnectionProtocol.rdp ? '3389' : '22';
      if (_port.text.trim().isEmpty || _port.text.trim() == '22' || _port.text.trim() == '3389') {
        _port.text = defaultPort;
      }
    });
  }

  SavedConnection? _build() {
    final host = _host.text.trim();
    if (host.isEmpty) return null;
    final port = int.tryParse(_port.text.trim()) ?? (_protocol == ConnectionProtocol.rdp ? 3389 : 22);
    return SavedConnection(
      // Keeping the id means an edit updates the entry instead of cloning it.
      id: widget.existing?.id,
      name: _name.text.trim().isEmpty ? host : _name.text.trim(),
      host: host,
      port: port,
      username: _username.text.trim(),
      // A saved connection always remembers whatever password field it was
      // given — that's the point of typing one in here. An empty field just
      // means "ask at connect time", same as before.
      rememberPassword: true,
      password: _password.text,
      folderId: _folderId,
      protocol: _protocol,
      domain: _domain.text.trim().isEmpty ? null : _domain.text.trim(),
      rdpClipboard: _rdpClipboard,
      rdpWallpaper: _rdpWallpaper,
    );
  }

  Future<void> _save({required bool alsoConnect}) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final conn = _build();
    if (conn == null) return;
    await app.upsertConnection(conn);
    if (!mounted) return;
    Navigator.pop(context);
    if (alsoConnect) {
      final error = await app.openConnection(conn);
      if (error != null) {
        messenger.showSnackBar(SnackBar(content: Text(error)));
      }
    }
  }

  Widget _passwordField() => _Field(
    label: 'Password',
    child: TextField(
      controller: _password,
      obscureText: _obscure,
      decoration: InputDecoration(
        hintText: 'Ask on connect',
        suffixIcon: IconButton(
          icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 16),
          tooltip: _obscure ? 'Show password' : 'Hide password',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 30, height: 30),
          style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          onPressed: () => setState(() => _obscure = !_obscure),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final rdp = _protocol == ConnectionProtocol.rdp;
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Title bar: what is being edited, and a way out.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 10, 14),
              child: Row(
                children: [
                  Icon(rdp ? Icons.desktop_windows_outlined : Icons.terminal, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _isEdit ? 'Edit Connection' : 'New Connection',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SegmentedButton<ConnectionProtocol>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: ConnectionProtocol.ssh,
                          label: Text('SSH'),
                          icon: Icon(Icons.terminal, size: 16),
                        ),
                        ButtonSegment(
                          value: ConnectionProtocol.rdp,
                          label: Text('RDP'),
                          icon: Icon(Icons.desktop_windows_outlined, size: 16),
                        ),
                      ],
                      selected: {_protocol},
                      onSelectionChanged: (s) => _setProtocol(s.first),
                    ),
                    const _Section('Connection'),
                    _Field(
                      label: 'Name',
                      child: TextField(
                        controller: _name,
                        decoration: const InputDecoration(hintText: 'Defaults to the host'),
                      ),
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 3,
                          child: _Field(
                            label: 'Host',
                            child: TextField(controller: _host, autofocus: true),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _Field(
                            label: 'Port',
                            child: TextField(controller: _port, keyboardType: TextInputType.number),
                          ),
                        ),
                      ],
                    ),
                    _Field(
                      label: 'Folder',
                      child: FolderField(
                        label: null,
                        folders: app.folders,
                        connections: app.connections,
                        value: _folderId,
                        onChanged: (v) => setState(() => _folderId = v),
                      ),
                    ),
                    const _Section('Credentials'),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _Field(
                            label: 'Username',
                            child: TextField(controller: _username),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: rdp
                              ? _Field(
                                  label: 'Domain',
                                  child: TextField(
                                    controller: _domain,
                                    decoration: const InputDecoration(hintText: 'Optional'),
                                  ),
                                )
                              : _passwordField(),
                        ),
                      ],
                    ),
                    if (rdp) _passwordField(),
                    if (rdp) ...[
                      const _Section('Remote desktop'),
                      Row(
                        children: [
                          Expanded(
                            child: _Toggle(
                              label: 'Share clipboard',
                              value: _rdpClipboard,
                              onChanged: (v) => setState(() => _rdpClipboard = v),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _Toggle(
                              label: 'Show wallpaper',
                              value: _rdpWallpaper,
                              onChanged: (v) => setState(() => _rdpWallpaper = v),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // Windows' dialog footer: the actions on a tinted band.
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              decoration: BoxDecoration(
                color: theme.scaffoldBackgroundColor,
                border: Border(top: BorderSide(color: theme.dividerColor)),
              ),
              // Wraps rather than overflowing with large system fonts.
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                  OutlinedButton(onPressed: () => _save(alsoConnect: false), child: const Text('Save')),
                  ElevatedButton(
                    onPressed: () => _save(alsoConnect: true),
                    child: const Text('Save and Connect'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A group heading, in the style of the context menu's header: small, dimmed
/// capitals over a hairline.
class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Row(
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
              color: theme.textTheme.bodySmall?.color,
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

/// A label above its field, as desktop forms do, rather than Material's
/// label floating inside the box.
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 1, bottom: 4),
            child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          ),
          child,
        ],
      ),
    );
  }
}

/// A settings-style row: the label, and a small switch at the right edge.
class _Toggle extends StatelessWidget {
  const _Toggle({required this.label, required this.value, required this.onChanged});
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
            Transform.scale(
              scale: 0.8,
              alignment: Alignment.centerRight,
              child: Switch(value: value, onChanged: onChanged),
            ),
          ],
        ),
      ),
    );
  }
}
