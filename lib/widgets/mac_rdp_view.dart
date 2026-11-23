import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../services/mac_rdp_session.dart';
import '../services/rdp_keymap.dart';
import '../services/session_controller.dart';

/// An RDP session drawn inside its tab on macOS: the remote desktop is a
/// Flutter texture the FreeRDP engine paints into, and the keyboard and mouse
/// over it go to the server. The pane's size is the desktop's size, and
/// resizing the pane re-renders the desktop at the new size.
class MacRdpEmbedView extends StatefulWidget {
  const MacRdpEmbedView({super.key, required this.controller, required this.active});
  final MacRdpSessionController controller;
  final bool active;

  @override
  State<MacRdpEmbedView> createState() => _MacRdpEmbedViewState();
}

class _MacRdpEmbedViewState extends State<MacRdpEmbedView> {
  final _focus = FocusNode(debugLabel: 'rdp-session');
  int _buttons = 0;

  /// Scroll not yet sent: trackpads move in fractions of a notch.
  double _wheel = 0;
  double _hWheel = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void didUpdateWidget(MacRdpEmbedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChange);
      widget.controller.addListener(_onChange);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    _focus.dispose();
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    // The session that just came up wants the keyboard, if its tab is the one
    // on screen.
    if (widget.active && widget.controller.status == SessionStatus.running && !_focus.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) _focus.requestFocus();
      });
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final usage = event.physicalKey.usbHidUsage;
    final c = widget.controller;
    switch (event) {
      case KeyDownEvent():
        c.sendKey(usage, down: true);
      case KeyRepeatEvent():
        c.sendKey(usage, down: true, repeat: true);
      case KeyUpEvent():
        c.sendKey(usage, down: false);
    }
    // Every key belongs to the session, as it does in the Windows pane.
    return KeyEventResult.handled;
  }

  void _onFocusChange(bool focused) {
    if (focused) {
      widget.controller.focused();
    } else {
      widget.controller.releaseKeys();
    }
  }

  // ---- pointer ----

  /// Where [local] (in the texture's box of [box] logical pixels) is on the
  /// remote desktop.
  (int, int) _remote(Offset local, Size box) {
    final c = widget.controller;
    if (box.width <= 0 || box.height <= 0) return (0, 0);
    return (
      (local.dx / box.width * c.remoteWidth).floor(),
      (local.dy / box.height * c.remoteHeight).floor(),
    );
  }

  void _pointer(PointerEvent e, Size box) {
    final (x, y) = _remote(e.localPosition, box);
    final c = widget.controller;
    final changed = e.buttons ^ _buttons;
    if (changed == 0) {
      c.sendPointer(RdpPointer.move, x, y);
      return;
    }
    for (final bit in const [kPrimaryButton, kSecondaryButton, kMiddleMouseButton]) {
      if (changed & bit == 0) continue;
      final flag = RdpPointer.buttonFlag(bit);
      if (flag == null) continue;
      final down = e.buttons & bit != 0;
      c.sendPointer(flag | (down ? RdpPointer.down : 0), x, y);
    }
    _buttons = e.buttons;
  }

  void _scroll(Offset delta, Offset local, Size box) {
    final (x, y) = _remote(local, box);
    // About three wheel units per logical pixel: a 40 px mouse-wheel step is
    // one Windows notch.
    _wheel += -delta.dy * 3;
    _hWheel += delta.dx * 3;
    final v = _wheel.truncate();
    if (v != 0) {
      _wheel -= v;
      widget.controller.sendPointer(RdpPointer.wheelFlags(v), x, y);
    }
    final h = _hWheel.truncate();
    if (h != 0) {
      _hWheel -= h;
      widget.controller.sendPointer(RdpPointer.wheelFlags(h, horizontal: true), x, y);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return LayoutBuilder(builder: (context, constraints) {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final w = (constraints.maxWidth * dpr).round();
      final h = (constraints.maxHeight * dpr).round();
      if (widget.active) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) c.reportSize(w, h);
        });
      }
      if (c.needsCredentials) return _MacRdpLogin(controller: c);
      final texture = c.textureId;
      if (c.status == SessionStatus.error || c.status == SessionStatus.closed) {
        return _MacRdpEnded(controller: c);
      }
      if (texture == null || c.remoteWidth == 0 || c.status != SessionStatus.running) {
        return _MacRdpConnecting(host: c.host);
      }
      // The desktop at its own pixel size, shrunk only while a resize is being
      // renegotiated and it is briefly bigger than the pane.
      final natural = Size(c.remoteWidth / dpr, c.remoteHeight / dpr);
      final scale = [1.0, constraints.maxWidth / natural.width, constraints.maxHeight / natural.height]
          .reduce((a, b) => a < b ? a : b);
      final box = Size(natural.width * scale, natural.height * scale);
      return ColoredBox(
        color: Colors.black,
        child: Align(
          alignment: Alignment.topLeft,
          child: Focus(
            focusNode: _focus,
            autofocus: widget.active,
            onKeyEvent: _onKey,
            onFocusChange: _onFocusChange,
            child: MouseRegion(
              cursor: SystemMouseCursors.basic,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (e) {
                  if (!_focus.hasFocus) _focus.requestFocus();
                  _pointer(e, box);
                },
                onPointerUp: (e) => _pointer(e, box),
                onPointerMove: (e) => _pointer(e, box),
                onPointerHover: (e) => _pointer(e, box),
                onPointerSignal: (e) {
                  if (e is PointerScrollEvent) _scroll(e.scrollDelta, e.localPosition, box);
                },
                onPointerPanZoomUpdate: (e) => _scroll(-e.panDelta, e.localPosition, box),
                child: SizedBox.fromSize(size: box, child: Texture(textureId: texture)),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _MacRdpConnecting extends StatelessWidget {
  const _MacRdpConnecting({required this.host});
  final String host;

  @override
  Widget build(BuildContext context) {
    final dim = Theme.of(context).textTheme.bodySmall?.color;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.4)),
        const SizedBox(height: 14),
        Text(tr('Connecting to {host}…', {'host': host}), style: TextStyle(color: dim, fontSize: 12)),
      ]),
    );
  }
}

class _MacRdpEnded extends StatelessWidget {
  const _MacRdpEnded({required this.controller});
  final MacRdpSessionController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dim = Theme.of(context).textTheme.bodySmall?.color;
    final failed = controller.status == SessionStatus.error;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 430),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(
            failed ? Icons.error_outline : Icons.desktop_windows_outlined,
            size: 38,
            color: failed ? scheme.error : scheme.primary.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 14),
          Text(
            tr(failed ? 'RDP session could not start' : 'RDP session closed'),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          if (failed && controller.lastError != null) ...[
            const SizedBox(height: 8),
            Text(
              controller.lastError!,
              textAlign: TextAlign.center,
              style: TextStyle(color: dim, fontSize: 12, height: 1.45),
            ),
          ],
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: controller.relaunch,
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(tr('Reconnect')),
          ),
        ]),
      ),
    );
  }
}

/// Asks for the login the server wants: none was saved, or the saved one was
/// refused. What is typed is used for this tab only.
class _MacRdpLogin extends StatefulWidget {
  const _MacRdpLogin({required this.controller});
  final MacRdpSessionController controller;

  @override
  State<_MacRdpLogin> createState() => _MacRdpLoginState();
}

class _MacRdpLoginState extends State<_MacRdpLogin> {
  late final _user = TextEditingController(text: widget.controller.user);
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();

  @override
  void dispose() {
    _user.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  void _submit() {
    if (_password.text.isEmpty) return;
    widget.controller.signIn(_user.text, _password.text);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final error = widget.controller.lastError;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Icon(Icons.desktop_windows_outlined, size: 34, color: scheme.primary.withValues(alpha: 0.6)),
          const SizedBox(height: 12),
          Text(
            tr('Sign in to {host}', {'host': widget.controller.host}),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          if (error != null) ...[
            const SizedBox(height: 6),
            Text(error, textAlign: TextAlign.center, style: TextStyle(color: scheme.error, fontSize: 12)),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _user,
            autofocus: _user.text.isEmpty,
            decoration: InputDecoration(labelText: tr('Username'), isDense: true),
            onSubmitted: (_) => _passwordFocus.requestFocus(),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _password,
            focusNode: _passwordFocus,
            autofocus: _user.text.isNotEmpty,
            obscureText: true,
            decoration: InputDecoration(labelText: tr('Password'), isDense: true),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _submit, child: Text(tr('Connect'))),
        ]),
      ),
    );
  }
}
