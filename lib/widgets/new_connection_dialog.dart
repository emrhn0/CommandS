import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_state.dart';

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

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_isEdit ? 'Edit Connection' : 'New Connection', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              SegmentedButton<ConnectionProtocol>(
                segments: const [
                  ButtonSegment(value: ConnectionProtocol.ssh, label: Text('SSH')),
                  ButtonSegment(value: ConnectionProtocol.rdp, label: Text('RDP')),
                ],
                selected: {_protocol},
                onSelectionChanged: (s) => _setProtocol(s.first),
                style: ButtonStyle(
                  shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(2))),
                ),
              ),
              const SizedBox(height: 12),
              TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
              const SizedBox(height: 8),
              TextField(controller: _host, autofocus: true, decoration: const InputDecoration(labelText: 'Host')),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _port,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Port'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 3,
                    child: TextField(controller: _username, decoration: const InputDecoration(labelText: 'Username')),
                  ),
                ],
              ),
              if (_protocol == ConnectionProtocol.rdp) ...[
                const SizedBox(height: 8),
                TextField(controller: _domain, decoration: const InputDecoration(labelText: 'Domain (optional)')),
              ],
              const SizedBox(height: 8),
              TextField(
                controller: _password,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Password',
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility, size: 18),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String?>(
                initialValue: _folderId,
                decoration: const InputDecoration(labelText: 'Folder'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('(none)')),
                  ...app.folders.map((f) => DropdownMenuItem(value: f.id, child: Text(f.name))),
                ],
                onChanged: (v) => setState(() => _folderId = v),
              ),
              if (_protocol == ConnectionProtocol.rdp) ...[
                const SizedBox(height: 4),
                SwitchListTile(
                  value: _rdpClipboard,
                  onChanged: (v) => setState(() => _rdpClipboard = v),
                  title: const Text('Share clipboard', style: TextStyle(fontSize: 13)),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
                SwitchListTile(
                  value: _rdpWallpaper,
                  onChanged: (v) => setState(() => _rdpWallpaper = v),
                  title: const Text('Show wallpaper', style: TextStyle(fontSize: 13)),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  OutlinedButton(onPressed: () => _save(alsoConnect: false), child: const Text('Save')),
                  const SizedBox(width: 8),
                  ElevatedButton(onPressed: () => _save(alsoConnect: true), child: const Text('Save && Connect')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
