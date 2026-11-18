import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../l10n/strings.dart';
import '../theme/app_theme.dart';

/// One place [findInTerminal] found the text: a buffer row and the columns
/// it covers, end excluded.
class TerminalSearchMatch {
  const TerminalSearchMatch(this.row, this.start, this.end);
  final int row;
  final int start;
  final int end;

  @override
  bool operator ==(Object other) =>
      other is TerminalSearchMatch && other.row == row && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(row, start, end);

  @override
  String toString() => 'match($row, $start-$end)';
}

/// Every place [query] appears in [terminal]'s buffer, scrollback included,
/// top to bottom, ignoring case.
List<TerminalSearchMatch> findInTerminal(Terminal terminal, String query) {
  final needle = query.toLowerCase();
  if (needle.isEmpty) return const [];
  final lines = terminal.buffer.lines;
  final matches = <TerminalSearchMatch>[];
  for (var row = 0; row < lines.length; row++) {
    final text = lines[row].getText().toLowerCase();
    var from = 0;
    while (true) {
      final at = text.indexOf(needle, from);
      if (at < 0) break;
      matches.add(TerminalSearchMatch(row, at, at + needle.length));
      from = at + needle.length;
    }
  }
  return matches;
}

/// Search in a terminal: a small magnifier at the pane's top right that
/// widens into a search field (also Ctrl+Shift+F). Every match is marked in
/// the terminal, the current one stronger, with its number and the total.
/// Enter and the arrows move between them; Esc closes it.
class TerminalSearch extends StatefulWidget {
  const TerminalSearch({
    super.key,
    required this.terminal,
    required this.controller,
    required this.scroll,
    required this.lineHeight,
    required this.open,
    required this.onClosed,
  });

  final Terminal terminal;
  final TerminalController controller;
  final ScrollController scroll;
  final double lineHeight;

  /// Opened by the button or the shortcut, closed by Esc or the close button.
  final ValueNotifier<bool> open;

  /// Gives the keyboard back to the terminal.
  final VoidCallback onClosed;

  @override
  State<TerminalSearch> createState() => _TerminalSearchState();
}

class _TerminalSearchState extends State<TerminalSearch> {
  final _field = TextEditingController();
  final _fieldFocus = FocusNode();
  List<TerminalSearchMatch> _matches = const [];
  int _current = -1;
  final List<TerminalHighlight> _highlights = [];
  Timer? _refresh;
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    widget.open.addListener(_openChanged);
    widget.terminal.addListener(_terminalChanged);
  }

  @override
  void dispose() {
    widget.open.removeListener(_openChanged);
    widget.terminal.removeListener(_terminalChanged);
    _refresh?.cancel();
    _clearHighlights();
    _field.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  void _openChanged() {
    if (!mounted) return;
    setState(() {});
    if (widget.open.value) {
      // The field appears once the bar has widened.
      Future.delayed(const Duration(milliseconds: 180), () {
        if (!mounted || !widget.open.value) return;
        _fieldFocus.requestFocus();
        _field.selection = TextSelection(baseOffset: 0, extentOffset: _field.text.length);
      });
      if (_field.text.isNotEmpty) _search(keepPlace: true);
    } else {
      _clearHighlights();
    }
  }

  /// New output while searching: the marks follow, at most a few times a
  /// second, so a busy session is not slowed down.
  void _terminalChanged() {
    if (!widget.open.value || _field.text.isEmpty || _refresh != null) return;
    _refresh = Timer(const Duration(milliseconds: 300), () {
      _refresh = null;
      if (mounted && widget.open.value) _search(keepPlace: true, scroll: false);
    });
  }

  void _clearHighlights() {
    for (final h in _highlights) {
      h.dispose();
    }
    _highlights.clear();
  }

  void _search({bool keepPlace = false, bool scroll = true}) {
    final previous = _current >= 0 && _current < _matches.length ? _matches[_current] : null;
    final matches = findInTerminal(widget.terminal, _field.text);
    var current = matches.isEmpty ? -1 : matches.length - 1;
    if (keepPlace && previous != null) {
      final same = matches.indexOf(previous);
      if (same >= 0) current = same;
    }
    setState(() {
      _matches = matches;
      _current = current;
    });
    _mark(scroll: scroll);
  }

  void _move(int by) {
    if (_matches.isEmpty) return;
    setState(() => _current = (_current + by) % _matches.length);
    _mark();
  }

  void _mark({bool scroll = true}) {
    _clearHighlights();
    final accent = Theme.of(context).colorScheme.primary;
    final lines = widget.terminal.buffer.lines;
    for (var i = 0; i < _matches.length; i++) {
      final m = _matches[i];
      if (m.row >= lines.length) continue;
      final line = lines[m.row];
      _highlights.add(widget.controller.highlight(
        p1: line.createAnchor(m.start),
        p2: line.createAnchor(m.end),
        color: i == _current ? accent.withValues(alpha: 0.75) : const Color(0xFFFFC83D).withValues(alpha: 0.35),
      ));
    }
    if (scroll && _current >= 0) _scrollTo(_matches[_current].row);
  }

  void _scrollTo(int row) {
    if (!widget.scroll.hasClients) return;
    final p = widget.scroll.position;
    final top = row * widget.lineHeight;
    final bottom = top + widget.lineHeight;
    if (top >= p.pixels && bottom <= p.pixels + p.viewportDimension) return;
    final to = (top - p.viewportDimension / 2).clamp(p.minScrollExtent, p.maxScrollExtent);
    widget.scroll.jumpTo(to);
  }

  void _close() {
    widget.open.value = false;
    widget.onClosed();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _move(HardwareKeyboard.instance.isShiftPressed ? 1 : -1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final open = widget.open.value;
    final count = _field.text.isEmpty
        ? ''
        : _matches.isEmpty
            ? tr('No results')
            : '${_current + 1}/${_matches.length}';
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        key: const Key('terminal-search'),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        width: open ? 340 : 30,
        height: 30,
        decoration: BoxDecoration(
          color: open ? palette.panel : palette.panel.withValues(alpha: _hover ? 0.95 : 0.6),
          border: Border.all(color: open ? theme.colorScheme.primary.withValues(alpha: 0.6) : palette.border),
          borderRadius: BorderRadius.circular(15),
          boxShadow: open ? const [BoxShadow(color: Color(0x33000000), blurRadius: 10, offset: Offset(0, 3))] : null,
        ),
        clipBehavior: Clip.antiAlias,
        // While it widens, the field waits until there is room for it.
        child: LayoutBuilder(builder: (context, box) => open && box.maxWidth >= 300
            ? Row(
                children: [
                  const SizedBox(width: 10),
                  Icon(Icons.search, size: 16, color: palette.textDim),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Focus(
                      onKeyEvent: _onKey,
                      child: TextField(
                        key: const Key('terminal-search-field'),
                        controller: _field,
                        focusNode: _fieldFocus,
                        style: TextStyle(fontSize: 13, color: palette.text),
                        cursorHeight: 14,
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          hintText: tr('Search in terminal'),
                          hintStyle: TextStyle(fontSize: 13, color: palette.textDim),
                          contentPadding: const EdgeInsets.symmetric(vertical: 8),
                        ),
                        onChanged: (_) => _search(),
                      ),
                    ),
                  ),
                  Text(
                    count,
                    key: const Key('terminal-search-count'),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: _field.text.isNotEmpty && _matches.isEmpty ? theme.colorScheme.error : palette.textDim,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  _SmallButton(icon: Icons.keyboard_arrow_up, tooltip: tr('Previous'), onTap: () => _move(-1)),
                  _SmallButton(icon: Icons.keyboard_arrow_down, tooltip: tr('Next'), onTap: () => _move(1)),
                  _SmallButton(icon: Icons.close, tooltip: tr('Close search (Esc)'), onTap: _close),
                  const SizedBox(width: 4),
                ],
              )
            : open
                ? Center(child: Icon(Icons.search, size: 16, color: palette.textDim))
                : Tooltip(
                message: tr('Search in terminal (Ctrl+Shift+F)'),
                child: InkWell(
                  key: const Key('terminal-search-open'),
                  onTap: () => widget.open.value = true,
                  child: Center(
                    child: Icon(Icons.search, size: 16, color: _hover ? palette.text : palette.textDim),
                  ),
                ),
              )),
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(icon, size: 16, color: AppPalette.of(context).textDim),
          ),
        ),
      );
}
