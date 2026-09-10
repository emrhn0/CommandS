import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'providers/app_state.dart';
import 'screens/home_screen.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(900, 600),
      title: 'CommandS',
      // Replaced by CustomTitleBar — the native caption only showed the OS
      // accent color (orange here) behind plain system buttons, nothing
      // like the rest of the app.
      titleBarStyle: TitleBarStyle.hidden,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  runApp(const CommandSApp());
}

class CommandSApp extends StatelessWidget {
  const CommandSApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState(),
      child: Consumer<AppState>(
        builder: (context, app, _) => MaterialApp(
          title: 'CommandS',
          debugShowCheckedModeBanner: false,
          themeMode: app.themeMode,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          home: const HomeScreen(),
        ),
      ),
    );
  }
}
