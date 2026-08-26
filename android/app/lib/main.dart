import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'src/library_repository.dart';
import 'src/rust_core_frb.dart';
import 'src/server_manager.dart';
import 'src/series_grid.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final (repository, manager, rustStatus) = await createServices();
  runApp(ComicApp(repository: repository, serverManager: manager, rustStatus: rustStatus));
}

/// Wires the UI to the Rust Core through flutter_rust_bridge; falls back to
/// the in-memory stub (with an explicit status banner) whenever the native
/// library cannot be loaded, so the app always launches.
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
    const api = FrbRustCoreApi();
    final manager = ServerManager(dbPath: dbPath, api: api);
    return (
      RustLibraryRepository(dbPath: dbPath, api: api, serverManager: manager),
      manager,
      'Rust core FFI 已连接',
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
  });

  final LibraryRepository repository;
  final ServerManager? serverManager;
  final String? rustStatus;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Comic',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: SeriesGridScreen(
        repository: repository,
        manager: serverManager,
        rustStatus: rustStatus,
      ),
    );
  }
}