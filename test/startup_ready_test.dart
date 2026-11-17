import 'package:commands/providers/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // main() waits for AppState.ready before the first frame, so the window is
  // never drawn in the default light theme and then repainted (a white flash
  // at every start). That only works if ready means "the saved state is in".
  test('ready completes once the saved theme and connections are read', () async {
    SharedPreferences.setMockInitialValues({
      'commands.themeId': 'builtin:dracula',
      'commands.themeMode': 'dark',
    });
    final app = AppState();
    expect(app.themeId, isNull, reason: 'nothing read yet right after creating it');
    await app.ready;
    expect(app.themeId, 'builtin:dracula');
    expect(app.themeMode, ThemeMode.dark);
  });
}
