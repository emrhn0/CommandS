import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The CommandS mark: the ⌘ (Command) key glyph on a rounded tile, its middle
/// square filled red as a terminal cursor. The same drawing as the window,
/// taskbar and installer icon (all made by `tool/make_icons.py`).
///
/// It follows the theme so the tile stands out from the bar behind it: the
/// light tile on a dark theme, the dark tile on a light one.
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.size = 20});
  final double size;

  static const lightAsset = 'assets/icon/commands_mark_light.svg';
  static const darkAsset = 'assets/icon/commands_mark_dark.svg';

  /// The asset drawn under a theme of [brightness].
  static String assetFor(Brightness brightness) =>
      brightness == Brightness.dark ? lightAsset : darkAsset;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      assetFor(Theme.of(context).brightness),
      width: size,
      height: size,
    );
  }
}
