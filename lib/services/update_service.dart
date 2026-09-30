import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_version.dart';

/// Checks GitHub for a newer CommandS release and, on Windows, installs it.
///
/// The repository is public, so the releases API is reachable without a token
/// — which matters, because there is no credential this app could ship that
/// wouldn't also be handed to everyone who installs it. Unauthenticated
/// requests are rate-limited per IP (60/hour); one check per launch, with a
/// floor between checks, stays far inside that.
class UpdateService {
  static const _owner = 'emrhn0';
  static const _repo = 'CommandS';
  static const _latestUrl =
      'https://api.github.com/repos/$_owner/$_repo/releases/latest';

  /// GitHub rejects API requests without one.
  static const _userAgent = 'CommandS-Updater';

  /// Published by the release workflow: one `<sha256>  <filename>` line per
  /// build. Releases made before this file existed simply don't have it.
  static const _checksumsAsset = 'SHA256SUMS.txt';

  static const _kSkippedVersion = 'commands.update.skippedVersion';
  static const _kLastCheck = 'commands.update.lastCheckMs';

  /// Only one check per launch anyway; this stops a user who restarts the app
  /// repeatedly from spending the hour's unauthenticated quota.
  static const _minCheckInterval = Duration(hours: 4);

  /// Looks for a release newer than [appVersion].
  ///
  /// Returns null when there is nothing to offer — already current, the user
  /// chose to skip this version, checked too recently, or the network/API
  /// didn't cooperate. A failed update check is never worth interrupting
  /// someone over, so every failure here is silent.
  static Future<UpdateInfo?> check({bool force = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!force) {
        final last = prefs.getInt(_kLastCheck) ?? 0;
        final since = DateTime.now().millisecondsSinceEpoch - last;
        if (since < _minCheckInterval.inMilliseconds) return null;
      }

      final release = await _fetchJson(_latestUrl);
      if (release == null) return null;
      await prefs.setInt(_kLastCheck, DateTime.now().millisecondsSinceEpoch);

      final tag = release['tag_name'] as String?;
      if (tag == null || tag.isEmpty) return null;
      if (release['draft'] == true || release['prerelease'] == true) return null;
      if (compareVersions(tag, appVersion) <= 0) return null;
      if (!force && prefs.getString(_kSkippedVersion) == tag) return null;

      final assets = (release['assets'] as List?) ?? const [];
      final asset = _pickAsset(assets);

      return UpdateInfo(
        version: tag,
        releaseUrl: release['html_url'] as String? ??
            'https://github.com/$_owner/$_repo/releases/latest',
        notes: (release['body'] as String? ?? '').trim(),
        assetName: asset?.name,
        assetUrl: asset?.url,
        assetSize: asset?.size ?? 0,
        checksumsUrl: _findAssetUrl(assets, _checksumsAsset),
      );
    } catch (_) {
      return null;
    }
  }

  /// Remembers that the user does not want to be asked about [version] again.
  /// A later release still prompts.
  static Future<void> skip(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSkippedVersion, version);
  }

  /// The build for this platform. Windows gets the installer (per-user, so it
  /// never raises a UAC prompt); macOS gets the zipped app, which is handed to
  /// the browser rather than installed, since replacing a running .app from
  /// inside itself is not something to do quietly.
  static String? _findAssetUrl(List<dynamic> assets, String name) {
    for (final raw in assets) {
      if (raw is! Map) continue;
      if ((raw['name'] as String?)?.toLowerCase() == name.toLowerCase()) {
        return raw['browser_download_url'] as String?;
      }
    }
    return null;
  }

  static _Asset? _pickAsset(List<dynamic> assets) {
    bool matches(String name) {
      final lower = name.toLowerCase();
      if (Platform.isWindows) return lower.endsWith('setup.exe');
      if (Platform.isMacOS) return lower.endsWith('macos.zip');
      return false;
    }

    for (final raw in assets) {
      if (raw is! Map) continue;
      final name = raw['name'] as String?;
      final url = raw['browser_download_url'] as String?;
      if (name == null || url == null || !matches(name)) continue;
      return _Asset(name, url, (raw['size'] as num?)?.toInt() ?? 0);
    }
    return null;
  }

  /// Compares `vX.Y.Z` strings. Returns >0 when [a] is newer than [b].
  /// Anything unparseable in a segment counts as 0, so a malformed tag can
  /// never be read as newer than a real version.
  static int compareVersions(String a, String b) {
    List<int> parts(String v) {
      final cleaned = v.trim().toLowerCase();
      final body = cleaned.startsWith('v') ? cleaned.substring(1) : cleaned;
      // Drop any pre-release/build suffix: only the numeric core is compared.
      final core = body.split(RegExp(r'[-+]')).first;
      final out = core.split('.').map((s) => int.tryParse(s) ?? 0).toList();
      while (out.length < 3) {
        out.add(0);
      }
      return out;
    }

    final x = parts(a);
    final y = parts(b);
    for (var i = 0; i < 3; i++) {
      if (x[i] != y[i]) return x[i] - y[i];
    }
    return 0;
  }

  static Future<Map<String, dynamic>?> _fetchJson(String url) async {
    final body = await _fetch(url, accept: 'application/vnd.github+json');
    if (body == null) return null;
    final decoded = jsonDecode(utf8.decode(body));
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  /// One redirect-following GET. `dart:io`'s client is used rather than adding
  /// an HTTP package for two requests.
  static Future<List<int>?> _fetch(String url, {String? accept}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      var target = Uri.parse(url);
      for (var redirects = 0; redirects < 5; redirects++) {
        final request = await client.getUrl(target);
        request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
        if (accept != null) request.headers.set(HttpHeaders.acceptHeader, accept);
        request.followRedirects = false;
        final response = await request.close();
        if (response.isRedirect) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.drain<void>();
          if (location == null) return null;
          target = target.resolve(location);
          continue;
        }
        if (response.statusCode != 200) {
          await response.drain<void>();
          return null;
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
        }
        return bytes;
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Downloads [info]'s installer and hands over to it.
  ///
  /// Windows only. The installer is the one published alongside the release,
  /// fetched over HTTPS from GitHub; it installs per-user into
  /// `%LOCALAPPDATA%\Programs\CommandS`, so it asks for no elevation, and it
  /// is run through a detached `cmd` that waits for it to finish and then
  /// starts the new build — this process has to exit for its own files to be
  /// replaced, so it cannot do the relaunch itself.
  ///
  /// [onProgress] reports 0..1, or null when the server sends no length.
  /// Returns an error string, or null once the installer has been handed off
  /// (at which point the caller should quit the app).
  static Future<String?> downloadAndInstall(
    UpdateInfo info, {
    void Function(double? progress)? onProgress,
  }) async {
    if (!Platform.isWindows) return 'Automatic install is Windows-only.';
    final url = info.assetUrl;
    if (url == null) return 'This release has no Windows installer.';

    Directory? dir;
    try {
      dir = await Directory.systemTemp.createTemp('commands_update_');
      final file = File('${dir.path}\\${info.assetName ?? 'CommandS_Setup.exe'}');
      final ok = await _download(url, file, onProgress);
      if (!ok) return 'The download did not complete.';

      final size = await file.length();
      // A truncated download, or an error page saved as if it were the
      // installer, would otherwise be executed. The release API already told
      // us how big the asset is, so a mismatch means this is not it.
      if (info.assetSize > 0 && size != info.assetSize) {
        return 'The downloaded installer is incomplete.';
      }
      if (size < 1024 * 1024) return 'The downloaded installer looks wrong.';

      // This method ends by running the file it just downloaded, so matching
      // the checksum published with the release is worth the extra request:
      // size alone would not notice a substituted file of the same length.
      // Releases predating SHA256SUMS.txt have none to check against, and are
      // accepted on the size check alone rather than made un-updatable.
      final expected = await _expectedChecksum(info);
      if (expected != null) {
        final actual = sha256.convert(await file.readAsBytes()).toString();
        if (actual.toLowerCase() != expected.toLowerCase()) {
          return 'The downloaded installer failed its checksum and was not run.';
        }
      }

      final installerPath = file.path;
      final appDir = Platform.resolvedExecutable;
      // /SILENT shows a progress window but asks nothing; CLOSEAPPLICATIONS
      // lets the installer replace files belonging to this app once it exits;
      // NORESTART keeps it from ever rebooting the machine.
      final command = '"$installerPath" /SILENT /CLOSEAPPLICATIONS /NORESTART '
          '&& start "" "$appDir"';
      await Process.start(
        'cmd.exe',
        ['/c', command],
        mode: ProcessStartMode.detached,
        runInShell: false,
      );
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  static Future<bool> _download(
    String url,
    File target,
    void Function(double? progress)? onProgress,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    IOSink? sink;
    try {
      var uri = Uri.parse(url);
      for (var redirects = 0; redirects < 5; redirects++) {
        final request = await client.getUrl(uri);
        request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
        request.followRedirects = false;
        final response = await request.close();
        if (response.isRedirect) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.drain<void>();
          if (location == null) return false;
          uri = uri.resolve(location);
          continue;
        }
        if (response.statusCode != 200) {
          await response.drain<void>();
          return false;
        }
        final total = response.contentLength;
        var received = 0;
        sink = target.openWrite();
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(total > 0 ? received / total : null);
        }
        await sink.flush();
        await sink.close();
        sink = null;
        return true;
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client.close(force: true);
    }
  }

  /// Opens the release page in the user's browser — the macOS path, and the
  /// fallback anywhere the installer could not be run.
  static Future<void> openReleasePage(UpdateInfo info) async {
    try {
      if (Platform.isWindows) {
        await Process.start('cmd.exe', ['/c', 'start', '', info.releaseUrl],
            mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.start('/usr/bin/open', [info.releaseUrl],
            mode: ProcessStartMode.detached);
      }
    } catch (_) {
      // Nothing useful to do if the OS won't open a browser.
    }
  }

  /// The hash the release published for [info]'s installer, or null when the
  /// release has no checksum file or does not list this asset in it.
  static Future<String?> _expectedChecksum(UpdateInfo info) async {
    final url = info.checksumsUrl;
    final name = info.assetName;
    if (url == null || name == null) return null;
    final bytes = await _fetch(url);
    if (bytes == null) return null;
    for (final line in const LineSplitter().convert(utf8.decode(bytes))) {
      // `sha256sum` format: the hash, whitespace, an optional binary marker,
      // then the file name.
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final fileName = parts.last.replaceFirst(RegExp(r'^\*'), '');
      if (fileName == name) return parts.first;
    }
    return null;
  }
}

class _Asset {
  const _Asset(this.name, this.url, this.size);
  final String name;
  final String url;
  final int size;
}

/// A release newer than the running build.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.releaseUrl,
    required this.notes,
    required this.assetName,
    required this.assetUrl,
    required this.assetSize,
    required this.checksumsUrl,
  });

  /// The release tag, e.g. `v1.0.26`.
  final String version;
  final String releaseUrl;

  /// The release notes, as written on GitHub.
  final String notes;

  /// The build for this platform, if the release published one.
  final String? assetName;
  final String? assetUrl;
  final int assetSize;

  /// Where the release published its `SHA256SUMS.txt`, if it did.
  final String? checksumsUrl;

  /// Whether this app can install the update itself, rather than sending the
  /// user to a download page.
  bool get canSelfInstall => Platform.isWindows && assetUrl != null;

  String get sizeLabel {
    if (assetSize <= 0) return '';
    final mb = assetSize / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }
}
