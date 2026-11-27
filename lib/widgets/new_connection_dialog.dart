import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../providers/app_state.dart';
import 'app_dialog.dart';
import 'app_select.dart';
import 'credential_profiles.dart';
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
  final _enablePassword = TextEditingController();
  final _domain = TextEditingController();
  bool _obscure = true;
  bool _obscureEnable = true;
  String? _folderId;
  ConnectionProtocol _protocol = ConnectionProtocol.ssh;
  bool _rdpClipboard = true;
  bool _rdpWallpaper = false;
  bool _recordSessionByDefault = false;

  /// SSH: answer the login yes/no question by itself.
  bool _answerLoginYes = false;

  /// The credential profile to log in with; null for this connection's own
  /// user name and password.
  String? _profileId;
  static const _newProfile = '__new_profile__';

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
      _enablePassword.text = existing.enablePassword;
      _domain.text = existing.domain ?? '';
      _folderId = existing.folderId;
      _protocol = existing.protocol;
      _rdpClipboard = existing.rdpClipboard;
      _rdpWallpaper = existing.rdpWallpaper;
      _recordSessionByDefault = existing.recordSessionByDefault;
      _answerLoginYes = existing.answerLoginQuestionYes;
      _profileId = existing.credentialProfileId;
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
        _enablePassword.text = prefill.enablePassword;
        _recordSessionByDefault = prefill.recordSessionByDefault;
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
    _enablePassword.dispose();
    _domain.dispose();
    super.dispose();
  }

  void _setProtocol(ConnectionProtocol p) {
    setState(() {
      final useDefault = _port.text.trim().isEmpty ||
          _port.text.trim() == '${_protocol.defaultPort}';
      _protocol = p;
      if (useDefault) _port.text = '${p.defaultPort}';
    });
  }

  SavedConnection? _build() {
    final host = _host.text.trim();
    if (host.isEmpty) return null;
    final enteredName = _name.text.trim();
    final autoName = _protocol == ConnectionProtocol.ssh &&
        (enteredName.isEmpty ||
            (widget.existing?.autoNamePending == true && enteredName == widget.existing!.name));
    final port = int.tryParse(_port.text.trim()) ?? _protocol.defaultPort;
    final telnet = _protocol == ConnectionProtocol.telnet;
    return SavedConnection(
      // Keeping the id means an edit updates the entry instead of cloning it.
      id: widget.existing?.id,
      name: autoName || enteredName.isEmpty ? host : enteredName,
      autoNamePending: autoName,
      host: host,
      port: port,
      username: telnet ? '' : _username.text.trim(),
      // A saved connection always remembers whatever password field it was
      // given — that's the point of typing one in here. An empty field just
      // means "ask at connect time", same as before.
      rememberPassword: !telnet,
      password: telnet ? '' : _password.text,
      enablePassword: _protocol == ConnectionProtocol.ssh ? _enablePassword.text : '',
      folderId: _folderId,
      protocol: _protocol,
      domain: telnet || _domain.text.trim().isEmpty ? null : _domain.text.trim(),
      rdpClipboard: _rdpClipboard,
      rdpWallpaper: _rdpWallpaper,
      recordSessionByDefault: _protocol != ConnectionProtocol.rdp && _recordSessionByDefault,
      device: _pickedDevice ?? _detectedDevice,
      deviceManual: _pickedDevice != null,
      credentialProfileId: telnet ? null : _profileId,
      answerLoginQuestionYes: _protocol == ConnectionProtocol.ssh && _answerLoginYes,
    );
  }

  Future<void> _pickProfile(String? value) async {
    if (value != _newProfile) {
      setState(() => _profileId = value);
      return;
    }
    final created = await showCredentialProfileDialog(context);
    if (!mounted) return;
    setState(() => _profileId = created?.id ?? _profileId);
  }

  Widget _profileField(AppState app) {
    final profiles = [...app.credentialProfiles]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final known = _profileId == null || profiles.any((p) => p.id == _profileId);
    return LabeledField(
      label: 'Log in with',
      child: AppSelect<String?>(
        key: const ValueKey('profile-field'),
        value: known ? _profileId : null,
        items: [
          AppSelectItem(null, tr('Its own user name and password'), leading: const Icon(Icons.person_outline, size: 16)),
          for (final p in profiles)
            AppSelectItem(
              p.id,
              tr('Profile: {name}', {'name': p.name}),
              leading: const Icon(Icons.badge_outlined, size: 16),
            ),
          AppSelectItem(
            _newProfile,
            tr('New profile…'),
            leading: const Icon(Icons.add, size: 16),
            dividerBefore: true,
            action: true,
          ),
        ],
        onChanged: _pickProfile,
      ),
    );
  }

  Widget _deviceField() {
    final detected = _detectedDevice;
    return LabeledField(
      label: 'Device',
      child: AppSelect<DeviceKind?>(
        key: const ValueKey('device-field'),
        value: _pickedDevice,
        items: [
          AppSelectItem(
            null,
            detected == null
                ? tr('Automatic (learnt when you connect)')
                : tr('Automatic ({device})', {'device': detected.label}),
            leading: const Icon(Icons.auto_awesome_outlined, size: 16),
          ),
          for (final k in DeviceKind.values)
            if (k != DeviceKind.windows)
              AppSelectItem(k, k.label, leading: DeviceIcon(k), dividerBefore: k == DeviceKind.values.first),
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

  Widget _secretField({
    required String label,
    required TextEditingController controller,
    required bool obscure,
    required VoidCallback onToggle,
    required String hint,
    Key? fieldKey,
  }) => LabeledField(
    label: label,
    child: TextField(
      key: fieldKey,
      controller: controller,
      obscureText: obscure,
      decoration: InputDecoration(
        hintText: tr(hint),
        suffixIcon: IconButton(
          icon: Icon(obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 16),
          tooltip: obscure ? tr('Show password') : tr('Hide password'),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 30, height: 30),
          style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          onPressed: onToggle,
        ),
      ),
    ),
  );

  Widget _passwordField() => _secretField(
    label: 'Password',
    controller: _password,
    obscure: _obscure,
    onToggle: () => setState(() => _obscure = !_obscure),
    hint: 'Ask on connect',
  );

  Widget _enablePasswordField() => _secretField(
    label: 'Enable password',
    controller: _enablePassword,
    obscure: _obscureEnable,
    onToggle: () => setState(() => _obscureEnable = !_obscureEnable),
    hint: 'Optional',
    fieldKey: const ValueKey('enable-password-field'),
  );

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final rdp = _protocol == ConnectionProtocol.rdp;
    final telnet = _protocol == ConnectionProtocol.telnet;
    return AppDialog(
      title: tr(
        _isEdit
            ? 'Edit Connection'
            : _isSaveOfQuick
            ? 'Save Connection'
            : 'New Connection',
      ),
      icon: rdp ? Icons.desktop_windows_outlined : telnet ? Icons.settings_ethernet : Icons.terminal,
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
                value: ConnectionProtocol.telnet,
                label: Text('Telnet'),
                icon: Icon(Icons.settings_ethernet, size: 16),
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
          if (telnet)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                tr('Telnet is not encrypted. Enter login details in the terminal.'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const _Section('Connection'),
          LabeledField(
            label: 'Name',
            child: TextField(
              controller: _name,
              decoration: InputDecoration(
                hintText: tr(rdp || telnet ? 'Defaults to the host' : 'Hostname after first SSH connection, otherwise host'),
              ),
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
          if (!telnet) ...[
            const _Section('Credentials'),
            _profileField(app),
            if (_profileId != null && app.credentialProfiles.any((p) => p.id == _profileId)) ...[
              Padding(
                padding: const EdgeInsets.only(left: 2, bottom: 8),
                child: Text(
                  tr("Logs in as {user} with the profile's password. Change them in the profile.", {
                    'user': app.credentialProfiles.firstWhere((p) => p.id == _profileId).username.isEmpty
                        ? '—'
                        : app.credentialProfiles.firstWhere((p) => p.id == _profileId).username,
                  }),
                  style: TextStyle(fontSize: 12, color: Theme.of(context).textTheme.bodySmall?.color),
                ),
              ),
              if (rdp)
                LabeledField(
                  label: 'Domain',
                  child: TextField(controller: _domain, decoration: InputDecoration(hintText: tr('Optional'))),
                ),
            ] else ...[
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
            ],
            if (!rdp) _enablePasswordField(),
          ],
          if (!rdp) ...[
            const _Section('Other'),
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => setState(() => _recordSessionByDefault = !_recordSessionByDefault),
              child: Row(
                children: [
                  Checkbox(
                    value: _recordSessionByDefault,
                    onChanged: (v) => setState(() => _recordSessionByDefault = v ?? false),
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 4),
                  Expanded(child: Text(tr('Record session automatically'), style: const TextStyle(fontSize: 13))),
                ],
              ),
            ),
            if (!telnet) InkWell(
              key: const Key('answer-login-yes'),
              borderRadius: BorderRadius.circular(6),
              onTap: () => setState(() => _answerLoginYes = !_answerLoginYes),
              child: Row(
                children: [
                  Checkbox(
                    value: _answerLoginYes,
                    onChanged: (v) => setState(() => _answerLoginYes = v ?? false),
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      tr('Answer yes to the login question (yes/no) by itself'),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ],
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
