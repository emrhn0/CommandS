import 'dart:async';
import 'package:flutter/material.dart';
import '../services/rdp_session.dart';
import '../services/session_controller.dart';

/// The Flutter-side half of RDP embedding: a plain container that reports
/// its own on-screen rectangle to [RdpSessionController.reposition] — both
/// after every layout and on a short timer the whole time it's the active
/// pane — so the native mstsc window it parented stays glued to this exact
/// spot, including as the tab is resized or the window is simply dragged
/// (which fires none of Flutter's own layout/metrics callbacks).
///
/// The native window is a separate OS-level surface, so switching tabs in
/// our own [IndexedStack] does nothing to it on its own — [active] drives an
/// explicit show/hide so a background RDP tab doesn't sit on top of
/// whichever tab you actually switched to.
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
    if (widget.active) _startPolling();
  }

  @override
  void didUpdateWidget(RdpEmbedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      widget.controller.show();
      _startPolling();
    } else if (!widget.active && oldWidget.active) {
      widget.controller.hide();
      _pollTimer?.cancel();
    }
  }

  @override
  void didChangeMetrics() {
    if (widget.active) _reposition();
  }

  /// Flutter only calls [didChangeMetrics] when the window's *size* changes
  /// (e.g. maximizing) -- a plain move/drag fires nothing here at all, and
  /// yet the native child is real enough of an OS window that a drag can
  /// still visibly desync it from the placeholder for a moment. Rather than
  /// chase every OS event that could possibly move things, just re-assert
  /// the position on a short timer the whole time this pane is active --
  /// the same self-healing approach already used natively for parenting.
  void _startPolling() {
    _pollTimer?.cancel();
    _reposition();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 200), (_) => _reposition());
  }

  void _reposition() {
    if (!mounted || !widget.active) return;
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final origin = box.localToGlobal(Offset.zero);
    final rect = origin & box.size;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    widget.controller.reposition(rect, dpr);
  }

  /// Reads the pane's current size *right now*, before triggering the
  /// reconnect -- see [RdpSessionController.refreshForCurrentSize] for why
  /// this can't wait for the next poll tick to do it instead.
  void _refresh() {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      widget.controller.refreshForCurrentSize();
      return;
    }
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final w = (box.size.width * dpr).round();
    final h = (box.size.height * dpr).round();
    widget.controller.refreshForCurrentSize(width: w, height: h);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    widget.controller.hide();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.active) WidgetsBinding.instance.addPostFrameCallback((_) => _reposition());
    return StreamBuilder<SessionStatus>(
      stream: widget.controller.statusStream,
      initialData: widget.controller.status,
      builder: (context, snap) {
        final status = snap.data;
        return Stack(
          children: [
            // The native mstsc window is parented on top of this — it's the
            // hole we're keeping clear for it.
            Container(key: _key, color: Colors.black),
            if (status == SessionStatus.starting)
              const Center(child: CircularProgressIndicator())
            else if (status == SessionStatus.error)
              Center(
                child: Text(
                  widget.controller.lastError ?? 'RDP session failed to start.',
                  style: const TextStyle(color: Colors.white70),
                ),
              )
            else if (status == SessionStatus.closed)
              const Center(
                child: Text('Session ended.', style: TextStyle(color: Colors.white70)),
              ),
            if (status == SessionStatus.running)
              Positioned(
                top: 8,
                right: 8,
                child: _RefreshForResizeButton(onPressed: _refresh),
              ),
          ],
        );
      },
    );
  }
}

/// A connection's content is sized once, at connect time, and never
/// auto-resized to follow the pane growing (see [RdpSessionController]) --
/// this is the manual way to pick up a new size without closing and
/// reopening the tab. Tucked in a corner and only shown once connected, so
/// it stays out of the way of the actual remote desktop underneath.
class _RefreshForResizeButton extends StatefulWidget {
  const _RefreshForResizeButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  State<_RefreshForResizeButton> createState() => _RefreshForResizeButtonState();
}

class _RefreshForResizeButtonState extends State<_RefreshForResizeButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedOpacity(
        opacity: _hover ? 1 : 0.45,
        duration: const Duration(milliseconds: 120),
        child: Material(
          color: Colors.black87,
          shape: const CircleBorder(),
          child: IconButton(
            tooltip: 'Reconnect to fill the current pane size',
            icon: const Icon(Icons.aspect_ratio, size: 16, color: Colors.white),
            visualDensity: VisualDensity.compact,
            onPressed: widget.onPressed,
          ),
        ),
      ),
    );
  }
}
