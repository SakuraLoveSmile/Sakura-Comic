import 'dart:io';

import 'package:comic_app/src/preview/downloads_screen.dart';
import 'package:comic_app/src/preview/models.dart';
import 'package:comic_app/src/preview/preview_app.dart';
import 'package:comic_app/src/preview/preview_data.dart';
import 'package:comic_app/src/preview/reader_screen.dart';
import 'package:comic_app/src/preview/series_detail_screen.dart';
import 'package:comic_app/src/preview/shelf_screen.dart';
import 'package:comic_app/src/preview/shelf_toolbar.dart';
import 'package:comic_app/src/preview/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Structural checks for the P1 prototype.
///
/// The prototype is a design artifact, so these tests do not try to pin its
/// pixels. They pin the things that make a screenshot review trustworthy:
/// every screen mounts at the three widths and three text scales the milestone
/// names, no layout overflows, and the milestone's *rules* — the primary
/// button's four cases, the next-volume ordering, the failed-page retry — are
/// real behaviour rather than a picture of behaviour.
void main() {
  const widths = <double>[360, 393, 412];
  const scales = <double>[1.0, 1.3, 2.0];

  group('prototype mounts at the sizes the milestone names', () {
    for (final width in widths) {
      for (final scale in scales) {
        testWidgets('shelf at ${width.toInt()}px / text $scale',
            (tester) async {
          await _pump(
            tester,
            width: width,
            scale: scale,
            child: Builder(
              builder: (context) => ShelfScreen(
                series: previewSeries(),
                scenario: ShelfScenario.normal,
                tools: ShelfToolsState(),
                settings: PreviewGlobalSettings(),
                onChanged: () {},
                onOpenSeries: (_) {},
                onContinueReading: (_, __) {},
                onOpenSettings: () {},
                onOpenServers: () {},
                onOpenLibraries: () {},
              ),
            ),
          );
          expect(find.text('继续阅读'), findsOneWidget);
          expect(find.text('水星领航员'), findsWidgets);
        });
      }
    }

    testWidgets('series detail at 393px / text 1.3', (tester) async {
      final series = previewSeries().first;
      await _pump(
        tester,
        width: 393,
        scale: 1.3,
        child: SeriesDetailScreen(
          series: series,
          settings: PreviewGlobalSettings(),
          overrides: const {},
          onOpenBook: (_, {required fromFirstPage, required viaReread}) {},
          onBack: () {},
        ),
      );
      expect(find.text('继续阅读'), findsOneWidget);
      expect(find.textContaining('打开 第 4 卷'), findsOneWidget);
    });

    testWidgets('downloads at 412px / text 2.0', (tester) async {
      await _pump(
        tester,
        width: 412,
        scale: 2.0,
        child: Builder(
          builder: (context) => PreviewDownloadsScreen(
            downloads: previewDownloads(previewSeries()),
            onChanged: () {},
            onOpenBook: (_) {},
            onOpenSeries: (_) {},
          ),
        ),
      );
      expect(find.text('下载队列'), findsOneWidget);
    });

    testWidgets('reader single page and webtoon at 393px', (tester) async {
      final series = previewSeries().first;
      for (final mode in ['single', 'double', 'webtoon']) {
        await _pump(
          tester,
          width: 393,
          scale: 1.0,
          child: PreviewReaderScreen(
            session: PreviewReaderSession(
              series: series,
              book: series.orderedBooks[3],
              initialPage: 62,
              mode: mode,
              direction: 'ltr',
              globalMode: 'single',
              globalDirection: 'ltr',
            ),
            settings: PreviewGlobalSettings(),
            onExit: (_) {},
            onOpenNext: (_) {},
          ),
        );
        expect(find.byType(Scaffold), findsWidgets,
            reason: 'mode $mode mounted');
      }
    });

    testWidgets('the whole shell mounts, including the four tabs',
        (tester) async {
      await _pump(tester, width: 393, scale: 1.0, child: const PreviewApp());
      expect(find.text('书架'), findsWidgets);
      expect(find.text('合集'), findsWidgets);
      expect(find.text('书单'), findsWidgets);
      expect(find.text('下载'), findsWidgets);
    });

    testWidgets('release-mode entry refuses to start the prototype',
        (tester) async {
      // The guard itself is what matters: a release binary must not open the
      // preview. The check is on the source, because `kReleaseMode` is false in
      // every test run.
      final source = File('lib/main_preview.dart').readAsStringSync();
      expect(source.contains('if (kReleaseMode)'), isTrue);
      expect(source.contains('_PreviewDisabled'), isTrue);
    });
  });

  group('milestone rules hold in the prototype model', () {
    test('the primary button follows the four cases', () {
      final series = previewSeries();

      final inProgress = series.firstWhere((s) => s.seriesId == 's-aria');
      expect(inProgress.readIntent, ReadIntent.continueReading);
      // The most recently read unfinished book wins, not the earliest.
      expect(inProgress.primaryBook!.bookId, 'b-aria-04');

      final unread = series.firstWhere((s) => s.seriesId == 's-nonnon');
      expect(unread.readIntent, ReadIntent.startReading);
      expect(unread.primaryBook!.title, '第 1 卷');

      final read = series.firstWhere((s) => s.seriesId == 's-yotsuba');
      expect(read.readIntent, ReadIntent.reread);
      expect(read.primaryBook!.title, '第 1 卷');

      final empty = series.firstWhere((s) => s.seriesId == 's-empty');
      expect(empty.readIntent, ReadIntent.empty);
      expect(empty.primaryBook, isNull);
    });

    test('book order is numbered first, then number_sort, title, remote id',
        () {
      final dupes = previewSeries().firstWhere((s) => s.seriesId == 's-dupes');
      expect(
        dupes.orderedBooks.map((b) => b.bookId).toList(),
        ['b-dupe-a', 'b-dupe-c', 'b-dupe-b', 'b-dupe-d'],
        reason:
            'number 1 ties break case-insensitively: "extra a" before "Extra B"',
      );
      expect(dupes.orderedBooks.last.bookId, 'b-dupe-d',
          reason: 'no number sorts last');
    });

    test('a next book exists only when the series really has one', () {
      final series = previewSeries();
      final complete = series.firstWhere((s) => s.seriesId == 's-nonnon');
      expect(complete.nextAfter(complete.orderedBooks[2])!.title, '第 4 卷');

      final last = complete.orderedBooks.last;
      expect(complete.nextAfter(last), isNull);
      expect(complete.isProvenLast(last), isTrue,
          reason: 'complete mirror proves the end');

      final incomplete = series.firstWhere((s) => s.seriesId == 's-incomplete');
      final tail = incomplete.orderedBooks.last;
      expect(incomplete.nextAfter(tail), isNull);
      expect(
        incomplete.isProvenLast(tail),
        isFalse,
        reason: 'an incomplete mirror must never claim the series ended',
      );
      expect(incomplete.incompleteNotice, '本地目录尚未完整同步');
    });

    test('a partially downloaded series never reads as downloaded', () {
      final series = previewSeries();
      final aria = series.firstWhere((s) => s.seriesId == 's-aria');
      final summary = aria.downloadSummary;
      expect(summary.hasAny, isTrue);
      expect(summary.downloaded, 2);
      expect(summary.partial, 2,
          reason: 'paused and failed are not "downloaded"');
      expect(summary.label, contains('未完成'));

      final none = series.firstWhere((s) => s.seriesId == 's-nonnon');
      expect(none.downloadSummary.label, isNull,
          reason: 'nothing downloadable says nothing');
    });

    test('volume keys are off by default', () {
      expect(PreviewGlobalSettings().volumeKeysEnabled, isFalse);
    });

    test('the theme is dark-only and covers the token scale', () {
      final theme = comicTheme();
      expect(theme.brightness, Brightness.dark);
      expect(ComicTokens.spaceXs, 8);
      expect(ComicTokens.spaceSm, 12);
      expect(ComicTokens.spaceMd, 16);
      expect(ComicTokens.spaceLg, 24);
      expect(ComicTokens.minTouchTarget, 48);
      expect(ComicTokens.coverAspectRatio, closeTo(2 / 3, 0.0001));
    });
  });

  test('a series with finished volumes reads as 继续阅读, not 开始阅读', () {
    // The case a naive "is anything in progress?" check gets wrong: volume 2
    // is finished, volume 3 has no progress, nothing is in progress — and the
    // user is plainly mid-series. The core's series_read_target agrees.
    final blame = previewSeries().firstWhere((s) => s.seriesId == 's-blame');
    expect(blame.books.any((b) => b.inProgress), isFalse,
        reason: 'the fixture has no part-read volume');
    expect(blame.readIntent, ReadIntent.continueReading);
    expect(blame.primaryBook?.bookId, 'b-blame-03',
        reason: 'and it opens the first unread volume, not volume 1');
  });

  test('a series nobody has touched reads as 开始阅读', () {
    final nonnon = previewSeries().firstWhere((s) => s.seriesId == 's-nonnon');
    expect(nonnon.readIntent, ReadIntent.startReading);
    expect(nonnon.primaryBook?.bookId, nonnon.orderedBooks.first.bookId);
  });

  test('a fully read series reads as 重新阅读', () {
    final yotsuba =
        previewSeries().firstWhere((s) => s.seriesId == 's-yotsuba');
    expect(yotsuba.readIntent, ReadIntent.reread);
  });

  test('an empty series has no primary book at all', () {
    final empty = previewSeries().firstWhere((s) => s.seriesId == 's-empty');
    expect(empty.readIntent, ReadIntent.empty);
    expect(empty.primaryBook, isNull);
  });

  group('reader behaviour', () {
    testWidgets('a centre tap toggles the toolbars and does not turn the page',
        (tester) async {
      final series = previewSeries().first;
      final book = series.orderedBooks[3];
      await _pump(
        tester,
        width: 393,
        scale: 1.0,
        child: PreviewReaderScreen(
          session: PreviewReaderSession(
            series: series,
            book: book,
            initialPage: 62,
            mode: 'single',
            direction: 'ltr',
            globalMode: 'single',
            globalDirection: 'ltr',
          ),
          settings: PreviewGlobalSettings(),
          onExit: (_) {},
          onOpenNext: (_) {},
        ),
      );

      expect(find.textContaining('第 62 页'), findsNothing,
          reason: 'toolbars start hidden');

      // A centre tap shows them. The extra settle is the double-tap window the
      // reader has to wait out before it may treat a tap as a single tap — the
      // same window the milestone insists must not turn a page either.
      await tester.tapAt(const Offset(196, 300));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('第 62 页'), findsOneWidget);
      expect(find.text('62 / 190'), findsNWidgets(2),
          reason:
              'page caption + toolbar both say 62 / 190 after a centre tap');

      await tester.tapAt(const Offset(196, 300));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('第 62 页'), findsNothing,
          reason: 'second tap hides them again');
    });
  });
}

/// Pumps one widget at a fixed logical size and text scale, and fails the test
/// if the framework reported an overflow, a failed assertion or an exception —
/// which is the whole point of running the prototype at 360/393/412 and
/// 1.0/1.3/2.0.
Future<void> _pump(
  WidgetTester tester, {
  required double width,
  required double scale,
  required Widget child,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(width, width * 2.2);
  addTearDown(tester.view.reset);

  final errors = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    errors.add(details);
    previous?.call(details);
  };
  addTearDown(() => FlutterError.onError = previous);

  // Only MediaQuery's text scaler is set here — the same thing the OS does.
  // Scaling the theme's font sizes too (comicTheme(textScale:)) would double
  // the effect and invent overflows the real app never has, which is exactly
  // how a "layout problem" turns out to be a bad test.
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: MaterialApp(
        theme: comicTheme(),
        home: child,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 16));

  final overflow = errors.where(
    (e) =>
        e.exception.toString().contains('overflowed') ||
        e.exception.toString().contains('RenderFlex'),
  );
  expect(overflow, isEmpty,
      reason: 'layout overflowed:\n${overflow.join('\n')}');
  expect(errors, isEmpty, reason: 'framework errors:\n${errors.join('\n')}');
}
