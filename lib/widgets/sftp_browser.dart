import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../theme/app_theme.dart';
import 'tool_button.dart';
import '../services/sftp_client.dart';
import '../services/sftp_transfer.dart';

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
  Future<void> mkdir(String path);
}

/// The last part of a local path, as written: a name with "%" in it is a
/// name, not URL encoding to undo, which is what broke on such folders.
String baseName(String path) {
  var end = path.length;
  while (end > 0 && (path[end - 1] == '\\' || path[end - 1] == '/')) {
    end--;
  }
  final cut = path.lastIndexOf(RegExp(r'[\\/]'), end - 1);
  return path.substring(cut + 1, end);
}

class DiskFileBrowser implements LocalFileBrowser {
  @override
  Future<void> mkdir(String path) async {
    if (await FileSystemEntity.type(path) != FileSystemEntityType.notFound) {
      throw FileSystemException('Folder already exists', path);
    }
    await Directory(path).create();
  }

  @override
  String get initialPath => Platform.isWindows
      ? (Platform.environment['USERPROFILE'] ?? Directory.current.path)
      : (Platform.environment['HOME'] ?? Directory.current.path);

  @override
  String parent(String path) => Directory(path).parent.path;

  @override
  String join(String path, String name) {
    final sep = Platform.pathSeparator;
    // A drive's root already ends in one: "C:\\" + "Users", not "C:\\\\Users".
    return path.endsWith(sep) || path.endsWith('/')
        ? '$path$name'
        : '$path$sep$name';
  }

  @override
  Future<List<LocalFileEntry>> list(String path) async {
    final result = <LocalFileEntry>[];
    // Entries this user may not open (Windows keeps a few under C:\\Users)
    // are left out, rather than failing the whole folder.
    final listing = Directory(path)
        .list(followLinks: false)
        .handleError((Object _) {});
    await for (final entity in listing) {
      try {
        final type = await FileSystemEntity.type(
          entity.path,
          followLinks: false,
        );
        if (type != FileSystemEntityType.directory &&
            type != FileSystemEntityType.file) {
          continue;
        }
        final size = type == FileSystemEntityType.file
            ? await File(entity.path).length()
            : 0;
        result.add(
          LocalFileEntry(
            baseName(entity.path),
            isDirectory: type == FileSystemEntityType.directory,
            size: size,
          ),
        );
      } on FileSystemException {
        continue;
      }
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
  const SftpBrowser({super.key, required this.createClient, this.localBrowser, this.onClose, this.onExpand, this.wide = false, this.transfers});
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
  final List<SftpTransfer>? transfers;

  @override
  State<SftpBrowser> createState() => _SftpBrowserState();
}

class _SftpBrowserState extends State<SftpBrowser> {
  late final LocalFileBrowser _local = widget.localBrowser ?? DiskFileBrowser();
  late String _localPath = _local.initialPath;
  String _remotePath = '';
  List<LocalFileEntry> _localEntries = [];
  List<SftpEntry> _remoteEntries = [];
  late final List<SftpTransfer> _transfers = widget.transfers ?? [];
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
    final item = SftpTransfer(name, upload ? 'upload' : 'download');
    setState(() {
      _busy = true;
      _transfers.insert(0, item);
    });
    try {
      void updateProgress(SftpProgress progress) {
        if (!mounted) return;
        setState(() {
          item.progress = progress;
          item.status = progress.verifying
              ? 'Verifying SHA-256'
              : 'Transferring';
        });
      }

      if (upload) {
        await client.upload(
          _local.join(_localPath, name),
          OpenSshSftpClient.joinRemote(_remotePath, name),
          onProgress: updateProgress,
        );
        await _loadRemote();
      } else {
        await client.download(
          OpenSshSftpClient.joinRemote(_remotePath, name),
          _local.join(_localPath, name),
          onProgress: updateProgress,
        );
        await _loadLocal();
      }
      item.status = 'Verified';
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

  Future<void> _newLocalFolder() async {
    var draft = '';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('New local folder')),
        content: TextField(
          autofocus: true,
          decoration: InputDecoration(labelText: tr('Name')),
          onChanged: (value) => draft = value,
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, draft), child: Text(tr('Create'))),
        ],
      ),
    );
    if (name == null || !mounted) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == '.' || trimmed == '..' || trimmed.contains(RegExp(r'[\\/]'))) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Invalid folder name'))));
      return;
    }
    try {
      await _local.mkdir(_local.join(_localPath, trimmed));
      await _loadLocal();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
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
      transfers: _transfers,
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
        expand: widget.wide || _busy ? null : (widget.onExpand ?? _openWide),
        close: widget.wide ? null : widget.onClose,
        onPath: _client == null
            ? null
            : (p) => _loadRemote(p.isEmpty ? '/' : p),
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
                onUp: _remotePath.isEmpty || _remotePath == '/'
                    ? null
                    : () => _loadRemote(
                        OpenSshSftpClient.parentRemote(_remotePath),
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
        extra: _newLocalFolder,
        extraTooltip: tr('New local folder'),
        onPath: _goLocal,
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
                onUp: () => _loadLocal(_local.parent(_localPath)),
              ),
      ),
    ],
  );

  Widget _downloadButton({required bool wide}) => OutlinedButton.icon(
    key: const ValueKey('sftp-download'),
    style: _barButton,
    onPressed: _canDownload ? () => _transfer(upload: false) : null,
    icon: Icon(
      wide ? Icons.arrow_back_rounded : Icons.download_rounded,
      size: 16,
    ),
    label: Text(tr('Download')),
  );

  Widget _uploadButton({required bool wide}) => ElevatedButton.icon(
    key: const ValueKey('sftp-upload'),
    style: _barButton,
    onPressed: _canUpload ? () => _transfer(upload: true) : null,
    icon: Icon(
      wide ? Icons.arrow_forward_rounded : Icons.upload_rounded,
      size: 16,
    ),
    label: Text(tr('Upload')),
  );

  Widget _transfersBox() => SizedBox(
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
                            Icon(
                              item.direction == 'upload'
                                  ? Icons.upload_rounded
                                  : Icons.download_rounded,
                              size: 14,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                item.name,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                            if (item.status == 'Transferring' ||
                                item.status == 'Verifying SHA-256')
                              const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            else
                              Icon(
                                item.status == 'Verified'
                                    ? Icons.check_circle_rounded
                                    : Icons.error_rounded,
                                size: 13,
                                color: item.status == 'Verified'
                                    ? const Color(0xFF2EB85C)
                                    : Theme.of(context).colorScheme.error,
                              ),
                            const SizedBox(width: 5),
                            Text(
                              item.status == 'Transferring' &&
                                      item.progress != null
                                  ? '${item.progress!.total == 0 ? _size(item.progress!.bytes) : '${(100 * item.progress!.bytes / item.progress!.total).clamp(0, 100).floor()}%'} · ${_size(item.progress!.bytesPerSecond.round())}/s'
                                  : tr(item.status),
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
    final panel = AppPalette.of(context).panel;
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
    String? extraTooltip,
    VoidCallback? expand,
    VoidCallback? close,
    ValueChanged<String>? onPath,
  }) {
    final dim = AppPalette.of(context).textDim;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title.toUpperCase(),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                  color: dim,
                ),
              ),
              const Spacer(),
              if (extra != null)
                ToolButton(icon: Icons.create_new_folder_rounded, tooltip: extraTooltip ?? tr('New remote folder'), onPressed: extra, size: 26),
              ToolButton(icon: Icons.arrow_upward_rounded, tooltip: tr('Parent folder'), onPressed: up, size: 26),
              ToolButton(icon: Icons.refresh_rounded, tooltip: tr('Refresh'), onPressed: refresh, size: 26),
              if (expand != null)
                ToolButton(
                  icon: Icons.open_in_full_rounded,
                  tooltip: tr('Expand'),
                  onPressed: expand,
                  size: 26,
                ),
              if (close != null)
                ToolButton(
                  icon: Icons.close_rounded,
                  tooltip: tr('Close SFTP'),
                  onPressed: close,
                  size: 26,
                ),
            ],
          ),
          const SizedBox(height: 2),
          _PathField(
            key: ValueKey('path-$title'),
            path: path,
            onSubmit: onPath,
          ),
        ],
      ),
    );
  }

  Widget _fileList(
    List<(String, bool, int)> entries, {
    required String? selected,
    required ValueChanged<String> onSelect,
    required ValueChanged<String> onOpen,
    VoidCallback? onUp,
  }) {
    if (entries.isEmpty) {
      return Center(child: Text(tr('This folder is empty.')));
    }
    return _FileList(
      entries: [
        for (final (name, folder, size) in entries)
          (name, folder, folder ? null : _size(size)),
      ],
      selected: selected,
      onSelect: onSelect,
      onOpen: onOpen,
      onUp: onUp,
    );
  }

  /// A pasted path: a folder opens; a file opens its folder with it selected.
  Future<void> _goLocal(String raw) async {
    final path = raw.trim().replaceAll('"', '');
    if (path.isEmpty) return;
    if (await File(path).exists()) {
      await _loadLocal(_local.parent(path));
      if (mounted) setState(() => _selectedLocal = baseName(path));
      return;
    }
    await _loadLocal(path);
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
    final text = AppPalette.of(context).text;
    final dim = AppPalette.of(context).textDim;
    final overlay = isDark ? Colors.white : Colors.black;
    final background = widget.selected
        ? overlay.withValues(alpha: isDark ? 0.11 : 0.075)
        : _hover
        ? overlay.withValues(alpha: isDark ? 0.06 : 0.04)
        : Colors.transparent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      // Selected the moment the button goes down, as in Explorer and the
      // connection list; a tap recognizer would wait out the double-click.
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) {
          if (e.buttons == kPrimaryButton) widget.onSelect();
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: widget.onOpen,
          child: Container(
            height: 28,
            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(4),
            ),
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
                  widget.folder
                      ? Icons.folder_rounded
                      : Icons.description_outlined,
                  size: 16,
                  color: widget.folder ? text : dim,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: text,
                      fontWeight: widget.folder ? FontWeight.w500 : null,
                    ),
                  ),
                ),
                if (widget.size != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      widget.size!,
                      style: TextStyle(fontSize: 11, color: dim),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The file manager view: a bar with the way back, then both sides.
class _WideSftp extends StatelessWidget {
  const _WideSftp({required this.createClient, required this.localBrowser, required this.transfers});
  final SftpClientFactory createClient;
  final LocalFileBrowser? localBrowser;
  final List<SftpTransfer> transfers;

  @override
  Widget build(BuildContext context) {
    final dim = AppPalette.of(context).textDim;
    return Material(
      color: AppPalette.of(context).bg,
      child: Column(
        children: [
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.folder_rounded, size: 16, color: dim),
                const SizedBox(width: 8),
                const Text(
                  'SFTP',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
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
          Expanded(child: SftpBrowser(createClient: createClient, localBrowser: localBrowser, wide: true, transfers: transfers)),
        ],
      ),
    );
  }
}

/// The folder's path, as text that can be edited: paste a path and press
/// Enter to go there, as in a file manager's address bar.
class _PathField extends StatefulWidget {
  const _PathField({super.key, required this.path, required this.onSubmit});
  final String path;
  final ValueChanged<String>? onSubmit;

  @override
  State<_PathField> createState() => _PathFieldState();
}

class _PathFieldState extends State<_PathField> {
  late final _controller = TextEditingController(text: widget.path);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Leaving the field without Enter puts the current path back.
    _focus.addListener(() {
      if (!_focus.hasFocus) _controller.text = widget.path;
      setState(() {});
    });
  }

  @override
  void didUpdateWidget(_PathField old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path && !_focus.hasFocus) {
      _controller.text = widget.path;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dim = AppPalette.of(context).textDim;
    final text = AppPalette.of(context).text;
    final overlay = isDark ? Colors.white : Colors.black;
    return SizedBox(
      height: 24,
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        enabled: widget.onSubmit != null,
        style: TextStyle(fontSize: 11.5, color: _focus.hasFocus ? text : dim),
        decoration: InputDecoration(
          isDense: true,
          filled: _focus.hasFocus,
          fillColor: overlay.withValues(alpha: isDark ? 0.08 : 0.05),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 5,
          ),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: BorderSide(color: overlay.withValues(alpha: 0.25)),
          ),
          hintText: tr('Type or paste a path'),
        ),
        onSubmitted: (value) {
          widget.onSubmit?.call(value.trim());
          _focus.unfocus();
        },
      ),
    );
  }
}

/// The rows of one side, with Explorer's keys: a letter jumps to the next name
/// starting with it (typed quickly, the next with those letters), the arrows
/// move, Enter opens a folder, Backspace goes up.
class _FileList extends StatefulWidget {
  const _FileList({
    required this.entries,
    required this.selected,
    required this.onSelect,
    required this.onOpen,
    required this.onUp,
  });

  /// Name, folder, size text.
  final List<(String, bool, String?)> entries;
  final String? selected;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onOpen;
  final VoidCallback? onUp;

  @override
  State<_FileList> createState() => _FileListState();
}

class _FileListState extends State<_FileList> {
  final _focus = FocusNode();
  final _scroll = ScrollController();
  static const _rowExtent = 30.0;
  String _typed = '';
  DateTime _typedAt = DateTime(0);

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  int get _index => widget.entries.indexWhere((e) => e.$1 == widget.selected);

  void _select(int index) {
    if (index < 0 || index >= widget.entries.length) return;
    widget.onSelect(widget.entries[index].$1);
    if (!_scroll.hasClients) return;
    final top = index * _rowExtent;
    final view = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + _rowExtent > _scroll.offset + view) {
      _scroll.jumpTo(
        (top + _rowExtent - view).clamp(0, _scroll.position.maxScrollExtent),
      );
    }
  }

  void _typeAhead(String char) {
    final now = DateTime.now();
    final again = now.difference(_typedAt) < const Duration(milliseconds: 800);
    _typedAt = now;
    _typed = again ? _typed + char : char;
    final names = [for (final e in widget.entries) e.$1.toLowerCase()];
    final n = names.length;
    // The same letter again moves on to the next name with it, as Explorer does.
    final cycling = _typed.split('').toSet().length == 1;
    final prefix = cycling ? _typed[0] : _typed;
    final start = cycling ? _index + 1 : 0;
    for (var i = 0; i < n; i++) {
      final at = (start + i) % n;
      if (names[at].startsWith(prefix)) {
        _select(at);
        return;
      }
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _select(_index < 0 ? 0 : _index + 1);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _select(_index < 0 ? 0 : _index - 1);
    } else if (key == LogicalKeyboardKey.home) {
      _select(0);
    } else if (key == LogicalKeyboardKey.end) {
      _select(widget.entries.length - 1);
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      final i = _index;
      if (i >= 0 && widget.entries[i].$2) widget.onOpen(widget.entries[i].$1);
    } else if (key == LogicalKeyboardKey.backspace) {
      widget.onUp?.call();
    } else {
      final char = event.character;
      if (char == null ||
          char.isEmpty ||
          char.trim().isEmpty ||
          char.codeUnitAt(0) < 32) {
        return KeyEventResult.ignored;
      }
      if (HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isAltPressed) {
        return KeyEventResult.ignored;
      }
      _typeAhead(char.toLowerCase());
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.only(bottom: 4),
        itemCount: widget.entries.length,
        itemExtent: _rowExtent,
        itemBuilder: (context, index) {
          final (name, folder, size) = widget.entries[index];
          return _FileRow(
            key: ValueKey('sftp-entry-$name'),
            name: name,
            folder: folder,
            size: size,
            selected: widget.selected == name,
            onSelect: () {
              _focus.requestFocus();
              widget.onSelect(name);
            },
            onOpen: folder ? () => widget.onOpen(name) : null,
          );
        },
      ),
    );
  }
}
