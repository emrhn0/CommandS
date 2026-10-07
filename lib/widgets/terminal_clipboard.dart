import 'dart:async';

import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

/// PuTTY's clipboard behaviour for a terminal view: selecting text copies it,
/// and right-clicking pastes. No Ctrl+C / Ctrl+V -- in a terminal those keys
/// belong to the remote side (Ctrl+C is an interrupt).
class TerminalClipboard {
  TerminalClipboard({required this.terminal, required this.controller}) {
    controller.addListener(_onSelectionChanged);
  }

  final Terminal terminal;
  final TerminalController controller;

  /// How long the selection has to stop changing before it is copied: it
  /// changes on every mouse move of a drag, and the clipboard only wants the
  /// final one.
  static const settle = Duration(milliseconds: 180);

  Timer? _debounce;
  String? _lastCopied;

  void _onSelectionChanged() {
    _debounce?.cancel();
    if (controller.selection == null) return;
    _debounce = Timer(settle, copySelection);
  }

  /// Copies the current selection, if there is one worth copying. Returns what
  /// was copied, or null.
  Future<String?> copySelection() async {
    final range = controller.selection;
    if (range == null) return null;
    final text = terminal.buffer.getText(range);
    if (text.trim().isEmpty || text == _lastCopied) return null;
    _lastCopied = text;
    await Clipboard.setData(ClipboardData(text: text));
    return text;
  }

  /// Pastes the clipboard into the session. Line breaks are sent as the Enter
  /// key (carriage return), the way PuTTY does it, rather than the Windows
  /// clipboard's CR LF, which a remote shell would read as two line ends.
  Future<void> paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    terminal.paste(text.replaceAll('\r\n', '\r').replaceAll('\n', '\r'));
  }

  void dispose() {
    _debounce?.cancel();
    controller.removeListener(_onSelectionChanged);
  }
}
