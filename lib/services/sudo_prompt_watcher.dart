/// Recognizes a small set of sudo password prompts at the live output tail.
/// A remote host can print arbitrary text, so detection only offers an action;
/// it never sends a password on its own.
class SudoPromptWatcher {
  static final _ansi = RegExp(
    r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])',
  );
  static final _prompt = RegExp(
    r'^\s*(?:\[sudo(?:\s*:\s*[^\]\r\n]{1,40})?\]\s*|sudo\s+)'
    r'(?:password|parola|şifre|parolası)'
    r'(?:\s+for\s+[^:\r\n]{1,64})?\s*:\s*$',
    caseSensitive: false,
  );

  String _tail = '';
  bool _dismissed = false;

  /// Returns the current prompt, or null when the output has moved past it.
  String? feed(String text) {
    if (text.contains('\r') || text.contains('\n')) _dismissed = false;
    _tail += text;
    if (_tail.length > 1024) _tail = _tail.substring(_tail.length - 1024);
    final clean = _tail.replaceAll(_ansi, '');
    final lastBreak = clean.lastIndexOf(RegExp(r'[\r\n]'));
    final line = clean.substring(lastBreak + 1);
    if (line.length > 180 || !_prompt.hasMatch(line)) return null;
    return _dismissed ? null : line.trim();
  }

  /// Do not re-offer the same live prompt after a manual dismissal or fill.
  void dismiss() => _dismissed = true;

  void reset() {
    _tail = '';
    _dismissed = false;
  }
}
