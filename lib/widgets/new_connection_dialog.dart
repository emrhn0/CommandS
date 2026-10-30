import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../providers/app_state.dart';
import 'app_dialog.dart';
import 'device_icon.dart';
import 'folder_picker.dart';
import '../l10n/strings.dart';

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

/// Saves a session opened from quick connect: the same form with its host,
/// port and protocol already filled in, so only the name, credentials and
/// folder are left to type. Returns the saved connection, or null if
/// cancelled.
Future<SavedConnection?> showSaveQuickConnectionDialog(BuildContext context, SavedConnection target) {
  return showDialog<SavedConnection>(
    context: context,
    builder: (_) => _ConnectionDialog(prefill: target),
  );
}

class _ConnectionDialog extends StatefulWidget {
  const _ConnectionDialog({this.initialFolderId, this.existing, this.prefill});
  final String? initialFolderId;
  final SavedConnection? existing;

  /// Host, port and protocol of an open quick connection being saved.
  final SavedConnection? prefill;

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

  /// Picked in the Device menu; null is "Automatic".
  DeviceKind? _pickedDevice;

  /// What detection found earlier, kept while the menu says Automatic.
  DeviceKind? _detectedDevice;

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
      if (existing.deviceManual) {
        _pickedDevice = existing.device;
      } else {
        _detectedDevice = existing.device;
      }
    } else {
      _folderId = widget.initialFolderId;
      final prefill = widget.prefill;
      if (prefill != null) {
        _host.text = prefill.host;
        _port.text = '${prefill.port}';
        _protocol = prefill.protocol;
      }
    }
  }

  bool get _isSaveOfQuick => widget.prefill != null;

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
      device: _pickedDevice ?? _detectedDevice,
      deviceManual: _pickedDevice != null,
    );
  }

  Widget _deviceRow(DeviceKind? kind, String label) => Row(
        children: [
          SizedBox(width: 22, child: kind == null ? const Icon(Icons.auto_awesome_outlined, size: 15) : DeviceIcon(kind)),
          const SizedBox(width: 10),
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
        ],
      );

  Widget _deviceField() {
    final detected = _detectedDevice;
    return LabeledField(
      label: 'Device',
      child: DropdownButtonFormField<DeviceKind?>(
        key: const ValueKey('device-field'),
        initialValue: _pickedDevice,
        isExpanded: true,
        borderRadius: BorderRadius.circular(6),
        decoration: const InputDecoration(isDense: true),
        items: [
          DropdownMenuItem(
            value: null,
            child: _deviceRow(
              null,
              detected == null
                  ? tr('Automatic (learnt when you connect)')
                  : tr('Automatic ({device})', {'device': detected.label}),
            ),
          ),
          for (final k in DeviceKind.values)
            if (k != DeviceKind.windows) DropdownMenuItem(value: k, child: _deviceRow(k, k.label)),
        ],
        onChanged: (v) => setState(() => _pickedDevice = v),
      ),
    );
  }

  Future<void> _save({required bool alsoConnect}) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final conn = _build();
    if (conn == null) return;
    await app.upsertConnection(conn);
    if (!mounted) return;
    Navigator.pop(context, conn);
    if (alsoConnect) {
      final error = await app.openConnection(conn);
      if (error != null) {
        messenger.showSnackBar(SnackBar(content: Text(error)));
      }
    }
  }

  Widget _passwordField() => LabeledField(
    label: 'Password',
    child: TextField(
      controller: _password,
      obscureText: _obscure,
      decoration: InputDecoration(
        hintText: tr('Ask on connect'),
        suffixIcon: IconButton(
          icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 16),
          tooltip: _obscure ? tr('Show password') : tr('Hide password'),
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
    final rdp = _protocol == ConnectionProtocol.rdp;
    return AppDialog(
      title: tr(
        _isEdit
            ? 'Edit Connection'
            : _isSaveOfQuick
            ? 'Save Connection'
            : 'New Connection',
      ),
      icon: rdp ? Icons.desktop_windows_outlined : Icons.terminal,
      width: 460,
      body: Column(
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
          LabeledField(
            label: 'Name',
            child: TextField(
              controller: _name,
              decoration: InputDecoration(hintText: tr('Defaults to the host')),
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: LabeledField(
                  label: 'Host',
                  child: TextField(controller: _host, autofocus: !_isSaveOfQuick),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: LabeledField(
                  label: 'Port',
                  child: TextField(controller: _port, keyboardType: TextInputType.number),
                ),
              ),
            ],
          ),
          LabeledField(
            label: 'Folder',
            child: FolderField(
              label: null,
              folders: app.folders,
              connections: app.connections,
              value: _folderId,
              onChanged: (v) => setState(() => _folderId = v),
            ),
          ),
          if (!rdp) _deviceField(),
          const _Section('Credentials'),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: LabeledField(
                  label: 'Username',
                  child: TextField(controller: _username, autofocus: _isSaveOfQuick),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: rdp
                    ? LabeledField(
                        label: 'Domain',
                        child: TextField(
                          controller: _domain,
                          decoration: InputDecoration(hintText: tr('Optional')),
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
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
        // A quick connection being saved is already open in its tab.
        if (_isSaveOfQuick)
          ElevatedButton(onPressed: () => _save(alsoConnect: false), child: Text(tr('Save')))
        else ...[
          OutlinedButton(onPressed: () => _save(alsoConnect: false), child: Text(tr('Save'))),
          ElevatedButton(onPressed: () => _save(alsoConnect: true), child: Text(tr('Save and Connect'))),
        ],
      ],
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
            tr(title).toUpperCase(),
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
            Expanded(child: Text(tr(label), style: const TextStyle(fontSize: 13))),
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
