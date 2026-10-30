import 'package:xterm/xterm.dart';

enum SessionStatus { starting, running, closed, error }

/// Shared shape for anything that can live in a tab — an SSH pty session or
/// an embedded RDP window. Lets the tab bar / IndexedStack treat both the
/// same way instead of branching on concrete type everywhere.
abstract class SessionController {
  String get host;
  String? get tabTitle;
  SessionStatus get status;
  Stream<SessionStatus> get statusStream;
  void dispose();
}

/// A session drawn in a terminal view: SSH, or a serial console. Both can be
/// started again in the same tab.
abstract class TerminalSessionController implements SessionController {
  /// The xterm buffer the view renders and the keyboard writes into.
  Terminal get terminal;

  /// Starts the session again in the same tab and terminal.
  void reconnect();
}
