import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'app_theme.dart';

/// The CommandS mark: a folded-paper lightning bolt on a rounded tile, drawn
/// in the theme's own colours. The shape never changes; like the S of
/// "CommandS", the bolt takes the theme's accent, and the tile its surfaces.
/// On CommandS Dark it is the same drawing as the window, taskbar and
/// installer icon (made by `tool/make_icons.py`, which also writes [asset]).
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.size = 20});
  final double size;

  /// The fixed drawing, in CommandS Dark's colours. The app draws the mark
  /// from [svgFor] instead; this file keeps the geometry on record.
  static const asset = 'assets/icon/commands_mark.svg';

  /// The geometry, in a 1024 grid, as in [asset].
  static const tileRadius = 200;
  static const upperFold = '658,61 208,602 546,602';
  static const lowerFold = '456,422 817,422 344,963';
  static const foldShadow = '456,422 584,422 546,602 418,602';

  /// The mark's colours for an [accent] on a theme with [palette].
  static MarkColors colorsFor(Color accent, AppPalette palette, Brightness brightness) {
    final hsl = HSLColor.fromColor(accent);
    HSLColor shade(double hue, double saturation, double lightness) => HSLColor.fromAHSL(
          1,
          (hsl.hue + hue) % 360,
          (hsl.saturation * saturation).clamp(0.0, 1.0),
          (hsl.lightness * lightness).clamp(0.0, 1.0),
        );
    final dark = brightness == Brightness.dark;
    return MarkColors(
      tileTop: Color.lerp(palette.panelAlt, accent, dark ? 0.04 : 0.06)!,
      tileBottom: dark ? Color.lerp(palette.bg, Colors.black, 0.15)! : Color.lerp(palette.panel, palette.border, 0.5)!,
      edge: palette.border,
      upper: accent,
      // The lower fold and the shadow where the folds overlap: the accent,
      // deeper. On CommandS Dark these come out as the icon's own reds.
      lower: shade(-7, 0.66, 0.68).toColor(),
      fold: shade(-8, 0.70, 0.47).toColor(),
    );
  }

  static String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  /// The mark as SVG in [colors].
  static String svgFor(MarkColors colors) => '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">'
      '<defs><linearGradient id="tile" x1="0" y1="0" x2="0" y2="1">'
      '<stop offset="0" stop-color="${_hex(colors.tileTop)}"/><stop offset="1" stop-color="${_hex(colors.tileBottom)}"/>'
      '</linearGradient></defs>'
      '<rect x="6" y="6" width="1012" height="1012" rx="${tileRadius - 6}" fill="url(#tile)" '
      'stroke="${_hex(colors.edge)}" stroke-width="12"/>'
      '<polygon points="$upperFold" fill="${_hex(colors.upper)}"/>'
      '<polygon points="$lowerFold" fill="${_hex(colors.lower)}"/>'
      '<polygon points="$foldShadow" fill="${_hex(colors.fold)}"/>'
      '</svg>';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = colorsFor(theme.colorScheme.primary, AppPalette.of(context), theme.brightness);
    return SvgPicture.string(svgFor(colors), width: size, height: size);
  }
}

/// The colours the mark is drawn in.
class MarkColors {
  const MarkColors({
    required this.tileTop,
    required this.tileBottom,
    required this.edge,
    required this.upper,
    required this.lower,
    required this.fold,
  });

  final Color tileTop;
  final Color tileBottom;
  final Color edge;
  final Color upper;
  final Color lower;
  final Color fold;
}
