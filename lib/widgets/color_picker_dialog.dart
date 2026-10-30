import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../services/terminal_appearance.dart';
import 'app_dialog.dart';

/// Opens a colour picker on [initial]: a saturation/brightness square, a hue
/// bar, and the colour's code, kept in step both ways. Returns the chosen
/// colour, or null if cancelled.
Future<Color?> showColorPicker(BuildContext context, {required Color initial, required String title}) {
  return showDialog<Color>(
    context: context,
    builder: (_) => _ColorPickerDialog(initial: initial, title: title),
  );
}

class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({required this.initial, required this.title});
  final Color initial;
  final String title;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial.withAlpha(255));
  late final _code = TextEditingController(text: colorToHex(widget.initial));
  bool _invalid = false;

  Color get _color => _hsv.toColor();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  /// From the square or the bar: the code follows.
  void _setHsv(HSVColor hsv) {
    setState(() {
      _hsv = hsv;
      _code.text = colorToHex(_color);
      _invalid = false;
    });
  }

  /// From the code: the square and bar follow, keeping the hue when the
  /// colour is grey (where it has none).
  void _setCode(String text) {
    final c = parseColorCode(text);
    setState(() {
      _invalid = c == null && text.trim().isNotEmpty;
      if (c != null) {
        final next = HSVColor.fromColor(c);
        _hsv = next.saturation == 0 ? next.withHue(_hsv.hue) : next;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = _color;
    final r = (c.r * 255).round(), g = (c.g * 255).round(), b = (c.b * 255).round();
    return AppDialog(
      title: tr(widget.title),
      icon: Icons.palette_outlined,
      width: 380,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            key: const ValueKey('color-square'),
            height: 190,
            child: _SaturationValueBox(hsv: _hsv, onChanged: _setHsv),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 18,
            child: _HueBar(hue: _hsv.hue, onChanged: (h) => _setHsv(_hsv.withHue(h))),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: c,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Theme.of(context).dividerColor),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  key: const ValueKey('color-code'),
                  controller: _code,
                  onChanged: _setCode,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    labelText: tr('Color code'),
                    helperText: 'rgb($r, $g, $b)',
                    errorText: _invalid ? tr('Use #RRGGBB, #RGB or rgb(r, g, b)') : null,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
        ElevatedButton(onPressed: () => Navigator.pop(context, c), child: Text(tr('Use'))),
      ],
    );
  }
}

/// Saturation left to right, brightness bottom to top, for the current hue.
class _SaturationValueBox extends StatelessWidget {
  const _SaturationValueBox({required this.hsv, required this.onChanged});
  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        void pick(Offset p) {
          final s = (p.dx / box.maxWidth).clamp(0.0, 1.0);
          final v = 1 - (p.dy / box.maxHeight).clamp(0.0, 1.0);
          onChanged(hsv.withSaturation(s).withValue(v));
        }

        return GestureDetector(
          onPanDown: (d) => pick(d.localPosition),
          onPanUpdate: (d) => pick(d.localPosition),
          child: MouseRegion(
            cursor: SystemMouseCursors.precise,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Colors.white, HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor()],
                        ),
                      ),
                    ),
                  ),
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: hsv.saturation * box.maxWidth - 8,
                    top: (1 - hsv.value) * box.maxHeight - 8,
                    child: IgnorePointer(
                      child: Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                          boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 3)],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The hue, 0 to 360 degrees, left to right.
class _HueBar extends StatelessWidget {
  const _HueBar({required this.hue, required this.onChanged});
  final double hue;
  final ValueChanged<double> onChanged;

  static final _rainbow = [
    for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1, h.toDouble() % 360, 1, 1).toColor(),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        void pick(Offset p) => onChanged((p.dx / box.maxWidth).clamp(0.0, 1.0) * 359.9);
        return GestureDetector(
          onPanDown: (d) => pick(d.localPosition),
          onPanUpdate: (d) => pick(d.localPosition),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(9),
                      gradient: LinearGradient(colors: _rainbow),
                    ),
                  ),
                ),
                Positioned(
                  left: hue / 360 * box.maxWidth - 9,
                  top: 0,
                  child: IgnorePointer(
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 3)],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
