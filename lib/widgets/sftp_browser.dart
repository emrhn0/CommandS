import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/strings.dart';
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
  const SftpBrowser({super.key, required this.createClient, this.localBrowser});
  final SftpClientFactory createClient;
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
    final item = _Transfer(name, upload ? Icons.upload : Icons.download);
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: Column(
        children: [
          _panelHeader(
            tr('Remote files'),
            _remotePath.isEmpty ? '/' : _remotePath,
            up: _remotePath.isEmpty || _remotePath == '/'
                ? null
                : () =>
                      _loadRemote(OpenSshSftpClient.parentRemote(_remotePath)),
            refresh: _client == null ? null : () => _loadRemote(),
            extra: _client == null ? null : _newFolder,
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
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('sftp-download'),
                    onPressed:
                        !_busy &&
                            _selectedRemote != null &&
                            _remoteEntries.any(
                              (e) =>
                                  e.name == _selectedRemote && !e.isDirectory,
                            )
                        ? () => _transfer(upload: false)
                        : null,
                    icon: const Icon(Icons.download, size: 16),
                    label: Text(tr('Download')),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('sftp-upload'),
                    onPressed:
                        !_busy &&
                            _selectedLocal != null &&
                            _localEntries.any(
                              (e) => e.name == _selectedLocal && !e.isDirectory,
                            )
                        ? () => _transfer(upload: true)
                        : null,
                    icon: const Icon(Icons.upload, size: 16),
                    label: Text(tr('Upload')),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
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
          const Divider(height: 1),
          SizedBox(
            height: 98,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 5, 10, 3),
                  child: Text(
                    tr('Transfers'),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
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
                                    const SizedBox(width: 10),
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
                                            ? Icons.check_circle_outline
                                            : Icons.error_outline,
                                        size: 13,
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
          ),
        ],
      ),
    );
  }

  Widget _errorView(String error, {required bool remote}) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
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

  Widget _panelHeader(
    String title,
    String path, {
    VoidCallback? up,
    VoidCallback? refresh,
    VoidCallback? extra,
  }) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          Row(
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              if (extra != null)
                IconButton(
                  icon: const Icon(Icons.create_new_folder_outlined, size: 17),
                  tooltip: tr('New remote folder'),
                  onPressed: extra,
                  visualDensity: VisualDensity.compact,
                ),
              IconButton(
                icon: const Icon(Icons.arrow_upward, size: 16),
                tooltip: tr('Parent folder'),
                onPressed: up,
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 16),
                tooltip: tr('Refresh'),
                onPressed: refresh,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10),
            ),
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
  }) {
    if (entries.isEmpty) {
      return Center(child: Text(tr('This folder is empty.')));
    }
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final (name, folder, size) = entries[index];
        return InkWell(
          key: ValueKey('sftp-entry-$name'),
          onTap: () => onSelect(name),
          onDoubleTap: folder ? () => onOpen(name) : null,
          child: Container(
            height: 27,
            color: selected == name
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
            padding: const EdgeInsets.symmetric(horizontal: 9),
            child: Row(
              children: [
                Icon(
                  folder ? Icons.folder : Icons.insert_drive_file_outlined,
                  size: 16,
                  color: folder ? Colors.amber.shade700 : null,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
                if (!folder)
                  Text(_size(size), style: const TextStyle(fontSize: 10)),
              ],
            ),
          ),
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
