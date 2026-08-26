import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:comic_app/main.dart';
import 'package:comic_app/src/library_repository.dart';
import 'package:comic_app/src/series.dart';
import 'package:comic_app/src/series_grid.dart';

void main() {
  testWidgets('scaffold renders', (tester) async {
    await tester.pumpWidget(const ComicApp());
    expect(find.text('Library'), findsOneWidget);
  });

  testWidgets('grid shows rows from repository', (tester) async {
    final repo = _FakeRepository();
    await tester.pumpWidget(MaterialApp(home: SeriesGridScreen(repository: repo)));
    await tester.pumpAndSettle();
    expect(find.text('One Piece'), findsOneWidget);
    expect(find.text('Berserk'), findsOneWidget);
  });

  testWidgets('rust status banner renders when provided', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: SeriesGridScreen(
        rustStatus: 'Rust core FFI 已连接',
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Rust core FFI 已连接'), findsOneWidget);
  });
}

class _FakeRepository implements LibraryRepository {
  @override
  Future<List<Series>> fetchSeries({int limit = 50, int offset = 0}) async => const [
        Series(remoteId: 's1', libraryId: 'lib-1', name: 'One Piece'),
        Series(remoteId: 's2', libraryId: 'lib-1', name: 'Berserk'),
      ];

  @override
  Stream<List<Series>> observeSeries() => const Stream.empty();
}
