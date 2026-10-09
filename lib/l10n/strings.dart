import 'package:flutter/widgets.dart';

import 'tr.dart';

/// The languages the app's own text comes in. English is the default; the
/// rest of the UI's wording is looked up from English.
enum AppLanguage {
  en('English'),
  tr('Türkçe');

  const AppLanguage(this.label);

  /// Always written in the language itself, so it can be found from any.
  final String label;

  static AppLanguage fromCode(String? code) =>
      AppLanguage.values.firstWhere((l) => l.name == code, orElse: () => AppLanguage.en);
}

/// The language the app is currently showing. Set through
/// [AppState.setLanguage], which also redraws every screen.
AppLanguage currentLanguage = AppLanguage.en;

/// Translates one piece of UI text. The English wording is the key, so a
/// string with no translation (or English itself) shows as written.
/// `{name}` placeholders are filled from [args] after translating, so the
/// translation can put them where its grammar needs them.
String tr(String english, [Map<String, Object?> args = const {}]) {
  var s = currentLanguage == AppLanguage.tr ? (turkish[english] ?? english) : english;
  args.forEach((k, v) => s = s.replaceAll('{$k}', '$v'));
  return s;
}

/// "1 connection" / "3 connections" -- English needs the plural, Turkish
/// does not ("1 bağlantı" / "3 bağlantı").
String trCount(int n, String one, String many) => tr(n == 1 ? one : many, {'n': n});

/// Redraws every widget, including the `const` ones a normal rebuild skips
/// -- their text comes from [tr], which they cannot know has changed.
void rebuildAllWidgets() {
  void mark(Element e) {
    e.markNeedsBuild();
    e.visitChildren(mark);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(mark);
}
