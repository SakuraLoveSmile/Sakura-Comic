import 'package:flutter_test/flutter_test.dart';

import 'package:comic_app/src/library_repository.dart';
import 'package:comic_app/src/rust/model/server_profile.dart';
import 'package:comic_app/src/server_manager.dart';

import 'fakes.dart';

/// How the repository resolves "which server am I talking to".
///
/// One shelf refresh asks nine times (five loaders, some resolving it more than
/// once), and each ask used to be two FFI round trips — `listServers` plus
/// `getActiveServer` — with no memo. That was 18 of the ~27 round trips a single
/// refresh cost, on top of every other query it issued.
void main() {
  ServerProfile profile(String id) => ServerProfile(
        id: id,
        displayName: id,
        baseUrl: 'http://127.0.0.1:25600',
        authType: AuthType.apiKey,
        capabilities: const [],
      );

  /// The methods the shelf's loaders call, in one burst.
  Future<void> shelfRefresh(RustLibraryRepository repo) async {
    await Future.wait([
      repo.fetchSyncStatus(),
      repo.fetchFilterOptions(),
      repo.fetchLibraryCounts(),
      repo.continueReading(),
      repo.listCollections(),
      repo.listReadlists(),
      repo.fetchCoverPaths(seriesIds: const []),
      repo.fetchCredentialState(),
    ]);
    await repo.querySeries();
    await repo.fetchSeries();
  }

  test('a whole refresh resolves the active server twice, not per query',
      () async {
    final api = MemoryRustCoreApi();
    api.servers['srv-1'] = profile('srv-1');
    api.activeId = 'srv-1';
    final repo = RustLibraryRepository(dbPath: '/tmp/x.sqlite', api: api);

    await shelfRefresh(repo);

    expect(
      api.activeServerProbes,
      2,
      reason: 'one listServers plus one getActiveServer for the whole refresh, '
          'not two per query (10 queries would be 20). '
          'list=${api.listServersCalls} active=${api.getActiveServerCalls}',
    );

    // And it stays warm: a second refresh costs nothing more.
    await shelfRefresh(repo);
    expect(api.activeServerProbes, 2);
    // Each refresh issues four series queries — `querySeries()` and `fetchSeries()`
    // (which delegates to it) per refresh — which is the work the memo is meant to
    // leave untouched. They are queries; resolving the server is not.
    expect(api.querySeriesCalls, 4);
  });

  test('switching the active server is picked up, not cached forever',
      () async {
    final api = MemoryRustCoreApi();
    api.servers['srv-1'] = profile('srv-1');
    api.servers['srv-2'] = profile('srv-2');
    api.activeId = 'srv-1';
    final manager = ServerManager(dbPath: '/tmp/x.sqlite', api: api);
    final repo = RustLibraryRepository(
      dbPath: '/tmp/x.sqlite',
      api: api,
      serverManager: manager,
    );

    await repo.fetchSeries();
    expect(api.lastQueryServerId, 'srv-1');

    // The manager is the funnel every route goes through.
    await manager.switchTo(serverId: 'srv-2');
    await repo.fetchSeries();

    expect(api.lastQueryServerId, 'srv-2',
        reason: 'a stale memo would keep querying the old server');
  });

  test('deleting the active server is picked up too', () async {
    final api = MemoryRustCoreApi();
    api.servers['srv-1'] = profile('srv-1');
    api.activeId = 'srv-1';
    final manager = ServerManager(dbPath: '/tmp/x.sqlite', api: api);
    final repo = RustLibraryRepository(
      dbPath: '/tmp/x.sqlite',
      api: api,
      serverManager: manager,
    );

    await repo.fetchSeries();
    expect(api.lastQueryServerId, 'srv-1');

    await manager.delete(serverId: 'srv-1');
    api.querySeriesCalls = 0;
    await repo.fetchSeries();

    expect(api.querySeriesCalls, 0,
        reason:
            'no active server means no query, not a query against a dead id');
  });

  test('a missing server is not cached as a permanent absence', () async {
    // Caching `null` would outlive the user adding their first server, and the
    // shelf would stay empty until the app was restarted.
    final api = MemoryRustCoreApi();
    final repo = RustLibraryRepository(dbPath: '/tmp/x.sqlite', api: api);

    await repo.fetchSeries();
    expect(api.querySeriesCalls, 0, reason: 'no server yet');

    api.servers['srv-1'] = profile('srv-1');
    api.activeId = 'srv-1';
    await repo.fetchSeries();

    expect(api.lastQueryServerId, 'srv-1',
        reason: 'the absence must not have been memoized as final');
  });

  test('the demo id resolves even though it has no servers row', () async {
    final api = MemoryRustCoreApi()..activeId = 'demo';
    final repo = RustLibraryRepository(dbPath: '/tmp/x.sqlite', api: api);

    await repo.fetchSeries();

    expect(api.lastQueryServerId, 'demo');
  });

  test('a page request forwards limit and offset, and fetches once', () async {
    // The abstract default used to call `fetchSeries()` twice and report the page
    // length as the library total, so paging was never exercised through it.
    final api = MemoryRustCoreApi();
    api.servers['srv-1'] = profile('srv-1');
    api.activeId = 'srv-1';
    final repo = RustLibraryRepository(dbPath: '/tmp/x.sqlite', api: api);

    await repo.querySeries(limit: 50, offset: 50);

    expect(api.querySeriesCalls, 1, reason: 'one query, not two');
    expect(api.lastQueryLimit, 50);
    expect(api.lastQueryOffset, 50);
  });
}
