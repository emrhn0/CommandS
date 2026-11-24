import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app_version.dart';
import '../services/update_service.dart';
import 'app_dialog.dart';
import '../l10n/strings.dart';

/// Checks for a new release in the background on every launch and, if there
/// is one, asks whether to install it -- unless the user chose to skip that
/// version, in which case only [UpdateNote] offers it.
///
/// Wrapped around the app's home screen rather than run from `main()` so the
/// prompt has a [Navigator] to open on and the window is already up: a dialog
/// is the one thing here the user has to answer, and it should not be waiting
/// for them before the app has finished appearing.
///
/// Then again every minute while the app stays open, as a release can come
/// out while someone is working. "Remind me later" brings the prompt for the
/// same version back an hour after it was answered. The checks go on while
/// the prompt is open: when a newer version turns up before it is answered,
/// the prompt closes and one for the newer version opens in its place, saying
/// which version it replaces, so an update is never a step behind.
class UpdateGate extends StatefulWidget {
  const UpdateGate({super.key, required this.child, @visibleForTesting this.checker = UpdateService.check});
  final Widget child;
  final Future<UpdateInfo?> Function() checker;

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> {
  static const _settle = Duration(seconds: 3);

  /// A new release shows up within a minute. The check reads the releases
  /// feed, which the API's hourly limit does not cover.
  static const _interval = Duration(minutes: 1);

  /// After "Remind me later", the same version is not asked about again for
  /// this long. A newer one is, at once.
  static const _snooze = Duration(hours: 1);

  Timer? _next;
  String? _snoozedVersion;
  Timer? _snoozeEnd;

  /// The version the open prompt offers, or null with no prompt open.
  UpdateInfo? _showing;

  /// The open prompt's own context, to close it with.
  BuildContext? _promptContext;

  /// True while the open prompt is downloading: it is not replaced then.
  final _installing = ValueNotifier<bool>(false);

  /// A newer version to open as soon as the open prompt has closed.
  UpdateInfo? _replaceWith;

  @override
  void initState() {
    super.initState();
    // Let the window settle first. The check is a network round trip on a
    // background isolate's I/O, so it never blocks the UI, but showing a
    // dialog over a half-drawn app looks like a fault.
    _next = Timer(_settle, _round);
  }

  @override
  void dispose() {
    _next?.cancel();
    _snoozeEnd?.cancel();
    _installing.dispose();
    super.dispose();
  }

  /// One check, and the next a minute after it ends. With a prompt open it
  /// only looks for a newer version to put in its place; a prompt is never
  /// opened over another one.
  Future<void> _round() async {
    final info = await widget.checker();
    if (!mounted) return;
    if (info != null) {
      UpdateService.available.value = info;
      final showing = _showing;
      if (showing != null) {
        await _replaceIfNewer(showing, info);
      } else if (info.version != _snoozedVersion && !await UpdateService.isSkipped(info.version)) {
        if (!mounted) return;
        // Not over a dialog the user is in the middle of: the next round,
        // a minute on, tries again.
        if (ModalRoute.of(context)?.isCurrent ?? true) unawaited(_present(info));
      }
    }
    if (!mounted) return;
    _next = Timer(_interval, _round);
  }

  /// Closes the open prompt for [showing] when [info] is newer, so [_present]
  /// opens [info] next. Not while it downloads, and not when something is open
  /// on top of it.
  Future<void> _replaceIfNewer(UpdateInfo showing, UpdateInfo info) async {
    if (UpdateService.compareVersions(info.version, showing.version) <= 0) return;
    if (_installing.value || await UpdateService.isSkipped(info.version)) return;
    final prompt = _promptContext;
    if (!mounted || prompt == null || !prompt.mounted) return;
    if (!(ModalRoute.of(prompt)?.isCurrent ?? false)) return;
    _replaceWith = info;
    Navigator.of(prompt).pop();
  }

  Future<void> _present(UpdateInfo info, {UpdateInfo? replaces}) async {
    _showing = info;
    await showUpdateDialog(
      context,
      info,
      replaces: replaces,
      installing: _installing,
      onContext: (c) => _promptContext = c,
    );
    _showing = null;
    _promptContext = null;
    _installing.value = false;
    if (!mounted) return;
    final newer = _replaceWith;
    _replaceWith = null;
    if (newer != null) {
      unawaited(_present(newer, replaces: info));
      return;
    }
    // Closed without updating or skipping: "Remind me later".
    _snoozedVersion = info.version;
    _snoozeEnd?.cancel();
    _snoozeEnd = Timer(_snooze, () => _snoozedVersion = null);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Downloads and installs [info], then quits so the update can replace this
/// app's files; the update relaunches it. Only returns if something went
/// wrong, with the reason. Shared by the launch prompt and the Settings page,
/// which offer the same update in two places.
Future<String?> installUpdate(UpdateInfo info, {void Function(double? progress)? onProgress}) async {
  final error = await UpdateService.downloadAndInstall(info, onProgress: onProgress);
  if (error != null) return error;
  exit(0);
}

/// Shows the "a new version is available" prompt for [info]. [replaces] is
/// the version an earlier prompt offered, when this one took its place.
/// [installing] follows whether it is downloading, and [onContext] gets the
/// prompt's own context, which closes it.
Future<void> showUpdateDialog(
  BuildContext context,
  UpdateInfo info, {
  UpdateInfo? replaces,
  ValueNotifier<bool>? installing,
  void Function(BuildContext promptContext)? onContext,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (promptContext) {
      onContext?.call(promptContext);
      return _UpdateDialog(info: info, replaces: replaces, installing: installing);
    },
  );
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.info, this.replaces, this.installing});
  final UpdateInfo info;
  final UpdateInfo? replaces;
  final ValueNotifier<bool>? installing;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _busy = false;
  double? _progress;
  String? _error;

  Future<void> _install() async {
    widget.installing?.value = true;
    setState(() {
      _busy = true;
      _error = null;
      _progress = 0;
    });
    final error = await installUpdate(
      widget.info,
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
    );
    widget.installing?.value = false;
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  Future<void> _openPage() async {
    await UpdateService.openReleasePage(widget.info);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final dim = Theme.of(context).textTheme.bodySmall?.color;
    final notes = info.plainNotes;
    return AppDialog(
      title: tr(info.channel == ReleaseChannel.beta
          ? 'CommandS Beta {version} is available'
          : 'CommandS {version} is available', {'version': info.version}),
      icon: Icons.system_update_alt,
      width: 500,
      closable: !_busy,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.replaces != null) ...[
            Container(
              key: const Key('update-replaces'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                tr('A newer version came out: {version} replaces {previous}.', {
                  'version': info.version,
                  'previous': widget.replaces!.version,
                }),
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.primary),
              ),
            ),
            const SizedBox(height: 12),
          ],
          Text(
            tr('You are running {version}.', {'version': appVersion}) +
                (info.sizeLabel.isEmpty ? '' : ' ${tr('Download is {size}.', {'size': info.sizeLabel})}'),
            style: TextStyle(color: dim, fontSize: 12),
          ),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 14),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                child: Text(notes, style: const TextStyle(fontSize: 12, height: 1.45)),
              ),
            ),
          ],
          if (!info.canSelfInstall) ...[
            const SizedBox(height: 14),
            Text(
              Platform.isMacOS
                  ? tr(
                      'Downloading opens the release page in your browser. Unzip the app and drag it to '
                      'Applications, replacing the old one.',
                    )
                  : tr('Downloading opens the release page in your browser.'),
              style: TextStyle(color: dim, fontSize: 12, height: 1.4),
            ),
          ],
          if (_busy) ...[
            const SizedBox(height: 18),
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 8),
            Text(
              _progress == null
                  ? tr('Downloading…')
                  : tr('Downloading… {percent}%', {'percent': (_progress! * 100).toStringAsFixed(0)}),
              style: TextStyle(color: dim, fontSize: 11),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
            const SizedBox(height: 6),
            Text(
              tr('You can still download it yourself from the release page.'),
              style: TextStyle(color: dim, fontSize: 11),
            ),
          ],
        ],
      ),
      actions: _busy
          ? const []
          : [
              TextButton(
                onPressed: () async {
                  await UpdateService.skip(info.version);
                  if (context.mounted) Navigator.of(context).pop();
                },
                child: Text(tr('Skip this version')),
              ),
              TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('Remind me later'))),
              if (info.canSelfInstall && _error == null)
                ElevatedButton(onPressed: _install, child: Text(tr('Update now')))
              else
                ElevatedButton(onPressed: _openPage, child: Text(tr('Open download page'))),
            ],
    );
  }
}

/// The update button's fill, the same green as a connected session's dot.
const updateGreen = Color(0xFF2EB85C);

/// The way back to an update after "Remind me later" (or "Skip"), without
/// restarting the app to get the prompt again. It takes the place of the
/// sidebar header's caption, [otherwise], while there is something to offer,
/// and takes no space of its own.
class UpdateNote extends StatelessWidget {
  const UpdateNote({super.key, required this.otherwise});

  final Widget otherwise;

  /// Shared with the New button so the two controls align in the sidebar.
  static const double actionHeight = 24;

  /// The note's padding, icon and the gap after it, around its text.
  static const double _chrome = 8 + 13 + 5 + 8 + 1;

  /// The note's text and icon on its green tint, readable in either theme.
  static Color inkFor(Brightness brightness) =>
      brightness == Brightness.dark ? const Color(0xFF5FD88A) : const Color(0xFF1E8A43);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UpdateInfo?>(
      valueListenable: UpdateService.available,
      builder: (context, info, _) {
        if (info == null) return otherwise;
        final ink = inkFor(Theme.of(context).brightness);
        final style = TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ink);
        final version = tr('{version} ready', {'version': info.version});
        final action = tr('Update');
        return LayoutBuilder(builder: (context, constraints) {
          // In a narrow panel the version gives way (the tooltip still has
          // it), never the word that says what a click does.
          final full = TextPainter(
            text: TextSpan(text: '$version · $action', style: DefaultTextStyle.of(context).style.merge(style)),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          final showVersion = constraints.maxWidth >= full.width + _chrome;
          full.dispose();
          return Align(
            alignment: Alignment.centerLeft,
            child: Tooltip(
              message: tr(info.channel == ReleaseChannel.beta
                  ? 'CommandS Beta {version} is available'
                  : 'CommandS {version} is available', {'version': info.version}),
              child: Material(
                // Green in either theme, the colour of "go" rather than the
                // theme's own: it is the one thing in the header that is not
                // always there, and it should be noticed.
                key: const ValueKey('update-button'),
                color: updateGreen.withValues(alpha: 0.16),
                shape: const StadiumBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => showUpdateDialog(context, info),
                  child: Container(
                    height: actionHeight,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.system_update_alt, size: 13, color: ink),
                        const SizedBox(width: 5),
                        if (showVersion) Text(version, key: const ValueKey('update-note-version'), style: style),
                        Flexible(
                          child: Text(
                            showVersion ? ' · $action' : action,
                            key: const ValueKey('update-note-action'),
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: style,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        });
      },
    );
  }
}
