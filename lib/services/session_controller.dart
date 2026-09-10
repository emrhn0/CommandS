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
