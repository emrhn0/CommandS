/// What a line of login output asks of the app.
sealed class LoginEvent {
  const LoginEvent();
}

/// A yes/no question from the server, to put to the user.
class LoginQuestion extends LoginEvent {
  const LoginQuestion(this.text);
  final String text;
}

/// The password prompt that follows a question, to answer with the saved one.
class LoginPasswordPrompt extends LoginEvent {
  const LoginPasswordPrompt();
}

/// Reads terminal output during login for a yes/no question (a firewall's
/// banner acknowledgement) that reached the terminal, and the password prompt
/// after it.
///
/// A logged-in device can print anything, so the saved password is only ever
/// sent to a prompt that is: worded with OpenSSH's own `(user@host)` prefix for
/// this connection, right after such a question was answered with something
/// other than no, the first of its kind, and early in the session.
class LoginWatcher {
  LoginWatcher({required String user, required String host, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now,
      _started = (clock ?? DateTime.now)(),
      _question = RegExp(
        '\\(${RegExp.escape('$user@$host')}\\)\\s*([\\s\\S]{0,300}?\\(yes/no\\)[^\\r\\n]*?)\\s*\$',
        caseSensitive: false,
      ),
      _password = RegExp(
        '\\(${RegExp.escape('$user@$host')}\\)\\s*[^\\r\\n]{0,40}?password:\\s*\$',
        caseSensitive: false,
      );

  /// Long enough for someone to read the banner and answer; after this it is
  /// no longer login.
  static const window = Duration(minutes: 3);

  static const _tailLimit = 1024;
  static final _ansi = RegExp(r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])');

  final DateTime Function() _clock;
  final DateTime _started;
  final RegExp _question;
  final RegExp _password;

  String _tail = '';
  bool _asked = false;
  bool _done = false;

  /// The user said no: nothing more to answer.
  void declined() => _done = true;

  /// The next thing asked for, if [text] ends on a prompt.
  LoginEvent? feed(String text) {
    if (_done) return null;
    if (_clock().difference(_started) > window) {
      _done = true;
      return null;
    }
    _tail += text.replaceAll(_ansi, '');
    if (_tail.length > _tailLimit) _tail = _tail.substring(_tail.length - _tailLimit);

    if (!_asked) {
      final m = _question.firstMatch(_tail);
      if (m == null) return null;
      _asked = true;
      _tail = '';
      return LoginQuestion(m.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim());
    }
    if (_password.hasMatch(_tail)) {
      _done = true;
      return const LoginPasswordPrompt();
    }
    return null;
  }
}
