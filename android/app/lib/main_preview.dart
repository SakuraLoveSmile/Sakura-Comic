// P1 prototype entry point.
//
// Run it with:
//   flutter run -t lib/main_preview.dart -d <device>
//
// This entry point exists to get the milestone's visual design approved before
// any of it touches the real application. It therefore:
//   * never initialises the Rust core, never opens the database, never reads a
//     credential and never issues a network request — everything it draws comes
//     from `src/preview/preview_data.dart`;
//   * is refused in a release build, so it can never become a second way into
//     the app that ships;
//   * is not referenced by `main.dart`, which stays the only production entry.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/preview/preview_app.dart';
import 'src/preview/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (kReleaseMode) {
    // A release binary must never start the prototype: it has no core, no
    // database, and no business pretending to be the app.
    runApp(const _PreviewDisabled());
    return;
  }
  // The shipped app is portrait-only; the prototype is too, so a review cannot
  // be misled by a layout that only exists in landscape.
  SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(const PreviewRoot());
}

/// The prototype's own MaterialApp: dark-only, with the theme parameters from
/// `theme.dart` — the same file the production theme will be built from.
class PreviewRoot extends StatelessWidget {
  const PreviewRoot({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Comic 原型',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: comicTheme(),
      theme: comicTheme(),
      home: const PreviewApp(),
    );
  }
}

class _PreviewDisabled extends StatelessWidget {
  const _PreviewDisabled();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('预览入口在 release 构建中被禁用。', textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }
}
