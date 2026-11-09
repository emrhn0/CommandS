import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app_version.dart';
import '../services/update_service.dart';
import 'app_dialog.dart';
import '../l10n/strings.dart';

/// Checks for a new release in the background on every launch and, if there
/// is one, asks whether to install it -- unless the user chose to skip that
/// version, in which case only [UpdateButton] offers it.
///
/// Wrapped around the app's home screen rather than run from `main()` so the
/// prompt has a [Navigator] to open on and the window is already up: a dialog
/// is the one thing here the user has to answer, and it should not be waiting
/// for them before the app has finished appearing.
///
/// Then again every hour while the app stays open, as a release can come out
/// while someone is working. "Remind me later" brings the prompt back an hour
/// after it was answered.
class UpdateGate extends StatefulWidget {
  const UpdateGate({super.key, required this.child, @visibleForTesting this.checker = UpdateService.check});
  final Widget child;
  final Future<UpdateInfo?> Function() checker;

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> {
  static const _settle = Duration(seconds: 3);
  static const _interval = Duration(minutes: 5);

  /// How soon to look again when the prompt could not be shown, because
  /// another dialog was open.
  static const _busyRetry = Duration(minutes: 1);

  Timer? _next;

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
    super.dispose();
  }

  /// One check. The next is timed from the end of this one, so the hour after
  /// "Remind me later" starts when it was pressed, and a prompt left open never
  /// has a second one opened over it.
  Future<void> _round() async {
    var wait = _interval;
    final info = await widget.checker();
    if (!mounted) return;
    if (info != null) {
      UpdateService.available.value = info;
      if (!await UpdateService.isSkipped(info.version)) {
        if (!mounted) return;
        // Not over a dialog the user is in the middle of.
        if (ModalRoute.of(context)?.isCurrent ?? true) {
          await showUpdateDialog(context, info);
          if (!mounted) return;
        } else {
          wait = _busyRetry;
        }
      }
    }
    _next = Timer(wait, _round);
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

/// Shows the "a new version is available" prompt for [info].
Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateDialog(info: info),
  );
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.info});
  final UpdateInfo info;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _busy = false;
  double? _progress;
  String? _error;

  Future<void> _install() async {
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
/// restarting the app to get the prompt again. Lives in the sidebar header and
/// takes no space at all until there is something to offer.
class UpdateButton extends StatelessWidget {
  const UpdateButton({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UpdateInfo?>(
      valueListenable: UpdateService.available,
      builder: (context, info, _) {
        if (info == null) return const SizedBox.shrink();
        return Tooltip(
          message: tr(info.channel == ReleaseChannel.beta
              ? 'CommandS Beta {version} is available'
              : 'CommandS {version} is available', {'version': info.version}),
          child: Material(
            // Filled, unlike everything else in the header: it is the one
            // control there that is not always present, and it should be
            // noticed the first time it is. Green in either theme, the
            // colour of "go" rather than the theme's own.
            key: const ValueKey('update-button'),
            color: updateGreen,
            borderRadius: BorderRadius.circular(4),
            child: InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () => showUpdateDialog(context, info),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.system_update_alt, size: 13, color: Colors.white),
                    if (!compact) ...[
                      const SizedBox(width: 5),
                      Text(
                        tr('Update to {version}', {'version': info.version}),
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
