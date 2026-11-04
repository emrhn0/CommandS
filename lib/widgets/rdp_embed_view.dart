import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/rdp_session.dart';
import '../services/session_controller.dart';
import '../l10n/strings.dart';

/// The Flutter-side half of an embedded RDP session: a black placeholder whose
/// on-screen rectangle is reported to [RdpSessionController.reposition] so the
/// native ActiveX host window stays exactly over it. Nothing Flutter draws here
/// shows over a live session, so its actions are in the tab's right-click menu.
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
    widget.controller.attachView(this, showing: widget.active);
    if (widget.active) _startPolling();
  }

  @override
  void didUpdateWidget(RdpEmbedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active) {
      widget.controller.attachView(this, showing: widget.active);
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
    widget.controller.attachView(this, showing: false);
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
        return Stack(
      children: [
        // The native session window sits over this — it's the hole
        // being kept clear for it. A tap only reaches Flutter before
        // that window exists (or after it is hidden on failure), and
        // means the user wants to type into the session.
        Listener(
          onPointerDown: (_) => widget.controller.focus(),
          child: Container(key: _key, color: Colors.black),
        ),
        // What the session was showing, while its window has stepped aside.
        Positioned.fill(
          child: IgnorePointer(
            child: ValueListenableBuilder<ui.Image?>(
              valueListenable: widget.controller.frozenFrame,
              builder: (context, frame, _) =>
                  frame == null ? const SizedBox.shrink() : RawImage(image: frame, fit: BoxFit.fill),
            ),
          ),
        ),
        if (status == SessionStatus.starting)
          const Center(child: CircularProgressIndicator())
        else if (status == SessionStatus.error)
          _RdpMessage(
            icon: Icons.error_outline,
            title: tr('Remote Desktop disconnected'),
            detail: widget.controller.lastError ?? tr('The session could not be started.'),
            onRetry: _reconnect,
          )
        else if (status == SessionStatus.closed)
          _RdpMessage(
            icon: Icons.power_settings_new,
            title: tr('Session ended'),
            detail:
                widget.controller.lastError ??
                tr('The remote session was closed. Reconnect to start a new one.'),
            onRetry: _reconnect,
          ),
      ],
    );
      },
    );
  }
}

class _RdpMessage extends StatelessWidget {
  const _RdpMessage({required this.icon, required this.title, required this.detail, required this.onRetry});

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
              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
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
              child: Text(tr('Reconnect')),
            ),
          ],
        ),
      ),
    );
  }
}
