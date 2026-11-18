/// Offers the enable password only after this session's user runs `enable`.
/// Output is untrusted: a matching prompt never sends the password by itself.
class EnablePromptWatcher {
  EnablePromptWatcher({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  static const window = Duration(seconds: 30);
  static final _ansi = RegExp(
    r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])',
  );
  static final _prompt = RegExp(
    r'^(?:(?:enter|enable)\s+)?password(?:\s+for\s+enable)?\s*:\s*$',
    caseSensitive: false,
  );
  static final _switchPrompt = RegExp(r'^[\w.:-]{1,64}[#>]\s*$');

  final DateTime Function() _clock;
  String _input = '';
  String _tail = '';
  DateTime? _armedAt;
  bool _offered = false;
  bool _lastWasCr = false;

  /// Track the command actually typed, including one-character keyboard input.
  void input(String data) {
    for (final ch in data.runes.map(String.fromCharCode)) {
      if (ch == '\n' && _lastWasCr) {
        _lastWasCr = false;
        continue;
      }
      _lastWasCr = ch == '\r';
      if (ch == '\r' || ch == '\n') {
        final enable = _input.trim().toLowerCase() == 'enable';
        _input = '';
        _tail = '';
        _armedAt = enable ? _clock() : null;
        _offered = false;
      } else if (ch == '\b' || ch == '\x7f') {
        if (_input.isNotEmpty) _input = _input.substring(0, _input.length - 1);
        _armedAt = null;
      } else if (ch == '\x1b' || ch == '\x03' || ch == '\x04') {
        reset();
      } else if (ch.codeUnitAt(0) >= 0x20) {
        _armedAt = null;
        _input = '$_input$ch';
        if (_input.length > 80) _input = _input.substring(_input.length - 80);
      }
    }
  }

  /// Returns the live prompt, or null when it is absent or has moved on.
  String? feed(String text) {
    final armedAt = _armedAt;
    if (armedAt == null) return null;
    if (_clock().difference(armedAt) > window) {
      reset();
      return null;
    }
    _tail += text;
    if (_tail.length > 1024) _tail = _tail.substring(_tail.length - 1024);
    final clean = _tail.replaceAll(_ansi, '');
    final lastBreak = clean.lastIndexOf(RegExp(r'[\r\n]'));
    final line = clean.substring(lastBreak + 1);
    if (line.length <= 80 && _prompt.hasMatch(line)) {
      _offered = true;
      return line.trim();
    }
    if (_switchPrompt.hasMatch(line) || (_offered && text.contains(RegExp(r'[\r\n]')))) {
      reset();
    }
    return null;
  }

  void dismiss() => reset();

  void reset() {
    _input = '';
    _tail = '';
    _armedAt = null;
    _offered = false;
    _lastWasCr = false;
  }
}
