import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The CommandS mark: a folded-paper lightning bolt on a warm dark tile. The
/// same drawing as the window, taskbar and installer icon (all made by
/// `tool/make_icons.py`), and the same on every theme, light or dark.
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.size = 20});
  final double size;

  static const asset = 'assets/icon/commands_mark.svg';

  @override
  Widget build(BuildContext context) => SvgPicture.asset(asset, width: size, height: size);
}
