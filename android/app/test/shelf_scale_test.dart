import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:comic_app/src/series.dart';
import 'package:comic_app/src/series_grid.dart';

import 'fakes.dart';

/// The shelf wall at library scale.
///
/// These assertions are integers, not timings, and they are what keeps the wall
/// lazy. The bug they pin: the wall used to be a `GridView.builder` with
/// `shrinkWrap: true` nested in a `ListView`, and `_loadMore()` fires from
/// `itemBuilder`. A shrink-wrapping viewport lays out *every* child to measure
/// itself, so `itemBuilder` ran for every index on every rebuild — the
/// pre-fetch re-triggered itself until the whole library was loaded and built.
/// On a 10,000-series library that is 200 sequential page queries, 10,000 tiles
/// and 10,000 full-size cover decodes before the user touches anything.
///
/// Default test surface is 800x600 logical. At the default grid density
/// (`maxCrossAxisExtent: 140`, spacing 12) six tiles fit per row at ~191 px per
/// row, so a 600 px viewport plus the 600 px `cacheExtent` mounts roughly 40
/// tiles. The `< 60` bound below leaves room for that arithmetic to drift a
/// little without going vacuous — what it must never again say is 5,000.
void main() {
  List<Series> buildLibrary(int count) => [
        for (var i = 0; i < count; i++)
          Series(
            remoteId: 's${i.toString().padLeft(4, '0')}',
            libraryId: 'lib-1',
            name: 'Series $i',
          ),
      ];

  testWidgets('the wall builds the viewport, not the library', (tester) async {
    final repo = PagingFakeRepository(buildLibrary(5000));
    await tester
        .pumpWidget(MaterialApp(home: SeriesGridScreen(repository: repo)));
    await tester.pumpAndSettle();

    // A: mounted tiles are bounded by the viewport, not by the library.
    expect(find.byType(SeriesWallTile).evaluate().length, lessThan(60));

    // B: the first paint asked for page 1 and nothing else. Under the old
    // shrinkWrap grid this was 100 entries — the whole library, drained before
    // the user scrolled a pixel.
    expect(repo.pageRequests, [(50, 0)]);

    // And it asked for covers for that page's fifty series — not for the
    // library. The whole-server answer used to decode one row and `stat()` one
    // file per series *and* per book, on every load.
    expect(repo.coverIdRequests, hasLength(1));
    expect(repo.coverIdRequests.single, hasLength(50));
    expect(repo.coverIdRequests.single.first, 's0000');

    // D: the total still comes from the server, not from the size of one page.
    // Without this, A could be "fixed" by making `total` report `items.length`.
    expect(find.textContaining('共 5000 个 Series'), findsOneWidget);
  });

  testWidgets('scrolling loads exactly one more page', (tester) async {
    final repo = PagingFakeRepository(buildLibrary(5000));
    await tester
        .pumpWidget(MaterialApp(home: SeriesGridScreen(repository: repo)));
    await tester.pumpAndSettle();

    // Far enough to bring the pre-fetch index (length - 5) into the built
    // range, and no further: one drag must mean one page.
    await tester.drag(
        find.byKey(const ValueKey('shelf-list')), const Offset(0, -4000));
    await tester.pumpAndSettle();

    // C: the trigger moved with laziness intact, and is not firing per-rebuild.
    expect(repo.pageRequests.length, 2);
    expect(repo.pageRequests.last, (50, 50));

    // And the second page asked for its own fifty covers, not for the hundred
    // now loaded. Re-asking for everything already on screen is what turns one
    // scroll into a library-sized decode.
    expect(repo.coverIdRequests, hasLength(2));
    expect(repo.coverIdRequests.last, hasLength(50));
    expect(repo.coverIdRequests.last.first, 's0050');
  });

  testWidgets('pagination still reaches the end of the library',
      (tester) async {
    final repo = PagingFakeRepository(buildLibrary(5000));
    await tester
        .pumpWidget(MaterialApp(home: SeriesGridScreen(repository: repo)));
    await tester.pumpAndSettle();

    // E: the wall must still be able to walk to the last series. Without this,
    // A could be satisfied by breaking infinite scroll instead of fixing it.
    //
    // Hand-rolled rather than `scrollUntilVisible`: that helper resolves the
    // target element after its loop and throws an opaque "No element" when the
    // target is a tile that has not been built yet. The loop is bounded so a
    // regression fails the assertion below instead of hanging the suite.
    final shelf = find.byKey(const ValueKey('shelf-list'));
    final lastTile = find.byKey(const ValueKey('series-tile-s4999'));
    var drags = 0;
    while (drags < 500 && lastTile.evaluate().isEmpty) {
      await tester.drag(shelf, const Offset(0, -4000));
      await tester.pump();
      drags++;
    }
    await tester.pumpAndSettle();

    expect(lastTile, findsOneWidget);
    expect(repo.pageRequests.length, 100);
  });
}
