import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

import '../app_version.dart';

/// Checks GitHub for a newer CommandS release and, on Windows, installs it.
///
/// The repository is public, so the releases API is reachable without a token
/// — which matters, because there is no credential this app could ship that
/// wouldn't also be handed to everyone who installs it. Unauthenticated
/// requests are rate-limited per IP (60/hour); one check per launch stays well
/// inside that even for an office full of people behind one address, and a
/// check that does get refused fails silently like any other.
class UpdateService {
  static const _owner = 'emrhn0';
  static const _repo = 'CommandS';

  /// GitHub rejects API requests without one.
  static const _userAgent = 'CommandS-Updater';

  /// Published by the release workflow: one `<sha256>  <filename>` line per
  /// build. Releases made before this file existed simply don't have it.
  static const _checksumsAsset = 'SHA256SUMS.txt';

  static const _kSkippedVersion = 'commands.update.skippedVersion';

  /// The newer release found at launch, if any. Outlives the prompt: someone
  /// who answered "Remind me later" can still update from the button in the
  /// sidebar header without restarting the app to get the prompt back.
  static final available = ValueNotifier<UpdateInfo?>(null);

  /// Looks for a release newer than [appVersion]. Runs on every launch -- an
  /// earlier version only checked once every four hours, so "Remind me later"
  /// followed by a restart quietly did not remind.
  ///
  /// Returns null when there is nothing newer, or the network/API didn't
  /// cooperate: a failed update check is never worth interrupting someone
  /// over, so every failure here is silent. A version the user chose to skip
  /// is still returned; whether to prompt about it is [isSkipped]'s question.
  ///
  /// Normal releases, and betas too for someone who turned on "Receive beta
  /// updates" in Settings: whichever is newest and newer than this version.
  static Future<UpdateInfo?> check() async => (await checkNow()).info;

  /// [check], but distinguishing "nothing newer" from "could not find out",
  /// for the Settings page's "Check for updates", which has to tell the user
  /// which one happened.
  ///
  /// The tags come from the releases feed, a plain page that the API's limit
  /// of 60 requests an hour per network does not cover: an office of people
  /// checking every few minutes would run through that. The API is asked only
  /// once something newer has turned up, for its downloads.
  static Future<UpdateCheck> checkNow() async {
    try {
      final betas = await _chosenChannel() == ReleaseChannel.beta;
      final tags = await fetchTags();
      if (tags == null) return const UpdateCheck.failed();
      // Never an older one, a beta behind the version installed included.
      final candidates = {
        for (final tag in tags)
          if ((_stableTag.hasMatch(tag) || (betas && _betaTag.hasMatch(tag))) &&
              compareVersions(tag, appVersion) > 0)
            tag,
      }.toList()
        ..sort((a, b) => compareVersions(b, a));

      // The feed lists a tag as soon as it is pushed, while its release is
      // still a draft being built (or after a release was removed). Such a
      // tag is not an update yet, and not a failure either: the next one
      // down is tried, and with none left the copy is up to date.
      String? newest;
      Map<String, dynamic>? release;
      for (final tag in candidates) {
        final found = await fetchRelease(tag);
        if (found == null) return const UpdateCheck.failed();
        if (found['draft'] == true) continue;
        newest = tag;
        release = found;
        break;
      }
      if (newest == null || release == null) return const UpdateCheck.upToDate();
      final channel = _betaTag.hasMatch(newest) ? ReleaseChannel.beta : ReleaseChannel.stable;
      final assets = (release['assets'] as List?) ?? const [];
      final plan = await _plan(assets, newest, channel);

      return UpdateCheck.available(UpdateInfo(
        version: newest,
        channel: channel,
        releaseUrl: release['html_url'] as String? ??
            'https://github.com/$_owner/$_repo/releases/tag/$newest',
        notes: (release['body'] as String? ?? '').trim(),
        assetName: plan?.asset.name,
        assetUrl: plan?.asset.url,
        assetSize: plan?.asset.size ?? 0,
        checksumsUrl: _findAssetUrl(assets, _checksumsAsset),
        method: plan?.method,
      ));
    } catch (_) {
      return const UpdateCheck.failed();
    }
  }

  static final _stableTag = RegExp(r'^v\d+\.\d+\.\d+$');
  static final _betaTag = RegExp(r'^v\d+\.\d+\.\d+-beta\.\d+$');

  static Future<ReleaseChannel> _chosenChannel() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('commands.update.channel');
    return saved == null ? buildChannel : releaseChannelFromString(saved);
  }

  /// The tags of the latest published releases, and one release in full.
  /// Replaced in tests, which must not reach GitHub.
  @visibleForTesting
  static Future<List<String>?> Function() fetchTags = _fetchFeedTags;
  @visibleForTesting
  static Future<Map<String, dynamic>?> Function(String tag) fetchRelease = _fetchRelease;

  /// A tag whose release is not public (a draft still building, or one that
  /// was removed) answers 404. That comes back as a draft, so the check moves
  /// on instead of reporting that GitHub could not be reached.
  static Future<Map<String, dynamic>?> _fetchRelease(String tag) async {
    final url = 'https://api.github.com/repos/$_owner/$_repo/releases/tags/${Uri.encodeComponent(tag)}';
    final response = await _fetchResponse(url, accept: 'application/vnd.github+json');
    if (response.status == 404) return const {'draft': true};
    final body = response.body;
    if (body == null) return null;
    final decoded = jsonDecode(utf8.decode(body));
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  static Future<List<String>?> _fetchFeedTags() async {
    final body = await _fetch(_feedUrl, accept: 'application/atom+xml');
    if (body == null) return null;
    return tagsFromFeed(utf8.decode(body));
  }

  static const _feedUrl = 'https://github.com/$_owner/$_repo/releases.atom';

  /// The release tags in GitHub's releases feed, from each entry's link.
  @visibleForTesting
  static List<String> tagsFromFeed(String atom) {
    final doc = XmlDocument.parse(atom);
    final tags = <String>[];
    for (final link in doc.findAllElements('link')) {
      final href = link.getAttribute('href') ?? '';
      final at = href.indexOf('/releases/tag/');
      if (at < 0) continue;
      tags.add(Uri.decodeComponent(href.substring(at + '/releases/tag/'.length)));
    }
    return tags;
  }

  /// GitHub's /latest endpoint excludes prereleases. Choose the newest beta
  /// from the ordinary release list, ignoring drafts and other tag formats.
  static Map<String, dynamic>? selectRelease(List<dynamic>? releases, ReleaseChannel channel) {
    if (releases == null) return null;
    Map<String, dynamic>? newest;
    for (final raw in releases) {
      if (raw is! Map<String, dynamic> || !matchesChannel(raw, channel)) continue;
      if (newest == null || compareVersions(raw['tag_name'] as String, newest['tag_name'] as String) > 0) {
        newest = raw;
      }
    }
    return newest;
  }

  static bool matchesChannel(Map<String, dynamic> release, ReleaseChannel channel) {
    if (release['draft'] == true) return false;
    final tag = release['tag_name'];
    if (tag is! String) return false;
    if (channel == ReleaseChannel.beta) {
      return release['prerelease'] == true && RegExp(r'^v\d+\.\d+\.\d+-beta\.\d+$').hasMatch(tag);
    }
    return release['prerelease'] != true && RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag);
  }

  /// Whether the user asked not to be prompted about [version].
  static Future<bool> isSkipped(String version) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kSkippedVersion) == version;
  }

  /// Remembers that the user does not want to be prompted about [version] at
  /// launch again. A later release still prompts.
  static Future<void> skip(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSkippedVersion, version);
  }

  static String? _findAssetUrl(List<dynamic> assets, String name) {
    for (final raw in assets) {
      if (raw is! Map) continue;
      if ((raw['name'] as String?)?.toLowerCase() == name.toLowerCase()) {
        return raw['browser_download_url'] as String?;
      }
    }
    return null;
  }

  /// How this copy will update itself, and which build it needs for that.
  ///
  /// Every copy updates in place -- there is deliberately no "go to the
  /// download page" outcome for a release that published the builds it should
  /// have. Only a release missing this platform's build returns null.
  ///
  /// * Windows, installed copy: run the installer.
  /// * Windows, anywhere else (the portable zip, unpacked wherever the user
  ///   put it): replace the files in that folder with the new portable build.
  ///   If that folder cannot be written to, fall back to the installer, which
  ///   installs per-user and relaunches the installed copy.
  /// * macOS: replace the running app, or put the new one in Applications if
  ///   the running one is somewhere it cannot be replaced (see [_macTarget]).
  static Future<_Plan?> _plan(List<dynamic> assets, String tag, ReleaseChannel channel) async {
    // A beta ships under the same names: it is the same app.
    const prefix = 'CommandS_';
    final version = tag.substring(1);
    _Asset? find(String ending) {
      for (final raw in assets) {
        if (raw is! Map) continue;
        final name = raw['name'] as String?;
        final url = raw['browser_download_url'] as String?;
        if (name == null || url == null) continue;
        if (name != '$prefix$version$ending') continue;
        return _Asset(name, url, (raw['size'] as num?)?.toInt() ?? 0);
      }
      return null;
    }

    if (Platform.isWindows) {
      final installer = find('_windows_Setup.exe');
      final portable = find('_windows_portable.zip');
      if (installer != null && await _isInstalledCopy()) {
        return _Plan(UpdateMethod.windowsInstaller, installer);
      }
      if (portable != null && _canWriteNextToExe()) {
        return _Plan(UpdateMethod.windowsPortable, portable);
      }
      if (installer != null) return _Plan(UpdateMethod.windowsInstaller, installer);
      return null;
    }
    if (Platform.isMacOS) {
      final app = find('_macOS.zip');
      if (app != null && _macTarget(channel) != null) {
        return _Plan(UpdateMethod.macApp, app);
      }
    }
    return null;
  }

  /// Compares stable and `-beta.N` tags. A beta sorts before its stable tag.
  /// Malformed tags sort below valid versions.
  static int compareVersions(String a, String b) {
    List<int>? parts(String v) {
      final cleaned = v.trim().toLowerCase();
      final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:-beta\.(\d+))?$').firstMatch(cleaned);
      if (match == null) return null;
      return [
        for (var i = 1; i <= 4; i++)
          if (i == 4 && match.group(i) == null) -1 else int.parse(match.group(i)!),
      ];
    }

    final x = parts(a);
    final y = parts(b);
    if (x == null) return y == null ? 0 : -1;
    if (y == null) return 1;
    for (var i = 0; i < 3; i++) {
      if (x[i] != y[i]) return x[i] - y[i];
    }
    if (x[3] == -1) return y[3] == -1 ? 0 : 1;
    if (y[3] == -1) return -1;
    return x[3] - y[3];
  }

  /// One redirect-following GET. `dart:io`'s client is used rather than adding
  /// an HTTP package for two requests.
  static Future<List<int>?> _fetch(String url, {String? accept}) async =>
      (await _fetchResponse(url, accept: accept)).body;

  /// [_fetch] with the final status code, null when no answer came at all.
  static Future<({int? status, List<int>? body})> _fetchResponse(String url, {String? accept}) async {
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
          if (location == null) return (status: response.statusCode, body: null);
          target = target.resolve(location);
          continue;
        }
        if (response.statusCode != 200) {
          await response.drain<void>();
          return (status: response.statusCode, body: null);
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
        }
        return (status: 200, body: bytes);
      }
      return (status: null, body: null);
    } catch (_) {
      return (status: null, body: null);
    } finally {
      client.close(force: true);
    }
  }

  /// Downloads [info]'s build for this platform and hands over to it -- see
  /// [_plan] for which build and how. The download is checked against the size
  /// the release API reported and the checksum the release published before
  /// anything is run or replaced.
  ///
  /// [onProgress] reports 0..1, or null when the server sends no length.
  /// Returns an error string, or null once the update has been handed off --
  /// at which point the caller must quit the app, since every method finishes
  /// by replacing this app's own files.
  static Future<String?> downloadAndInstall(
    UpdateInfo info, {
    void Function(double? progress)? onProgress,
  }) async {
    final method = info.method;
    final url = info.assetUrl;
    if (method == null || url == null) {
      return 'This release has no ${Platform.isMacOS ? 'macOS' : 'Windows'} build.';
    }
    try {
      final dir = await Directory.systemTemp.createTemp('commands_update_');
      final sep = Platform.pathSeparator;
      final file = File('${dir.path}$sep${info.assetName ?? 'update'}');
      final ok = await _download(url, file, onProgress);
      if (!ok) return 'The download did not complete.';
      final problem = await _verify(info, file);
      if (problem != null) return problem;

      switch (method) {
        case UpdateMethod.windowsInstaller:
          return await _handOverWindows(file);
        case UpdateMethod.windowsPortable:
          return await _handOverWindowsPortable(file, dir, info.channel);
        case UpdateMethod.macApp:
          return await _handOverMac(file, dir, info.channel);
      }
    } catch (e) {
      return e.toString();
    }
  }

  /// Null if [file] is the build the release published.
  static Future<String?> _verify(UpdateInfo info, File file) async {
    final size = await file.length();
    // A truncated download, or an error page saved as if it were the build,
    // would otherwise be run. The release API already said how big the asset
    // is, so a mismatch means this is not it.
    if (info.assetSize > 0 && size != info.assetSize) {
      return 'The download is incomplete.';
    }
    if (size < 1024 * 1024) return 'The download does not look like a CommandS build.';

    // This ends by running what was just downloaded, so matching the checksum
    // published with the release is worth the extra request: size alone would
    // not notice a substituted file of the same length. Releases predating
    // SHA256SUMS.txt have none to check against and are accepted on size
    // alone, rather than being made impossible to update to.
    final expected = await _expectedChecksum(info);
    if (expected != null) {
      final actual = sha256.convert(await file.readAsBytes()).toString();
      if (actual.toLowerCase() != expected.toLowerCase()) {
        return 'The download failed its checksum and was not run.';
      }
    }
    return null;
  }

  static Future<String?> _handOverWindows(File installer) async {
    // Started directly, never through `cmd /c`. The first version of this
    // chained the installer and a relaunch in one cmd line, and cmd.exe strips
    // the first and last quote of any /c argument that starts with one -- so
    // with a quoted installer path the line was mangled, cmd failed with "The
    // filename, directory name, or volume label syntax is incorrect", and the
    // app quit with no installer running. Arguments passed to the installer
    // directly are quoted the way every ordinary Win32 program parses them.
    //
    // /SILENT shows a progress window but asks nothing; CLOSEAPPLICATIONS lets
    // the installer replace this app's files once it exits; NORESTART keeps it
    // from ever rebooting the machine; RELAUNCH is this app's own switch (see
    // windows/installer.iss), since the installer's usual "launch when done"
    // step is skipped in silent mode and this process will be gone by then.
    await Process.start(
      installer.path,
      const ['/SILENT', '/CLOSEAPPLICATIONS', '/NORESTART', '/RELAUNCH'],
      mode: ProcessStartMode.detached,
    );
    return null;
  }

  static Future<String?> _handOverWindowsPortable(File zip, Directory work, ReleaseChannel channel) async {
    final target = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    final extractTo = Directory('${work.path}${sep}extracted');
    await extractTo.create();
    // Windows' own bsdtar reads zip (Windows 10 1803 and later), so no archive
    // package is needed for one extraction. Named by full path: a Git or
    // MSYS `tar` earlier on PATH is GNU tar, which does not.
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final unzip = await Process.run(
        '$systemRoot${sep}System32${sep}tar.exe', ['-xf', zip.path, '-C', extractTo.path]);
    if (unzip.exitCode != 0) return 'Could not unpack the update.';
    // The zip holds a single CommandS_<version>_windows_portable folder.
    final folders = extractTo.listSync().whereType<Directory>().toList();
    const executable = 'commands.exe';
    if (folders.length != 1 ||
        !File('${folders.single.path}$sep$executable').existsSync()) {
      return 'The update does not contain CommandS.';
    }

    final script = File('${work.path}${sep}update.ps1');
    await script.writeAsString(_windowsPortableScript);
    // powershell -File takes each following argument as one parameter value,
    // so the paths travel as plain argv entries -- no shell quoting to get
    // wrong, unlike the `cmd /c` line the first Windows updater was undone by.
    //
    // Started in the normal mode, not detached, on purpose. Detached means
    // DETACHED_PROCESS, which gives a console program no console at all, and
    // powershell.exe started that way exits without running its script --
    // measured: three detached variants never ran, while a GUI program
    // started the identical way survived the launcher exiting. Normal mode
    // gives it a console of its own (hidden by -WindowStyle), and the process
    // keeps running after this one exits, which is all the hand-off needs.
    await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', script.path,
        '-ProcessId', '$pid',
        '-Source', folders.single.path,
        '-Target', target,
        '-Backup', '${work.path}${sep}previous',
        '-Executable', executable,
      ],
    );
    return null;
  }

  /// Waits for the app to exit, copies the new build over the old one and
  /// relaunches it. The old files are copied aside first and copied back if
  /// replacing them fails part-way, so a failed update leaves a working app.
  static const _windowsPortableScript = r"""
param([int]$ProcessId, [string]$Source, [string]$Target, [string]$Backup, [string]$Executable)
$ErrorActionPreference = 'Stop'
try { Wait-Process -Id $ProcessId -Timeout 60 -ErrorAction SilentlyContinue } catch {}
Start-Sleep -Milliseconds 500
try {
  New-Item -ItemType Directory -Force -Path $Backup | Out-Null
  Copy-Item -Path (Join-Path $Target '*') -Destination $Backup -Recurse -Force
  Copy-Item -Path (Join-Path $Source '*') -Destination $Target -Recurse -Force
} catch {
  try { Copy-Item -Path (Join-Path $Backup '*') -Destination $Target -Recurse -Force } catch {}
}
Start-Process -FilePath (Join-Path $Target $Executable)
""";

  static Future<String?> _handOverMac(File zip, Directory work, ReleaseChannel channel) async {
    final target = _macTarget(channel);
    if (target == null) return 'There is nowhere this user can install the update.';

    final extractTo = Directory('${work.path}/extracted');
    await extractTo.create();
    final unzip = await Process.run(
        '/usr/bin/ditto', ['-x', '-k', zip.path, extractTo.path]);
    if (unzip.exitCode != 0) return 'Could not unpack the update.';
    final fresh = extractTo
        .listSync()
        .whereType<Directory>()
        .where((d) => d.path.endsWith('.app'))
        .toList();
    const expectedApp = 'CommandS.app';
    if (fresh.length != 1 || !fresh.single.path.endsWith('/$expectedApp')) {
      return 'The update does not contain an app.';
    }

    final script = File('${work.path}/swap.sh');
    await script.writeAsString(_macSwapScript);
    await Process.start(
      '/bin/sh',
      [script.path, '$pid', target, fresh.single.path, work.path],
      mode: ProcessStartMode.detached,
    );
    return null;
  }

  /// Waits for the app to exit, puts the new bundle at OLD, and opens it. If
  /// something is already at OLD it is renamed aside, not deleted, until the
  /// new one has actually been moved in, and renamed back if that fails -- so
  /// a failed update leaves the working app where it was. OLD may not exist
  /// yet, when the update is going into Applications rather than over the
  /// running copy. The quarantine attribute is cleared so the new bundle does
  /// not bring back the warning the user already dismissed for the old one.
  static const _macSwapScript = r"""#!/bin/sh
PID="$1"; OLD="$2"; NEW="$3"; WORK="$4"
i=0
while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 120 ]; do
  sleep 0.25; i=$((i + 1))
done
BACKUP="$OLD.previous"
rm -rf "$BACKUP"
if [ -e "$OLD" ]; then
  if ! mv "$OLD" "$BACKUP"; then
    open "$OLD"; exit 1
  fi
fi
if mv "$NEW" "$OLD"; then
  xattr -dr com.apple.quarantine "$OLD" 2>/dev/null
  rm -rf "$BACKUP"
elif [ -e "$BACKUP" ]; then
  mv "$BACKUP" "$OLD"
fi
open "$OLD"
rm -rf "$WORK"
""";

  /// Where the new `.app` goes on macOS.
  ///
  /// Over the running copy when that is possible. When it is not -- the app
  /// was opened straight from Downloads, so macOS is running it from a
  /// read-only App Translocation copy, or it sits in a folder this user
  /// cannot write to -- into /Applications, or ~/Applications for a user who
  /// cannot write there either. Null only if none of those is writable.
  static String? _macTarget(ReleaseChannel channel) {
    bool writable(String dir) {
      final probe = File('$dir/.commands_update_probe_$pid');
      try {
        probe.writeAsStringSync('');
        probe.deleteSync();
        return true;
      } catch (_) {
        return false;
      }
    }

    // .../CommandS.app/Contents/MacOS/CommandS
    final bundle = File(Platform.resolvedExecutable).parent.parent.parent;
    if (bundle.path.endsWith('.app') &&
        !bundle.path.contains('/AppTranslocation/') &&
        writable(bundle.parent.path)) {
      return bundle.path;
    }
    const appBundle = 'CommandS.app';
    if (writable('/Applications')) return '/Applications/$appBundle';
    final home = Platform.environment['HOME'];
    if (home != null) {
      final userApps = Directory('$home/Applications');
      try {
        userApps.createSync(recursive: true);
      } catch (_) {}
      if (writable(userApps.path)) return '${userApps.path}/$appBundle';
    }
    return null;
  }

  /// Whether this is the copy the installer put in place -- the one the
  /// installer's update will replace and relaunch.
  static Future<bool> _isInstalledCopy() async {
    try {
      final result = await Process.run('reg', [
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\{4C6F0A1E-7B2A-4E1B-9F0C-3A6D1C2E7B90}_is1',
        '/v',
        'InstallLocation',
      ]);
      if (result.exitCode != 0) return false;
      final match = RegExp(r'InstallLocation\s+REG_SZ\s+(.+)')
          .firstMatch(result.stdout as String);
      if (match == null) return false;
      String norm(String p) => p.trim().replaceAll('/', r'\')
          .replaceFirst(RegExp(r'\\+$'), '').toLowerCase();
      final installDir = norm(match.group(1)!);
      final exeDir = norm(File(Platform.resolvedExecutable).parent.path);
      return installDir == exeDir;
    } catch (_) {
      return false;
    }
  }

  /// Whether the folder this copy runs from can have its files replaced.
  static bool _canWriteNextToExe() {
    final dir = File(Platform.resolvedExecutable).parent.path;
    final probe = File('$dir${Platform.pathSeparator}.commands_update_probe_$pid');
    try {
      probe.writeAsStringSync('');
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
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

  /// Opens the release page in the user's browser -- only offered after an
  /// automatic update has failed, or for a release missing this platform's
  /// build.
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

class _Plan {
  const _Plan(this.method, this.asset);
  final UpdateMethod method;
  final _Asset asset;
}

/// How a copy replaces itself. See [UpdateService._plan].
enum UpdateMethod { windowsInstaller, windowsPortable, macApp }

/// The outcome of asking GitHub for the latest release.
class UpdateCheck {
  const UpdateCheck.available(UpdateInfo this.info) : failed = false;
  const UpdateCheck.upToDate()
      : info = null,
        failed = false;
  const UpdateCheck.failed()
      : info = null,
        failed = true;

  /// The newer release, when there is one.
  final UpdateInfo? info;

  /// True when the question could not be answered (offline, rate-limited, ...).
  final bool failed;
}

/// A release newer than the running build.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    this.channel = ReleaseChannel.stable,
    required this.releaseUrl,
    required this.notes,
    required this.assetName,
    required this.assetUrl,
    required this.assetSize,
    required this.checksumsUrl,
    required this.method,
  });

  /// The release tag, e.g. `v1.0.26`.
  final String version;
  final ReleaseChannel channel;
  final String releaseUrl;

  /// The release notes, as written on GitHub (Markdown).
  final String notes;

  /// [notes] as plain text, for showing inside the app.
  ///
  /// The notes are written for the GitHub release page, so shown verbatim
  /// they came through as raw Markdown -- `## What's new`, `**bold**` -- and
  /// ended in download instructions that make no sense to someone who is
  /// about to be updated automatically. This keeps what changed and drops
  /// the rest.
  String get plainNotes {
    final out = <String>[];
    for (final raw in notes.split(RegExp(r'\r?\n'))) {
      final line = raw.trimRight();
      // Everything from the per-platform download sections on is for people
      // installing by hand.
      if (RegExp(r'^#{1,6}\s*(windows|macos)\b', caseSensitive: false).hasMatch(line)) {
        break;
      }
      if (line.trim().startsWith('```')) continue;
      var text = line
          .replaceFirst(RegExp(r'^#{1,6}\s*'), '')
          .replaceFirst(RegExp(r'^>\s?'), '')
          .replaceAll('**', '')
          .replaceAll('`', '');
      text = text.replaceFirstMapped(
          RegExp(r'^(\s*)[-*]\s+'), (m) => '${m[1]}• ');
      out.add(text);
    }
    return out.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// The build for this platform, if the release published one.
  final String? assetName;
  final String? assetUrl;
  final int assetSize;

  /// Where the release published its `SHA256SUMS.txt`, if it did.
  final String? checksumsUrl;

  /// How this copy will install the update; null only when the release did
  /// not publish a build for this platform.
  final UpdateMethod? method;

  bool get canSelfInstall => method != null;

  String get sizeLabel {
    if (assetSize <= 0) return '';
    final mb = assetSize / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }
}
