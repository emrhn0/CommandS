import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';

const _bgPresets = [
  Color(0xFF14161A), // CommandS default
  Color(0xFF000000), // pure black
  Color(0xFF0C0C0C), // Windows Terminal black
  Color(0xFF1E1E1E), // VS Code dark
  Color(0xFF002B36), // Solarized dark
  Color(0xFFFDF6E3), // Solarized light
  Color(0xFFFFFFFF), // white
];

const _fgPresets = [
  Color(0xFFE8E6E1), // CommandS default
  Color(0xFFFFFFFF), // white
  Color(0xFF00FF00), // classic green phosphor
  Color(0xFFC9973A), // amber
  Color(0xFF839496), // Solarized body
  Color(0xFF000000), // black (for light backgrounds)
];

/// Small, focused settings popup — just the SSH terminal's own colors, not
/// a whole preferences screen. Applies live and persists immediately.
Future<void> showTerminalAppearanceDialog(BuildContext context) {
  return showDialog(context: context, builder: (_) => const _TerminalAppearanceDialog());
}

class _TerminalAppearanceDialog extends StatefulWidget {
  const _TerminalAppearanceDialog();

  @override
  State<_TerminalAppearanceDialog> createState() => _TerminalAppearanceDialogState();
}

class _TerminalAppearanceDialogState extends State<_TerminalAppearanceDialog> {
  late Color _bg;
  late Color _fg;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _bg = app.terminalBackground;
    _fg = app.terminalForeground;
  }

  void _apply() {
    context.read<AppState>().setTerminalColors(background: _bg, foreground: _fg);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Terminal appearance', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              Container(
                height: 60,
                decoration: BoxDecoration(color: _bg, border: Border.all(color: Colors.black26)),
                alignment: Alignment.center,
                child: Text('user@host:~\$ ls -la', style: TextStyle(color: _fg, fontFamily: 'monospace', fontSize: 13)),
              ),
              const SizedBox(height: 16),
              const Text('Background', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              _Swatches(colors: _bgPresets, selected: _bg, onPick: (c) => setState(() { _bg = c; _apply(); })),
              const SizedBox(height: 16),
              const Text('Text', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              _Swatches(colors: _fgPresets, selected: _fg, onPick: (c) => setState(() { _fg = c; _apply(); })),
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Swatches extends StatelessWidget {
  const _Swatches({required this.colors, required this.selected, required this.onPick});
  final List<Color> colors;
  final Color selected;
  final ValueChanged<Color> onPick;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final c in colors)
          GestureDetector(
            onTap: () => onPick(c),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected.toARGB32() == c.toARGB32() ? Theme.of(context).colorScheme.primary : Colors.black26,
                  width: selected.toARGB32() == c.toARGB32() ? 2.5 : 1,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
