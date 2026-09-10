import 'package:flutter/material.dart';

/// The CommandS mark: the ⌘ (Command) key glyph in gold on a sharp-cornered
/// charcoal tile, thin bronze bezel — a pun on the app's name, matching the
/// window/taskbar icon.
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.size = 20});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset('assets/icon/commands_mark.png', width: size, height: size);
  }
}
