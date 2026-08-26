import 'rust/ffi/application.dart';
import 'rust/model/server.dart';
import 'rust/model/server_profile.dart';
import 'rust/store/series.dart';
import 'rust/sync/bootstrap.dart';

/// Contract for the FFI layer mirroring
/// android/komga_core/src/ffi/bridge.rs (Phase 0 step 02).
///
/// The generated bindings in lib/src/rust/ implement this contract natively;
/// [StubRustCoreApi] exists so widget tests and host tooling can run without
/// the native library.
abstract interface class RustCoreApi {
  /// Application Facade `bootstrap` — API-key auth, mirrors the first page.
  Future<BootstrapSummary> bootstrap({
    required String dbPath,
    required String serverId,
    required String baseUrl,
    required String apiKey,
  });

  /// Connection probe (acceptance chain): authenticate + verify Komga +
  /// fetch server info + libraries + version policy check.
  Future<ConnectionResult> testConnection({
    required String baseUrl,
    required String apiKey,
  });

  Future<List<SeriesRow>> fetchSeries({
    required String dbPath,
    required String serverId,
    int limit = 50,
    int offset = 0,
  });

  Future<List<ServerProfile>> listServers({required String dbPath});

  Future<void> saveServer({required String dbPath, required ServerProfile profile});

  Future<ServerProfile?> getServer({
    required String dbPath,
    required String serverId,
  });

  /// Deletes a server profile (clears the active-server state when needed).
  Future<bool> deleteServer({required String dbPath, required String serverId});

  /// Persist libraries discovered during a successful connection.
  Future<void> saveLibraries({
    required String dbPath,
    required String serverId,
    required List<Library> libraries,
  });

  Future<void> setActiveServer({required String dbPath, required String serverId});

  Future<String?> getActiveServer({required String dbPath});
}

/// In-memory stub so tests and the fallback UI path can run without FFI.
class StubRustCoreApi implements RustCoreApi {
  const StubRustCoreApi();

  @override
  Future<BootstrapSummary> bootstrap({
    required String dbPath,
    required String serverId,
    required String baseUrl,
    required String apiKey,
  }) async =>
      BootstrapSummary(
        serverId: serverId,
        syncedSeries: BigInt.zero,
        totalElements: 0,
        hasMorePages: false,
      );

  @override
  Future<ConnectionResult> testConnection({
    required String baseUrl,
    required String apiKey,
  }) async =>
      const ConnectionResult(
        serverInfo: ServerInfo(),
        serverVersion: null,
        libraries: [],
        capabilities: [],
      );

  @override
  Future<List<SeriesRow>> fetchSeries({
    required String dbPath,
    required String serverId,
    int limit = 50,
    int offset = 0,
  }) async =>
      const [];

  @override
  Future<List<ServerProfile>> listServers({required String dbPath}) async => const [];

  @override
  Future<void> saveServer({required String dbPath, required ServerProfile profile}) async {}

  @override
  Future<ServerProfile?> getServer({
    required String dbPath,
    required String serverId,
  }) async =>
      null;

  @override
  Future<bool> deleteServer({required String dbPath, required String serverId}) async => false;

  @override
  Future<void> saveLibraries({
    required String dbPath,
    required String serverId,
    required List<Library> libraries,
  }) async {}

  @override
  Future<void> setActiveServer({required String dbPath, required String serverId}) async {}

  @override
  Future<String?> getActiveServer({required String dbPath}) async => null;
}