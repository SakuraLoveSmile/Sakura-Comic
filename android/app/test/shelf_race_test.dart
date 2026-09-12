import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:comic_app/src/library_repository.dart';
import 'package:comic_app/src/models.dart';
import 'package:comic_app/src/rust/sync/bootstrap.dart';
import 'package:comic_app/src/rust/model/server_profile.dart';
import 'package:comic_app/src/server_manager.dart';
import 'package:comic_app/src/series.dart';
import 'package:comic_app/src/series_grid.dart';

import 'fakes.dart';

void main() {
  testWidgets('a stale search response cannot replace the current search',
      (tester) async {
    final repo = ControlledShelfRepository();
    await tester.pumpWidget(_app(repo));
    final initial = repo.takeRequest();
    initial.complete(_page('initial'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'old');
    await tester.pump(const Duration(milliseconds: 351));
    final stale = repo.takeRequest();
    await tester.enterText(find.byType(TextField), 'new');
    await tester.pump(const Duration(milliseconds: 351));
    final current = repo.takeRequest();
    current.complete(_page('new-result'));
    await tester.pumpAndSettle();

    stale.complete(_page('old-result'));
    await tester.pumpAndSettle();

    expect(find.text('new-result'), findsOneWidget);
    expect(find.text('old-result'), findsNothing);
  });

  testWidgets('a stale cover response cannot overwrite the current search',
      (tester) async {
    final repo = ControlledShelfRepository(holdCovers: true);
    await tester.pumpWidget(_app(repo));
    final initial = repo.takeRequest();
    initial.complete(_page('initial'));
    await tester.pump();
    final initialCovers = repo.takeCoverRequest();
    initialCovers.complete(const {});
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'old');
    await tester.pump(const Duration(milliseconds: 351));
    final oldQuery = repo.takeRequest();
    oldQuery.complete(_page('old-result'));
    await tester.pump();
    final oldCovers = repo.takeCoverRequest();

    await tester.enterText(find.byType(TextField), 'new');
    await tester.pump(const Duration(milliseconds: 351));
    final newQuery = repo.takeRequest();
    newQuery.complete(_page('new-result'));
    await tester.pump();
    final newCovers = repo.takeCoverRequest();
    newCovers.complete(const {});
    await tester.pumpAndSettle();
    oldCovers.complete(const {'old-result': '/tmp/old-cover'});
    await tester.pumpAndSettle();

    expect(find.text('new-result'), findsOneWidget);
    expect(find.text('old-result'), findsNothing);
  });

  testWidgets('an old query completing during debounce cannot restore old data',
      (tester) async {
    final repo = ControlledShelfRepository();
    await tester.pumpWidget(_app(repo));
    final initial = repo.takeRequest();
    initial.complete(_page('initial'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'old');
    await tester.pump(const Duration(milliseconds: 351));
    final oldQuery = repo.takeRequest();
    await tester.enterText(find.byType(TextField), 'new');
    await tester.pump(const Duration(milliseconds: 200));
    oldQuery.complete(_page('old-result'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 151));
    final newQuery = repo.takeRequest();
    newQuery.complete(_page('new-result'));
    await tester.pumpAndSettle();

    expect(find.text('new-result'), findsOneWidget);
    expect(find.text('old-result'), findsNothing);
  });

  testWidgets('an old append cannot be merged after a new search starts',
      (tester) async {
    final repo = ControlledShelfRepository();
    await tester.pumpWidget(_app(repo));
    final first = repo.takeRequest();
    first.complete(_page('first', total: 2));
    await tester.pump();
    final append = repo.takeRequest();

    await tester.enterText(find.byType(TextField), 'new');
    await tester.pump(const Duration(milliseconds: 351));
    final current = repo.takeRequest();
    current.complete(_page('new-result'));
    await tester.pumpAndSettle();

    append.complete(_page('old-appended'));
    await tester.pumpAndSettle();

    expect(find.text('new-result'), findsOneWidget);
    expect(find.text('old-appended'), findsNothing);
  });

  testWidgets('a filter change invalidates a pending append', (tester) async {
    final repo = ControlledShelfRepository(statuses: const ['已读']);
    await tester.pumpWidget(_app(repo));
    final first = repo.takeRequest();
    first.complete(_page('first', total: 2));
    await tester.pump();
    final append = repo.takeRequest();

    await tester.tap(find.widgetWithText(Chip, '状态'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已读'));
    await tester.pump();
    final filtered = repo.takeRequest();
    filtered.complete(_page('filtered'));
    await tester.pumpAndSettle();
    append.complete(_page('old-appended'));
    await tester.pumpAndSettle();

    expect(find.text('filtered'), findsOneWidget);
    expect(find.text('old-appended'), findsNothing);
  });

  testWidgets('editing search again invalidates the pending debounce',
      (tester) async {
    final repo = ControlledShelfRepository();
    await tester.pumpWidget(_app(repo));
    final initial = repo.takeRequest();
    initial.complete(_page('initial'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'old');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.enterText(find.byType(TextField), 'new');
    await tester.pump(const Duration(milliseconds: 200));
    expect(repo.requests, hasLength(1));

    await tester.pump(const Duration(milliseconds: 151));
    expect(repo.requests, hasLength(2));
    expect(repo.requests.last.search, 'new');
    repo.requests.last.complete(_page('new-result'));
    await tester.pumpAndSettle();
    expect(find.text('old-result'), findsNothing);
    expect(find.text('new-result'), findsOneWidget);
  });

  testWidgets('a stale failure cannot blank a newer successful result',
      (tester) async {
    final repo = ControlledShelfRepository();
    await tester.pumpWidget(_app(repo));
    final initial = repo.takeRequest();
    initial.complete(_page('initial'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'old');
    await tester.pump(const Duration(milliseconds: 351));
    final stale = repo.takeRequest();
    await tester.enterText(find.byType(TextField), 'new');
    await tester.pump(const Duration(milliseconds: 351));
    final current = repo.takeRequest();
    current.complete(_page('new-result'));
    await tester.pumpAndSettle();

    stale.fail(StateError('old query failed'));
    await tester.pumpAndSettle();

    expect(find.text('new-result'), findsOneWidget);
    expect(find.byKey(const ValueKey('wall-error-headline')), findsNothing);
  });

  testWidgets('a failed pagination page can be retried explicitly',
      (tester) async {
    final repo = ControlledShelfRepository();
    await tester.pumpWidget(_app(repo));
    final first = repo.takeRequest();
    first.complete(_page('first', total: 2));
    await tester.pump();
    final append = repo.takeRequest();
    append.fail(StateError('page two failed'));
    await tester.pumpAndSettle();

    expect(find.text('重试加载'), findsOneWidget);
    await tester.tap(find.text('重试加载'));
    await tester.pump();
    final retry = repo.takeRequest();
    expect(retry.offset, 1);
    retry.complete(_page('second'));
    await tester.pumpAndSettle();
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsOneWidget);
    expect(find.text('重试加载'), findsNothing);
  });

  testWidgets('a pending shelf request is harmless after disposal',
      (tester) async {
    final repo = ControlledShelfRepository();
    await tester.pumpWidget(_app(repo));
    final request = repo.takeRequest();
    await tester.pumpWidget(const SizedBox.shrink());
    request.complete(_page('late-result'));
    await tester.pump();
    expect(find.text('late-result'), findsNothing);
  });

  testWidgets('replacing the repository invalidates the old server context',
      (tester) async {
    final oldRepo = ControlledShelfRepository();
    final newRepo = ControlledShelfRepository();
    await tester.pumpWidget(_app(oldRepo));
    final oldRequest = oldRepo.takeRequest();

    await tester.pumpWidget(_app(newRepo));
    await tester.pump();
    final newRequest = newRepo.takeRequest();
    newRequest.complete(_page('new-server'));
    await tester.pumpAndSettle();
    oldRequest.complete(_page('old-server'));
    await tester.pumpAndSettle();

    expect(find.text('new-server'), findsOneWidget);
    expect(find.text('old-server'), findsNothing);
  });

  testWidgets('switching through server management invalidates old results',
      (tester) async {
    final api = MemoryRustCoreApi();
    const oldProfile = ServerProfile(
      id: 'old',
      displayName: 'Old server',
      baseUrl: 'http://old',
      authType: AuthType.apiKey,
      capabilities: [],
    );
    const newProfile = ServerProfile(
      id: 'new',
      displayName: 'New server',
      baseUrl: 'http://new',
      authType: AuthType.apiKey,
      capabilities: [],
    );
    api.servers.addAll({'old': oldProfile, 'new': newProfile});
    api.activeId = 'old';
    final manager = ServerManager(
      dbPath: '/tmp/shelf-race.sqlite',
      api: api,
    );
    final repo = ControlledShelfRepository();
    await tester.pumpWidget(MaterialApp(
      home: SeriesGridScreen(repository: repo, manager: manager),
    ));
    final oldRequest = repo.takeRequest();

    await tester.tap(find.byTooltip('服务器'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New server'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pageBack();
    await tester.pump();
    final newRequest = repo.takeRequest();
    newRequest.complete(_page('new-server'));
    await tester.pump();
    repo.completePendingWith(_page('new-server'));
    await tester.pumpAndSettle();
    oldRequest.complete(_page('old-server'));
    await tester.pumpAndSettle();

    expect(find.text('new-server'), findsOneWidget);
    expect(find.text('old-server'), findsNothing);
  });
}

Widget _app(LibraryRepository repository) => MaterialApp(
      home: SeriesGridScreen(repository: repository),
    );

PagedSeries _page(String name, {int total = 1}) => PagedSeries(
      items: [Series(remoteId: name, libraryId: 'library', name: name)],
      total: total,
    );

class ControlledRequest {
  ControlledRequest(this.search, this.offset) : _completer = Completer<PagedSeries>();

  final String? search;
  final int offset;
  final Completer<PagedSeries> _completer;

  Future<PagedSeries> get future => _completer.future;

  void complete(PagedSeries page) => _completer.complete(page);

  void fail(Object error) => _completer.completeError(error);
}

class ControlledShelfRepository extends LibraryRepository {
  ControlledShelfRepository({this.holdCovers = false, this.statuses = const []});

  final bool holdCovers;
  final List<String> statuses;
  final List<ControlledRequest> requests = [];
  final List<Completer<Map<String, String>>> coverRequests = [];
  var _nextRequest = 0;

  ControlledRequest takeRequest() {
    if (_nextRequest >= requests.length) {
      throw StateError('expected a querySeries request');
    }
    return requests[_nextRequest++];
  }

  void completePendingWith(PagedSeries page) {
    while (_nextRequest < requests.length) {
      requests[_nextRequest++].complete(page);
    }
  }

  Completer<Map<String, String>> takeCoverRequest() {
    if (coverRequests.isEmpty) {
      throw StateError('expected a fetchCoverPaths request');
    }
    return coverRequests.removeAt(0);
  }

  @override
  Future<List<Series>> fetchSeries({int limit = 50, int offset = 0}) async =>
      const [];

  @override
  Future<FilterOptions> fetchFilterOptions() async =>
      FilterOptions(statuses: statuses);

  @override
  Future<PagedSeries> querySeries({
    String? search,
    String? libraryId,
    String? status,
    String? tag,
    String? genre,
    String sort = 'name',
    bool ascending = true,
    int limit = 50,
    int offset = 0,
  }) {
    final request = ControlledRequest(search, offset);
    requests.add(request);
    return request.future;
  }

  @override
  Future<Map<String, String>> fetchCoverPaths({required List<String> seriesIds}) {
    if (!holdCovers) return Future.value(const {});
    final completer = Completer<Map<String, String>>();
    coverRequests.add(completer);
    return completer.future;
  }

  @override
  Future<BootstrapSummary?> bootstrapActiveServer({bool resume = true}) async => null;

  @override
  Future<int> syncCovers() async => 0;

  @override
  Future<BootstrapSummary> loadDemo() async => BootstrapSummary(
        serverId: 'demo',
        syncedSeries: BigInt.zero,
        totalElements: 0,
        hasMorePages: false,
      );

  @override
  bool get demoSupported => false;
}
