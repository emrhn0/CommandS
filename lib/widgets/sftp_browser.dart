import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../theme/app_theme.dart';
import 'tool_button.dart';
import '../services/sftp_client.dart';

typedef SftpClientFactory = Future<SftpClient> Function(String? password);

class LocalFileEntry {
  const LocalFileEntry(
    this.name, {
    required this.isDirectory,
    required this.size,
  });
  final String name;
  final bool isDirectory;
  final int size;
}

abstract class LocalFileBrowser {
  String get initialPath;
  String parent(String path);
  String join(String path, String name);
  Future<List<LocalFileEntry>> list(String path);
}

class DiskFileBrowser implements LocalFileBrowser {
  @override
  String get initialPath => Platform.isWindows
      ? (Platform.environment['USERPROFILE'] ?? Directory.current.path)
      : (Platform.environment['HOME'] ?? Directory.current.path);

  @override
  String parent(String path) => Directory(path).parent.path;

  @override
  String join(String path, String name) =>
      '$path${Platform.pathSeparator}$name';

  @override
  Future<List<LocalFileEntry>> list(String path) async {
    final result = <LocalFileEntry>[];
    await for (final entity in Directory(path).list(followLinks: false)) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type != FileSystemEntityType.directory &&
          type != FileSystemEntityType.file) {
        continue;
      }
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final size = type == FileSystemEntityType.file
          ? await File(entity.path).length()
          : 0;
      result.add(
        LocalFileEntry(
          Uri.decodeComponent(name),
          isDirectory: type == FileSystemEntityType.directory,
          size: size,
        ),
      );
    }
    result.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return result;
  }
}

class SftpBrowser extends StatefulWidget {
  const SftpBrowser({super.key, required this.createClient, this.localBrowser, this.onClose, this.onExpand, this.wide = false});
  final SftpClientFactory createClient;

  /// Closes the panel; the terminal stays.
  final VoidCallback? onClose;

  /// Opens the file manager in a window of its own. Without it, the expand
  /// button shows it over this window instead.
  final VoidCallback? onExpand;

  /// Side by side over the whole window, rather than a panel beside the
  /// terminal.
  final bool wide;
  final LocalFileBrowser? localBrowser;

  @override
  State<SftpBrowser> createState() => _SftpBrowserState();
}

class _Transfer {
  _Transfer(this.name, this.direction);
  final String name;
  final IconData direction;
  String status = 'Transferring';
  String? error;
}

class _SftpBrowserState extends State<SftpBrowser> {
  late final LocalFileBrowser _local = widget.localBrowser ?? DiskFileBrowser();
  late String _localPath = _local.initialPath;
  String _remotePath = '';
  List<LocalFileEntry> _localEntries = [];
  List<SftpEntry> _remoteEntries = [];
  final List<_Transfer> _transfers = [];
  SftpClient? _client;
  String? _remoteError;
  String? _localError;
  String? _selectedRemote;
  String? _selectedLocal;
  bool _remoteLoading = true;
  bool _localLoading = true;
  bool _busy = false;
  int _remoteRequest = 0;
  int _localRequest = 0;

  @override
  void initState() {
    super.initState();
    _connect(null);
    _loadLocal();
  }

  @override
  void dispose() {
    _remoteRequest++;
    _localRequest++;
    _client?.dispose();
    super.dispose();
  }

  Future<void> _connect(String? password) async {
    setState(() {
      _remoteLoading = true;
      _remoteError = null;
    });
    try {
      final client = await widget.createClient(password);
      if (!mounted) {
        client.dispose();
        return;
      }
      _client?.dispose();
      _client = client;
      final home = await client.home();
      if (!mounted || _client != client) return;
      await _loadRemote(home);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _remoteLoading = false;
        _remoteError = '$error';
      });
    }
  }

  Future<void> _loadRemote([String? path]) async {
    final client = _client;
    if (client == null) return;
    final request = ++_remoteRequest;
    final target = path ?? _remotePath;
    setState(() {
      _remoteLoading = true;
      _remoteError = null;
    });
    try {
      final entries = await client.list(target);
      if (!mounted || request != _remoteRequest) return;
      setState(() {
        _remotePath = target;
        _remoteEntries = entries;
        _selectedRemote = null;
        _remoteLoading = false;
      });
    } catch (error) {
      if (!mounted || request != _remoteRequest) return;
      setState(() {
        _remoteError = '$error';
        _remoteLoading = false;
      });
    }
  }

  Future<void> _loadLocal([String? path]) async {
    final request = ++_localRequest;
    final target = path ?? _localPath;
    setState(() {
      _localLoading = true;
      _localError = null;
    });
    try {
      final entries = await _local.list(target);
      if (!mounted || request != _localRequest) return;
      setState(() {
        _localPath = target;
        _localEntries = entries;
        _selectedLocal = null;
        _localLoading = false;
      });
    } catch (error) {
      if (!mounted || request != _localRequest) return;
      setState(() {
        _localError = '$error';
        _localLoading = false;
      });
    }
  }

  Future<bool> _confirmOverwrite(String name) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(tr('Replace file?')),
            content: Text(
              tr('File {name} already exists at the destination.', {
                'name': name,
              }),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(tr('Cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(tr('Replace')),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _transfer({required bool upload}) async {
    final client = _client;
    final name = upload ? _selectedLocal : _selectedRemote;
    if (client == null || name == null || _busy) return;
    final valid = upload
        ? _localEntries.any((e) => e.name == name && !e.isDirectory)
        : _remoteEntries.any((e) => e.name == name && !e.isDirectory);
    if (!valid) return;
    final exists = upload
        ? _remoteEntries.any((e) => e.name == name)
        : _localEntries.any((e) => e.name == name);
    if (exists && !await _confirmOverwrite(name)) return;
    if (!mounted) return;
    final item = _Transfer(name, upload ? Icons.upload_rounded : Icons.download_rounded);
    setState(() {
      _busy = true;
      _transfers.insert(0, item);
    });
    try {
      if (upload) {
        await client.upload(
          _local.join(_localPath, name),
          OpenSshSftpClient.joinRemote(_remotePath, name),
        );
        await _loadRemote();
      } else {
        await client.download(
          OpenSshSftpClient.joinRemote(_remotePath, name),
          _local.join(_localPath, name),
        );
        await _loadLocal();
      }
      item.status = 'Completed';
    } catch (error) {
      item.status = 'Failed';
      item.error = '$error';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _newFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('New remote folder')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: tr('Name')),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(tr('Create')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null ||
        name.trim().isEmpty ||
        name.contains('/') ||
        name == '.' ||
        name == '..' ||
        !mounted) {
      return;
    }
    try {
      await _client!.mkdir(
        OpenSshSftpClient.joinRemote(_remotePath, name.trim()),
      );
      await _loadRemote();
    } catch (error) {
      if (mounted) setState(() => _remoteError = '$error');
    }
  }

  Future<void> _askPassword() async {
    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('SFTP password')),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: InputDecoration(labelText: tr('Password')),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(tr('Connect')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (password != null && mounted) await _connect(password);
  }

  bool get _canDownload =>
      !_busy &&
      _selectedRemote != null &&
      _remoteEntries.any((e) => e.name == _selectedRemote && !e.isDirectory);

  bool get _canUpload =>
      !_busy &&
      _selectedLocal != null &&
      _localEntries.any((e) => e.name == _selectedLocal && !e.isDirectory);

  /// The remote files over the whole app window, beside this computer's, as
  /// in a file manager. The window can be resized as usual.
  Future<void> _openWide() => showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black26,
    pageBuilder: (context, _, _) => _WideSftp(
      createClient: widget.createClient,
      localBrowser: widget.localBrowser,
    ),
  );

  Widget _remoteSection() => Column(
    children: [
      _panelHeader(
        tr('Remote files'),
        _remotePath.isEmpty ? '/' : _remotePath,
        up: _remotePath.isEmpty || _remotePath == '/'
            ? null
            : () => _loadRemote(OpenSshSftpClient.parentRemote(_remotePath)),
        refresh: _client == null ? null : () => _loadRemote(),
        extra: _client == null ? null : _newFolder,
        expand: widget.wide ? null : (widget.onExpand ?? _openWide),
        close: widget.wide ? null : widget.onClose,
      ),
      Expanded(
            child: _remoteLoading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _remoteError != null
                ? _errorView(_remoteError!, remote: true)
                : _fileList(
                    _remoteEntries
                        .map((e) => (e.name, e.isDirectory, e.size))
                        .toList(),
                    selected: _selectedRemote,
                    onSelect: (name) => setState(() => _selectedRemote = name),
                    onOpen: (name) => _loadRemote(
                      OpenSshSftpClient.joinRemote(_remotePath, name),
                    ),
                  ),
      ),
    ],
  );

  Widget _localSection() => Column(
    children: [
      _panelHeader(
        tr('Local files'),
        _localPath,
        up: () => _loadLocal(_local.parent(_localPath)),
        refresh: () => _loadLocal(),
      ),
      Expanded(
            child: _localLoading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _localError != null
                ? _errorView(_localError!, remote: false)
                : _fileList(
                    _localEntries
                        .map((e) => (e.name, e.isDirectory, e.size))
                        .toList(),
                    selected: _selectedLocal,
                    onSelect: (name) => setState(() => _selectedLocal = name),
                    onOpen: (name) => _loadLocal(_local.join(_localPath, name)),
                  ),
      ),
    ],
  );

  Widget _downloadButton({required bool wide}) => OutlinedButton.icon(
    key: const ValueKey('sftp-download'),
    style: _barButton,
    onPressed: _canDownload ? () => _transfer(upload: false) : null,
    icon: Icon(wide ? Icons.arrow_back_rounded : Icons.download_rounded, size: 16),
    label: Text(tr('Download')),
  );

  Widget _uploadButton({required bool wide}) => ElevatedButton.icon(
    key: const ValueKey('sftp-upload'),
    style: _barButton,
    onPressed: _canUpload ? () => _transfer(upload: true) : null,
    icon: Icon(wide ? Icons.arrow_forward_rounded : Icons.upload_rounded, size: 16),
    label: Text(tr('Upload')),
  );

  Widget _transfersBox() =>
          SizedBox(
            height: 98,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: Text(
                    tr('Transfers').toUpperCase(),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                      color: Theme.of(context).textTheme.bodySmall?.color,
                    ),
                  ),
                ),
                Expanded(
                  child: _transfers.isEmpty
                      ? Center(
                          child: Text(
                            tr('No transfers yet'),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        )
                      : ListView.builder(
                          itemCount: _transfers.length,
                          itemBuilder: (context, index) {
                            final item = _transfers[index];
                            return Tooltip(
                              message: item.error ?? tr(item.status),
                              child: SizedBox(
                                height: 24,
                                child: Row(
                                  children: [
                                    const SizedBox(width: 12),
                                    Icon(item.direction, size: 14),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        item.name,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                    ),
                                    if (item.status == 'Transferring')
                                      const SizedBox(
                                        width: 12,
                                        height: 12,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    else
                                      Icon(
                                        item.status == 'Completed'
                                            ? Icons.check_circle_rounded
                                            : Icons.error_rounded,
                                        size: 13,
                                        color: item.status == 'Completed'
                                            ? const Color(0xFF2EB85C)
                                            : Theme.of(context).colorScheme.error,
                                      ),
                                    const SizedBox(width: 5),
                                    Text(
                                      tr(item.status),
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                    const SizedBox(width: 10),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          );

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final panel = isDark ? AppColors.darkPanel : AppColors.lightPanel;
    if (widget.wide) {
      // This computer on the left, the device on the right, the buttons
      // between them pointing the way the file goes.
      return Material(
        color: panel,
        child: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(child: _localSection()),
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: 132,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _uploadButton(wide: true),
                          const SizedBox(height: 8),
                          _downloadButton(wide: true),
                        ],
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: _remoteSection()),
                ],
              ),
            ),
            const Divider(height: 1),
            _transfersBox(),
          ],
        ),
      );
    }
    return Material(
      color: panel,
      child: Column(
        children: [
          Expanded(child: _remoteSection()),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                Expanded(child: _downloadButton(wide: false)),
                const SizedBox(width: 8),
                Expanded(child: _uploadButton(wide: false)),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _localSection()),
          const Divider(height: 1),
          _transfersBox(),
        ],
      ),
    );
  }

  Widget _errorView(String error, {required bool remote}) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.error_rounded, color: Theme.of(context).colorScheme.error),
        const SizedBox(height: 6),
        Text(
          error,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11),
        ),
        const SizedBox(height: 6),
        TextButton(
          onPressed: remote ? () => _connect(null) : () => _loadLocal(),
          child: Text(tr('Try again')),
        ),
        if (remote)
          TextButton(
            onPressed: _askPassword,
            child: Text(tr('Use SFTP password')),
          ),
      ],
    ),
  );

  /// The panel's two buttons, as compact as the rest of the panel.
  static final _barButton = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(0, 30)),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
  );

  Widget _panelHeader(
    String title,
    String path, {
    VoidCallback? up,
    VoidCallback? refresh,
    VoidCallback? extra,
    VoidCallback? expand,
    VoidCallback? close,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dim = isDark ? AppColors.darkTextDim : AppColors.lightTextDim;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title.toUpperCase(),
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: dim),
              ),
              const Spacer(),
              if (extra != null)
                ToolButton(icon: Icons.create_new_folder_rounded, tooltip: tr('New remote folder'), onPressed: extra, size: 26),
              ToolButton(icon: Icons.arrow_upward_rounded, tooltip: tr('Parent folder'), onPressed: up, size: 26),
              ToolButton(icon: Icons.refresh_rounded, tooltip: tr('Refresh'), onPressed: refresh, size: 26),
              if (expand != null)
                ToolButton(icon: Icons.open_in_full_rounded, tooltip: tr('Expand'), onPressed: expand, size: 26),
              if (close != null)
                ToolButton(icon: Icons.close_rounded, tooltip: tr('Close SFTP'), onPressed: close, size: 26),
            ],
          ),
          const SizedBox(height: 2),
          Text(path, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: dim)),
        ],
      ),
    );
  }

  Widget _fileList(
    List<(String, bool, int)> entries, {
    required String? selected,
    required ValueChanged<String> onSelect,
    required ValueChanged<String> onOpen,
  }) {
    if (entries.isEmpty) {
      return Center(child: Text(tr('This folder is empty.')));
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 4),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final (name, folder, size) = entries[index];
        return _FileRow(
          key: ValueKey('sftp-entry-$name'),
          name: name,
          folder: folder,
          size: folder ? null : _size(size),
          selected: selected == name,
          onSelect: () => onSelect(name),
          onOpen: folder ? () => onOpen(name) : null,
        );
      },
    );
  }

  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// One file or folder, drawn like a row of the connection panel: a rounded,
/// neutral highlight with the selection pill, and a single-colour icon.
class _FileRow extends StatefulWidget {
  const _FileRow({
    super.key,
    required this.name,
    required this.folder,
    required this.size,
    required this.selected,
    required this.onSelect,
    required this.onOpen,
  });

  final String name;
  final bool folder;
  final String? size;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback? onOpen;

  @override
  State<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends State<_FileRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final text = isDark ? AppColors.darkText : AppColors.lightText;
    final dim = isDark ? AppColors.darkTextDim : AppColors.lightTextDim;
    final overlay = isDark ? Colors.white : Colors.black;
    final background = widget.selected
        ? overlay.withValues(alpha: isDark ? 0.11 : 0.075)
        : _hover
        ? overlay.withValues(alpha: isDark ? 0.06 : 0.04)
        : Colors.transparent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSelect,
        onDoubleTap: widget.onOpen,
        child: Container(
          height: 28,
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(4)),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 14,
                margin: const EdgeInsets.only(right: 7),
                decoration: BoxDecoration(
                  color: widget.selected ? text : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Icon(
                widget.folder ? Icons.folder_rounded : Icons.description_outlined,
                size: 16,
                color: widget.folder ? text : dim,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: text, fontWeight: widget.folder ? FontWeight.w500 : null),
                ),
              ),
              if (widget.size != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(widget.size!, style: TextStyle(fontSize: 11, color: dim)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The file manager view: a bar with the way back, then both sides.
class _WideSftp extends StatelessWidget {
  const _WideSftp({required this.createClient, required this.localBrowser});
  final SftpClientFactory createClient;
  final LocalFileBrowser? localBrowser;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dim = isDark ? AppColors.darkTextDim : AppColors.lightTextDim;
    return Material(
      color: isDark ? AppColors.darkBg : AppColors.lightBg,
      child: Column(
        children: [
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
            child: Row(
              children: [
                Icon(Icons.folder_rounded, size: 16, color: dim),
                const SizedBox(width: 8),
                const Text('SFTP', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const Spacer(),
                ToolButton(
                  key: const ValueKey('sftp-shrink'),
                  icon: Icons.close_fullscreen_rounded,
                  tooltip: tr('Shrink'),
                  onPressed: () => Navigator.of(context).pop(),
                  size: 28,
                ),
              ],
            ),
          ),
          Expanded(child: SftpBrowser(createClient: createClient, localBrowser: localBrowser, wide: true)),
        ],
      ),
    );
  }
}
