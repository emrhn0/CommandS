import 'dart:async';

import 'package:flutter/material.dart';

import '../services/rdp_session.dart';
import '../services/session_controller.dart';

/// Height of the session bar above an embedded RDP surface.
///
/// The session *is* a native child window sitting over its share of the pane,
/// which means Flutter cannot draw anything on top of it — a floating overlay
/// button inside the pane is painted behind the session and can be neither seen
/// nor clicked. (The previous implementation's "reconnect to fit" button was
/// positioned exactly there.) So the controls get their own strip that the
/// native window is kept out of, rather than an overlay that silently doesn't
/// work.
const double _kSessionBarHeight = 26;

/// The Flutter-side half of an embedded RDP session: a strip of controls, and
/// below it a black placeholder whose on-screen rectangle is reported to
/// [RdpSessionController.reposition] so the native ActiveX host window stays
/// exactly over it.
///
/// The native window is a real child of the app's top-level window, a sibling
/// of Flutter's view, created `WS_CLIPSIBLINGS` under a `WS_CLIPCHILDREN`
/// parent. That is what keeps it visible: the previous implementation embedded
/// a window it did not own and could not restyle, and had to re-assert z-order
/// on a 30ms timer for the whole life of a session because any repaint
/// elsewhere in the app would otherwise cover the session up. Here z-order is
/// asserted once, when the pane becomes visible.
class RdpEmbedView extends StatefulWidget {
  const RdpEmbedView({super.key, required this.controller, required this.active});
  final RdpSessionController controller;
  final bool active;

  @override
  State<RdpEmbedView> createState() => _RdpEmbedViewState();
}

class _RdpEmbedViewState extends State<RdpEmbedView> with WidgetsBindingObserver {
  final _key = GlobalKey();
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.setActive(widget.active);
    if (widget.active) _startPolling();
  }

  @override
  void didUpdateWidget(RdpEmbedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active) {
      widget.controller.setActive(widget.active);
      if (widget.active) {
        _startPolling();
      } else {
        _pollTimer?.cancel();
      }
    }
  }

  @override
  void didChangeMetrics() {
    if (widget.active) _reposition();
  }

  /// Flutter reports a window *resize* through [didChangeMetrics], but a pane
  /// can move or change size without either that or a rebuild of this widget —
  /// a split divider being dragged, the sidebar animating open. Rather than
  /// chase every one, the rectangle is re-read on a light timer; the controller
  /// drops the read when nothing changed, so an idle session costs a
  /// `localToGlobal` call and no platform-channel traffic at all.
  void _startPolling() {
    _pollTimer?.cancel();
    _reposition();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => _reposition());
  }

  void _reposition() {
    if (!mounted || !widget.active) return;
    final rect = _surfaceRect();
    if (rect == null) return;
    widget.controller.reposition(rect, MediaQuery.of(context).devicePixelRatio);
  }

  Rect? _surfaceRect() {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _reconnect() {
    widget.controller.reconnect(_surfaceRect(), MediaQuery.of(context).devicePixelRatio);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    widget.controller.setActive(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reposition());
    }
    return StreamBuilder<SessionStatus>(
      stream: widget.controller.statusStream,
      initialData: widget.controller.status,
      builder: (context, snapshot) {
        final status = snapshot.data ?? SessionStatus.starting;
        return Column(
          children: [
            _SessionBar(
              host: widget.controller.tabTitle ?? widget.controller.host,
              status: status,
              // Where the server renegotiates resolution on resize there is
              // nothing for a manual reconnect to fix, so it isn't offered.
              showRefit: status == SessionStatus.running &&
                  !widget.controller.supportsDynamicResolution,
              onRefit: _reconnect,
              onCtrlAltDel: status == SessionStatus.running
                  ? widget.controller.sendCtrlAltDelete
                  : null,
              onReconnect: status == SessionStatus.running ? null : _reconnect,
            ),
            Expanded(
              child: Stack(
                children: [
                  // The native session window sits over this — it's the hole
                  // being kept clear for it. A tap only reaches Flutter before
                  // that window exists (or after it is hidden on failure), and
                  // means the user wants to type into the session.
                  Listener(
                    onPointerDown: (_) => widget.controller.focus(),
                    child: Container(key: _key, color: Colors.black),
                  ),
                  if (status == SessionStatus.starting)
                    const Center(child: CircularProgressIndicator())
                  else if (status == SessionStatus.error)
                    _RdpMessage(
                      icon: Icons.error_outline,
                      title: 'Remote Desktop disconnected',
                      detail: widget.controller.lastError ??
                          'The session could not be started.',
                      onRetry: _reconnect,
                    )
                  else if (status == SessionStatus.closed)
                    _RdpMessage(
                      icon: Icons.power_settings_new,
                      title: 'Session ended',
                      detail: widget.controller.lastError ??
                          'The remote session was closed. Reconnect to start a new one.',
                      onRetry: _reconnect,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The strip above the session. Holds the two things that cannot be done from
/// inside a windowed RDP session — sending Ctrl+Alt+Del, which Windows
/// intercepts locally before any app sees it, and (on servers with no dynamic
/// resolution) reconnecting to fit a resized pane — plus the session's state,
/// which is otherwise invisible once the desktop is drawing.
class _SessionBar extends StatelessWidget {
  const _SessionBar({
    required this.host,
    required this.status,
    required this.showRefit,
    required this.onRefit,
    required this.onCtrlAltDel,
    required this.onReconnect,
  });

  final String host;
  final SessionStatus status;
  final bool showRefit;
  final VoidCallback onRefit;
  final VoidCallback? onCtrlAltDel;
  final VoidCallback? onReconnect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = switch (status) {
      SessionStatus.starting => ('Connecting', scheme.onSurface.withValues(alpha: 0.5)),
      SessionStatus.running => ('Connected', scheme.onSurface.withValues(alpha: 0.5)),
      SessionStatus.closed => ('Ended', scheme.onSurface.withValues(alpha: 0.5)),
      SessionStatus.error => ('Disconnected', scheme.error),
    };
    return SizedBox(
      height: _kSessionBarHeight,
      child: Material(
        color: scheme.surface,
        child: Row(
          children: [
            const SizedBox(width: 8),
            Icon(Icons.desktop_windows_outlined, size: 12, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                host,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
            ),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(fontSize: 10, color: color)),
            const Spacer(),
            if (onCtrlAltDel != null)
              _BarButton(
                tooltip: 'Send Ctrl+Alt+Del',
                icon: Icons.keyboard,
                onPressed: onCtrlAltDel!,
              ),
            if (showRefit)
              _BarButton(
                tooltip: 'Reconnect to fill the current pane size',
                icon: Icons.aspect_ratio,
                onPressed: onRefit,
              ),
            if (onReconnect != null)
              _BarButton(
                tooltip: 'Reconnect',
                icon: Icons.refresh,
                onPressed: onReconnect!,
              ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      // Above the bar, not below it: below is the session's own window, which
      // is drawn over anything Flutter puts there.
      preferBelow: false,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
          child: Icon(icon, size: 14),
        ),
      ),
    );
  }
}

class _RdpMessage extends StatelessWidget {
  const _RdpMessage({
    required this.icon,
    required this.title,
    required this.detail,
    required this.onRetry,
  });

  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 34, color: Colors.white38),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12, height: 1.45),
            ),
            const SizedBox(height: 18),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white24),
              ),
              onPressed: onRetry,
              child: const Text('Reconnect'),
            ),
          ],
        ),
      ),
    );
  }
}
