import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'src/library_repository.dart';
import 'src/rust_core_frb.dart';
import 'src/series_grid.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final (repository, rustStatus) = await createRepository();
  runApp(ComicApp(repository: repository, rustStatus: rustStatus));
}

/// Wires the UI to the Rust Core through flutter_rust_bridge; falls back to
/// the in-memory stub (with an explicit status banner) whenever the native
/// library cannot be loaded, so the app always launches.
Future<(LibraryRepository, String?)> createRepository() async {
  if (!await initRustCore()) {
    debugPrint('[RustCore] init failed — using StubLibraryRepository');
    return (const StubLibraryRepository(), 'Rust core 未加载（Stub 模式）');
  }
  try {
    final docs = await getApplicationDocumentsDirectory();
    final dbPath = '${docs.path}/comic.sqlite';
    debugPrint('[RustCore] FFI connected (libkomga_core loaded), db=$dbPath');
    return (RustLibraryRepository(dbPath: dbPath), 'Rust core FFI 已连接');
  } catch (_) {
    debugPrint('[RustCore] init error — using StubLibraryRepository');
    return (const StubLibraryRepository(), 'Rust core 初始化失败（Stub 模式）');
  }
}

class ComicApp extends StatelessWidget {
  const ComicApp({super.key, this.repository = const StubLibraryRepository(), this.rustStatus});

  final LibraryRepository repository;
  final String? rustStatus;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Comic',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: SeriesGridScreen(repository: repository, rustStatus: rustStatus),
    );
  }
}