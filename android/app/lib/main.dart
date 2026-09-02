import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'src/download_stress.dart';
import 'src/library_repository.dart';
import 'src/reader_stress.dart';
import 'src/rust_core_frb.dart';
import 'src/server_manager.dart';
import 'src/series_grid.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final (repository, manager, rustStatus) = await createServices();
  // Printed because the stress entry depends on it: this is the only way to see
  // which intent extra the platform actually turned into the initial route.
  debugPrint('BOOT route=${WidgetsBinding.instance.platformDispatcher.defaultRouteName}');
  runApp(ComicApp(
    repository: repository,
    serverManager: manager,
    rustStatus: rustStatus,
    initialRoute: WidgetsBinding.instance.platformDispatcher.defaultRouteName,
  ));
}

/// Wires the UI to the Rust Core through flutter_rust_bridge; falls back to
/// the in-memory stub whenever the native library cannot be loaded, so the app
/// always launches.
///
/// The returned status string is *problem copy only*: null means the real core
/// is connected and serving, and the shelf shows no banner. A non-null value
/// names the failure mode (stub / init error) so the UI can say the app is
/// running without its native core.
Future<(LibraryRepository, ServerManager?, String?)> createServices() async {
  if (!await initRustCore()) {
    debugPrint('[RustCore] init failed — using StubRustCoreApi');
    return (
      const StubLibraryRepository(),
      null,
      'Rust core 未加载（Stub 模式）',
    );
  }
  try {
    final docs = await getApplicationDocumentsDirectory();
    final dbPath = '${docs.path}/comic.sqlite';
    debugPrint('[RustCore] FFI connected (libkomga_core loaded), db=$dbPath');
    final api = FrbRustCoreApi();
    final manager = ServerManager(dbPath: dbPath, api: api);
    return (
      RustLibraryRepository(dbPath: dbPath, api: api, serverManager: manager),
      manager,
      // Healthy: no banner. The wall itself is the signal that the real core
      // is serving — the banner exists for the degraded modes only.
      null,
    );
  } catch (_) {
    debugPrint('[RustCore] init error — using StubRustCoreApi');
    return (
      const StubLibraryRepository(),
      null,
      'Rust core 初始化失败（Stub 模式）',
    );
  }
}

class ComicApp extends StatelessWidget {
  const ComicApp({
    super.key,
    this.repository = const StubLibraryRepository(),
    this.serverManager,
    this.rustStatus,
    this.initialRoute = '/',
  });

  final LibraryRepository repository;
  final ServerManager? serverManager;
  final String? rustStatus;
  final String initialRoute;

  /// The Stage 8 device acceptance entry. `am start --es route /reader-stress…`
  /// is the only way this screen is reachable; any other route launches the app
  /// exactly as before. It drives the real reader, so what a device run measures
  /// is the reading path itself and not a copy of it.
  Widget get _home {
    final stress = ReaderStressParams.parse(initialRoute);
    if (stress != null) return ReaderStressScreen(params: stress);
    // The Stage 9 entry, same shape: only this route reaches it.
    final download = DownloadStressParams.parse(initialRoute);
    if (download != null) return DownloadStressScreen(params: download);
    return SeriesGridScreen(
      repository: repository,
      manager: serverManager,
      rustStatus: rustStatus,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Comic',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: _home,
    );
  }
}