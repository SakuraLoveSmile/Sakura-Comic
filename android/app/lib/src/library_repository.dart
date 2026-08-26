import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import 'rust/model/server_profile.dart';
import 'rust/store/series.dart';
import 'rust/sync/bootstrap.dart';
import 'rust_core_api.dart';
import 'rust_core_frb.dart';
import 'series.dart';
import 'server_manager.dart';

/// Gateway between UI and Rust Core.
///
/// Phase 0: [StubLibraryRepository] keeps the UI testable without FFI;
/// [RustLibraryRepository] talks to komga_core through the generated
/// flutter_rust_bridge bindings. The UI only reads the local store — network
/// is confined to the sync/cover methods below (Local First).
abstract interface class LibraryRepository {
  Future<List<Series>> fetchSeries({int limit = 50, int offset = 0});

  /// Cover file paths for the active server, resolved from SQLite
  /// (remote_id → local path). Missing covers are rendered as placeholders.
  Future<Map<String, String>> fetchCoverPaths();

  /// Pulls the first Series page into SQLite and backfills covers for the
  /// active server. Returns null when no server (or credential) exists.
  Future<BootstrapSummary?> bootstrapActiveServer();

  /// Backfills covers for series without a usable record (缓存缺失自动补齐).
  Future<int> syncCovers();

  /// Offline demo: seeds fixture series + generated covers (no server).
  Future<BootstrapSummary> loadDemo();

  /// Whether the repository can seed the demo wall (FFI-backed only).
  bool get demoSupported;

  Stream<List<Series>> observeSeries();
}

/// In-memory stub so the grid UI can be built and tested before FFI lands.
class StubLibraryRepository implements LibraryRepository {
  const StubLibraryRepository();

  @override
  Future<List<Series>> fetchSeries({int limit = 50, int offset = 0}) async => const [];

  @override
  Future<Map<String, String>> fetchCoverPaths() async => const {};

  @override
  Future<BootstrapSummary?> bootstrapActiveServer() async => null;

  @override
  Future<int> syncCovers() async => 0;

  @override
  Future<BootstrapSummary> loadDemo() async => _emptySummary('demo');

  @override
  bool get demoSupported => false;

  @override
  Stream<List<Series>> observeSeries() => const Stream.empty();

  static BootstrapSummary _emptySummary(String serverId) => BootstrapSummary(
        serverId: serverId,
        syncedSeries: BigInt.zero,
        totalElements: 0,
        hasMorePages: false,
      );
}

/// Rust Core-backed repository (multi-server): reads the active server
/// profile from SQLite via the FFI bridge (falling back to the first
/// profile), then mirrors its series rows.
class RustLibraryRepository implements LibraryRepository {
  RustLibraryRepository({
    required this.dbPath,
    RustCoreApi? api,
    ServerManager? serverManager,
  })  : _api = api ?? const FrbRustCoreApi(),
        _serverManager = serverManager;

  final String dbPath;
  final RustCoreApi _api;

  /// Provides credentials (Keystore) for sync/cover backfill; may be null
  /// in test setups where the wall only renders local data.
  final ServerManager? _serverManager;

  @override
  Future<List<Series>> fetchSeries({int limit = 50, int offset = 0}) async {
    final serverId = await _activeServerId();
    if (serverId == null) {
      debugPrint('[RustCore] listServers -> 0 servers (grid stays empty)');
      return const [];
    }
    final rows = await _api.fetchSeries(
      dbPath: dbPath,
      serverId: serverId,
      limit: limit,
      offset: offset,
    );
    debugPrint('[RustCore] fetchSeries("$serverId") -> ${rows.length} rows');
    return rows.map(SeriesRowToSeries.toSeries).toList();
  }

  @override
  Future<Map<String, String>> fetchCoverPaths() async {
    final serverId = await _activeServerId();
    if (serverId == null) return const {};
    final rows = await _api.listThumbnails(dbPath: dbPath, serverId: serverId);
    return {for (final row in rows) row.remoteId: row.localPath};
  }

  @override
  Future<BootstrapSummary?> bootstrapActiveServer() async {
    final credential = await _activeCredential();
    if (credential == null) return null;
    final (profile, apiKey) = credential;
    final summary = await _api.bootstrap(
      dbPath: dbPath,
      serverId: profile.id,
      baseUrl: profile.baseUrl,
      apiKey: apiKey,
    );
    debugPrint('[RustCore] bootstrap("${profile.id}") -> ${summary.syncedSeries} series');
    await syncCovers();
    return summary;
  }

  @override
  Future<int> syncCovers() async {
    final credential = await _activeCredential();
    if (credential == null) return 0;
    final (profile, apiKey) = credential;
    final n = await _api.ensureCovers(
      dbPath: dbPath,
      serverId: profile.id,
      baseUrl: profile.baseUrl,
      apiKey: apiKey,
    );
    debugPrint('[RustCore] ensureCovers("${profile.id}") -> $n backfilled');
    return n;
  }

  @override
  Future<BootstrapSummary> loadDemo() async {
    const serverId = 'demo';
    final summary = await _api.bootstrapDemo(dbPath: dbPath, serverId: serverId);
    await _api.setActiveServer(dbPath: dbPath, serverId: serverId);
    debugPrint('[RustCore] bootstrapDemo -> ${summary.syncedSeries} series');
    return summary;
  }

  @override
  bool get demoSupported => true;

  @override
  Stream<List<Series>> observeSeries() {
    return Stream.periodic(const Duration(seconds: 15), (_) => null).asyncMap(
      (_) async {
        try {
          return await fetchSeries();
        } catch (_) {
          return const <Series>[];
        }
      },
    );
  }

  /// The profile to display: the active server, else the first one.
  Future<String?> _activeServerId() async {
    final servers = await _api.listServers(dbPath: dbPath);
    if (servers.isEmpty) return null;
    final activeId = await _api.getActiveServer(dbPath: dbPath);
    return activeId ?? servers.first.id;
  }

  /// (profile, apiKey) for the active server — or null when unavailable
  /// (no server / no stored secret).
  Future<(ServerProfile, String)?> _activeCredential() async {
    final manager = _serverManager;
    if (manager == null) return null;
    final servers = await _api.listServers(dbPath: dbPath);
    if (servers.isEmpty) return null;
    final activeId = await _api.getActiveServer(dbPath: dbPath);
    final profile =
        servers.firstWhere((s) => s.id == (activeId ?? servers.first.id), orElse: () => servers.first);
    final ref = profile.credentialRef;
    if (ref == null) return null;
    final secret = await manager.readSecret(ref);
    if (secret == null) return null;
    return (profile, secret);
  }
}

/// Maps the FFI mirror of the Rust `SeriesRow` to the UI model.
abstract final class SeriesRowToSeries {
  static Series toSeries(SeriesRow row) => Series(
        remoteId: row.remoteId,
        libraryId: row.libraryId,
        name: row.name,
        status: row.status,
      );
}