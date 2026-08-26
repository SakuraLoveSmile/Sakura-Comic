import 'rust/ffi/bridge.dart' as frb;
import 'rust/frb_generated.dart';
import 'rust/model/server_profile.dart';
import 'rust/store/series.dart';
import 'rust/sync/bootstrap.dart';
import 'rust_core_api.dart';

/// Tries to load the native library (`libkomga_core.so`).
///
/// Returns `false` when the library is unavailable (widget tests, host runs
/// without a cargo-ndk build) — callers then fall back to the stub
/// repository so the UI still renders.
Future<bool> initRustCore() async {
  try {
    await RustLib.init();
    return true;
  } catch (_) {
    return false;
  }
}

/// [RustCoreApi] backed by the generated flutter_rust_bridge bindings
/// (lib/src/rust/). Keep signatures aligned with
/// android/komga_core/src/ffi/bridge.rs.
class FrbRustCoreApi implements RustCoreApi {
  const FrbRustCoreApi();

  @override
  Future<BootstrapSummary> bootstrap({
    required String dbPath,
    required String serverId,
    required String baseUrl,
    required String apiKey,
  }) {
    return frb.bootstrap(
      dbPath: dbPath,
      serverId: serverId,
      baseUrl: baseUrl,
      apiKey: apiKey,
    );
  }

  @override
  Future<List<SeriesRow>> fetchSeries({
    required String dbPath,
    required String serverId,
    int limit = 50,
    int offset = 0,
  }) {
    return frb.fetchSeries(
      dbPath: dbPath,
      serverId: serverId,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<List<ServerProfile>> listServers({required String dbPath}) {
    return frb.listServers(dbPath: dbPath);
  }

  @override
  Future<void> saveServer({
    required String dbPath,
    required ServerProfile profile,
  }) {
    return frb.saveServer(dbPath: dbPath, profile: profile);
  }
}