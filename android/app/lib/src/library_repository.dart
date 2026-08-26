import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import 'rust/store/series.dart';
import 'rust_core_api.dart';
import 'rust_core_frb.dart';
import 'series.dart';

/// Gateway between UI and Rust Core.
///
/// Phase 0: [StubLibraryRepository] keeps the UI testable without FFI;
/// [RustLibraryRepository] talks to komga_core through the generated
/// flutter_rust_bridge bindings.
abstract interface class LibraryRepository {
  Future<List<Series>> fetchSeries({int limit = 50, int offset = 0});

  Stream<List<Series>> observeSeries();
}

/// In-memory stub so the grid UI can be built and tested before FFI lands.
class StubLibraryRepository implements LibraryRepository {
  const StubLibraryRepository();

  @override
  Future<List<Series>> fetchSeries({int limit = 50, int offset = 0}) async => const [];

  @override
  Stream<List<Series>> observeSeries() => const Stream.empty();
}

/// Rust Core-backed repository (multi-server): reads the active server
/// profile from SQLite via the FFI bridge (falling back to the first
/// profile), then mirrors its series rows.
class RustLibraryRepository implements LibraryRepository {
  RustLibraryRepository({required this.dbPath, RustCoreApi? api})
      : _api = api ?? const FrbRustCoreApi();

  final String dbPath;
  final RustCoreApi _api;

  @override
  Future<List<Series>> fetchSeries({int limit = 50, int offset = 0}) async {
    final servers = await _api.listServers(dbPath: dbPath);
    if (servers.isEmpty) {
      debugPrint('[RustCore] listServers -> 0 servers (grid stays empty)');
      return const [];
    }
    final activeId = await _api.getActiveServer(dbPath: dbPath);
    final serverId = activeId ?? servers.first.id;
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