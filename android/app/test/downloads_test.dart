import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:comic_app/src/download_controller.dart';
import 'package:comic_app/src/downloads_api.dart';
import 'package:comic_app/src/downloads_screen.dart';
import 'package:comic_app/src/rust/ffi/application.dart';

/// The facts the controller asks the platform for. Both answers are recorded, so a
/// test can assert the core was told what the device said rather than a constant.
class _Facts {
  String link = 'unmetered';
  int free = 1 << 30;
  int linkReads = 0;
  int freeReads = 0;

  Future<String> readLink() async {
    linkReads += 1;
    return link;
  }

  Future<int> readFree() async {
    freeReads += 1;
    return free;
  }
}

/// Screen tests use a ticker that will not fire inside the test's fake clock: the
/// interval is a fixture here, not the behaviour under test, and a repeating timer
/// made `pumpAndSettle` chase frames for nothing.
DownloadController _controller(
  InMemoryDownloadsApi api,
  _Facts facts, {
  Duration interval = const Duration(seconds: 1),
}) =>
    DownloadController(
      api,
      link: facts.readLink,
      freeBytes: facts.readFree,
      interval: interval,
    );

Future<void> _mount(WidgetTester tester, DownloadController controller) async {
  await tester
      .pumpWidget(MaterialApp(home: DownloadsScreen(controller: controller)));
  await tester.pumpAndSettle();
}

/// The fake, plus the one count these screen tests need: emptying a whole server
/// is the only call in this API that can wipe the device in one tap, so a test
/// that cannot tell it from a single delete cannot pin the entry point.
class _BulkAwareApi extends InMemoryDownloadsApi {
  _BulkAwareApi({super.books});

  int removeAllCalls = 0;

  @override
  Future<DownloadDeleteDto> removeAll() async {
    removeAllCalls += 1;
    return super.removeAll();
  }
}

/// A local database that will not answer the first time and does the second.
/// That is the shape of the failure the screen used to answer with 「还没有下载」.
/// A pump that fails the way a bridge or a locked database would: the turn
/// itself breaks, so there is no report to read a stop reason from.
class _ThrowingPumpApi extends InMemoryDownloadsApi {
  _ThrowingPumpApi({super.books});

  @override
  Future<DownloadPumpDto?> pump({
    int maxPages = 0,
    int maxBytes = 0,
    int freeBytes = 0,
    String link = 'unknown',
  }) async =>
      throw StateError('bridge closed');
}

class _FlakyListApi extends InMemoryDownloadsApi {
  _FlakyListApi({super.books});

  /// How many reads still fail before the database answers.
  int failures = 1;

  @override
  Future<List<DownloadBookDto>> list() async {
    if (failures > 0) {
      failures -= 1;
      throw StateError('database is locked');
    }
    return super.list();
  }
}

void main() {  group('泵：一个回合做有界的几步', () {
    test('一个回合串起多个 pass，直到队列没有进展', () async {
      final api = InMemoryDownloadsApi(
        books: [
          FakeDownload(bookId: 'b1', title: 'One Piece #1', pagesTotal: 10)
        ],
      )..pumpPages = 2;
      final facts = _Facts();
      final controller = _controller(api, facts);
      await controller.enqueue('b1');

      await controller.pumpTurn();
      // 10 pages at 2 per pass is 5 passes. The turn is what chains them; the
      // per-pass bound is what the core enforces. Neither is the other's job.
      expect(api.pumpCalls, 5);
      expect(controller.books.single.state, 'completed');
      expect(controller.books.single.pagesDone, 10);
      expect(facts.linkReads, 1,
          reason: 'the link is read once per turn, not per pass');
      expect(facts.freeReads, greaterThan(0));
      expect(controller.lastPump?.queueActive, isFalse);
      expect(controller.hasWork, isFalse,
          reason: 'a finished queue must not claim work');
      controller.stop();
    });

    test('回合有上限，40 页的书不在一个回合里跑完', () async {
      final api = InMemoryDownloadsApi(
        books: [FakeDownload(bookId: 'b1', title: 'Book', pagesTotal: 40)],
      )..pumpPages = 2;
      final controller = _controller(api, _Facts());
      await controller.enqueue('b1');
      await controller.pumpTurn();
      expect(api.pumpCalls, 8,
          reason: 'the turn ceiling, not the queue length');
      expect(controller.books.single.pagesDone, 16);
      expect(controller.hasWork, isTrue);
      expect(controller.pumping, isFalse,
          reason: 'the turn must not leave itself busy');
      controller.stop();
    });

    test('链路中断按核心的节拍退避', () async {
      final api = InMemoryDownloadsApi(
        books: [FakeDownload(bookId: 'b1', title: 'Book')],
      )..nextStop = 'linkDown';
      final controller = _controller(api, _Facts());
      await controller.pumpTurn();
      expect(controller.stopReason, 'linkDown');
      expect(controller.periodicDelay, const Duration(seconds: 2),
          reason: 'the backoff is the core\'s number, read from its report');
      api.nextStop = '';
      await controller.pumpTurn();
      expect(controller.periodicDelay, const Duration(seconds: 1));
      controller.stop();
    });

    test('有活可干时，链路类型与剩余空间是问出来的而不是写死的', () async {
      // A queued book, because that is the condition: an empty queue must not probe
      // the platform at all, which the case below pins from the other side.
      final api = InMemoryDownloadsApi(
        books: [FakeDownload(bookId: 'b1', title: 'Book', pagesTotal: 4)],
      );
      final facts = _Facts()
        ..link = 'metered'
        ..free = 12345;
      final controller = _controller(api, facts);
      await controller.pumpTurn();
      expect(api.lastLink, 'metered');
      expect(api.lastFreeBytes, 12345);
      controller.stop();
    });

    test('空队列不去问平台，也不去动核心', () async {
      final api = InMemoryDownloadsApi();
      final facts = _Facts();
      final controller = _controller(api, facts);
      await controller.pumpTurn();
      expect(facts.linkReads, 0, reason: 'no work, so no question to ask');
      expect(facts.freeReads, 0);
      expect(api.pumpCalls, 0,
          reason: 'a no-op pass is not evidence of a live queue');
      expect(controller.hasWork, isFalse);
    });

    test('一个回合并不会踩另一个', () async {
      final api = InMemoryDownloadsApi(
        books: [FakeDownload(bookId: 'b1', title: 'Book', pagesTotal: 40)],
      );
      final controller = _controller(api, _Facts());
      await controller.enqueue('b1');
      final before = api.pumpCalls;
      await Future.wait([controller.pumpTurn(), controller.pumpTurn()]);
      // The second call saw the busy flag and returned without pumping. Without the
      // guard both would drive the same queue and the progress bar would jump.
      expect(api.pumpCalls - before, lessThan(9), reason: 'one turn, not two');
      expect(controller.pumping, isFalse);
      controller.stop();
    });
  });

  group('用户动作', () {
    test('暂停只发 pause，绝不发 delete', () async {
      final api = InMemoryDownloadsApi(
        books: [FakeDownload(bookId: 'b1', title: 'Book', pagesTotal: 6)],
      );
      final controller = _controller(api, _Facts());
      await controller.enqueue('b1');
      await controller.pause('b1');
      expect(api.pauseCalls, 1);
      expect(api.deleteCalls, 0,
          reason: 'a pause that deletes is the worst bug here');
      expect(controller.books.single.state, 'paused');

      await controller.resumeBook('b1');
      expect(api.resumeCalls, 1);
      expect(controller.books.single.state, 'waiting');
      controller.stop();
    });

    test('重试只重排队失败的页', () async {
      final api = InMemoryDownloadsApi(
        books: [
          FakeDownload(
            bookId: 'bad',
            title: 'Book',
            pagesTotal: 10,
            state: 'failed',
            pagesDone: 7,
          )
        ],
      );
      final controller = _controller(api, _Facts());
      await controller.refresh();
      expect(controller.books.single.pagesDone, 7);
      await controller.retry('bad');
      expect(api.retryCalls, 1);
      expect(controller.books.single.state, 'waiting');
      expect(controller.books.single.pagesDone, 7,
          reason: 'a retry that resets progress re-downloads seven pages');
      controller.stop();
    });
  });

  group('屏幕说的是人话', () {
    testWidgets('进度报的是页和字节，不只是百分比', (tester) async {
      final api = InMemoryDownloadsApi(
        books: [
          FakeDownload(
              bookId: 'b1',
              title: 'One Piece #1',
              pagesTotal: 10,
              pagesDone: 4,
              bytesTotal: 10000)
        ],
      );
      final controller =
          _controller(api, _Facts(), interval: const Duration(hours: 1));
      await controller.refresh(withStorage: true);
      await _mount(tester, controller);
      expect(find.textContaining('已下载 4/10 页'), findsOneWidget);
      expect(find.text('排队中'), findsOneWidget);
      // The whole line, not just the byte figure: the storage card above shows the
      // same number and a `textContaining` match there would pass for the wrong
      // reason.
      expect(find.text('已下载 4/10 页 · 3.9 KB/9.8 KB'), findsOneWidget);
    });

    testWidgets('源没了的书标出来，仍然算已完成', (tester) async {
      final api = InMemoryDownloadsApi(
        books: [
          FakeDownload(
            bookId: 'gone',
            title: 'Vanished',
            pagesTotal: 3,
            pagesDone: 3,
            state: 'completed',
            stale: true,
          )
        ],
      );
      final controller =
          _controller(api, _Facts(), interval: const Duration(hours: 1));
      await controller.refresh();
      await _mount(tester, controller);
      expect(find.text('服务器上已经没有这本书，本机的这份仍可阅读'), findsOneWidget);
      expect(find.text('已完成'), findsOneWidget);
    });

    testWidgets('平台不说剩余空间时写「未知」，不写 0 B', (tester) async {
      final facts = _Facts()..free = 0;
      final controller = DownloadController(InMemoryDownloadsApi(),
          link: facts.readLink,
          freeBytes: facts.readFree,
          interval: const Duration(hours: 1));
      await controller.refresh(withStorage: true);
      await _mount(tester, controller);
      expect(find.text('未知'), findsOneWidget);
      expect(find.textContaining('0 B '), findsNothing);
    });

    testWidgets('蜂窝被挡时只有一个出口，而且是用户点的', (tester) async {
      final api = InMemoryDownloadsApi(
        books: [FakeDownload(bookId: 'b1', title: 'Book', pagesTotal: 4)],
      )..nextStop = 'linkBlocked';
      final controller =
          _controller(api, _Facts(), interval: const Duration(hours: 1));
      await controller.enqueue('b1');
      await controller.pumpTurn();
      expect(controller.stopReason, 'linkBlocked');
      await _mount(tester, controller);
      expect(find.byKey(const Key('cellular-b1')), findsOneWidget);
      await tester.tap(find.byKey(const Key('cellular-b1')));
      await tester.pumpAndSettle();
      expect(controller.books.single.allowCellular, isTrue);
      expect(find.byKey(const Key('cellular-b1')), findsNothing);
    });

    testWidgets('按暂停不会顺手删掉一本书', (tester) async {
      final api = InMemoryDownloadsApi(
        books: [FakeDownload(bookId: 'b1', title: 'Book', pagesTotal: 6)],
      );
      final controller =
          _controller(api, _Facts(), interval: const Duration(hours: 1));
      // `refresh`, not `enqueue`: enqueue is a user gesture and it legitimately kicks
      // the pump immediately, which would finish this 6-page book before the tap.
      await controller.refresh();
      await _mount(tester, controller);
      await tester.tap(find.byKey(const Key('pause-b1')));
      await tester.pumpAndSettle();
      expect(api.pauseCalls, 1);
      expect(api.deleteCalls, 0);
      expect(find.text('已暂停'), findsOneWidget);
      expect(find.byKey(const Key('resume-b1')), findsOneWidget);
    });

    testWidgets('确认删除才真的删', (tester) async {
      final api = InMemoryDownloadsApi(
        books: [
          FakeDownload(
              bookId: 'b1', title: 'One Piece #1', pagesTotal: 6, pagesDone: 4)
        ],
      );
      final controller =
          _controller(api, _Facts(), interval: const Duration(hours: 1));
      await controller.refresh(withStorage: true);
      await _mount(tester, controller);

      await tester.tap(find.byKey(const Key('delete-b1')));
      await tester.pumpAndSettle();
      expect(find.textContaining('只删除本机的离线副本'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(api.deleteCalls, 0);
      expect(controller.books, hasLength(1));

      await tester.tap(find.byKey(const Key('delete-b1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-delete')));
      await tester.pumpAndSettle();
      expect(api.deleteCalls, 1);
      expect(controller.books, isEmpty);
      expect(find.text('还没有下载'), findsOneWidget);
    });
  });

  group('队列停摆时说清原因，也能一次清空', () {
    testWidgets('停下来是因为空间不足，就说空间不足', (tester) async {
      final api = InMemoryDownloadsApi(
        books: [FakeDownload(bookId: 'b1', title: 'Book', pagesTotal: 40)],
      )..nextStop = 'lowSpace';
      final controller =
          _controller(api, _Facts(), interval: const Duration(hours: 1));
      await controller.refresh();
      await controller.pumpTurn();
      expect(controller.stopReason, 'lowSpace');

      await _mount(tester, controller);

      // The old screen showed this stop as a book '排队中 0/40 页' and nothing
      // else, which is the same picture as a queue that is merely waiting.
      expect(find.text('存储空间不足，清理后再继续'), findsOneWidget);
      expect(find.byKey(const Key('downloads-status')), findsOneWidget);
    });

    testWidgets('停下来是因为服务器限流，就说限流', (tester) async {
      final api = InMemoryDownloadsApi(
        books: [FakeDownload(bookId: 'b1', title: 'Book', pagesTotal: 40)],
      )..nextStop = 'throttled';
      final controller =
          _controller(api, _Facts(), interval: const Duration(hours: 1));
      await controller.refresh();
      await controller.pumpTurn();
      expect(controller.stopReason, 'throttled');

      await _mount(tester, controller);

      expect(find.text('服务器限流，稍后自动重试'), findsOneWidget);
    });

    testWidgets('不认识的原因说中性的话，不把核心的标识印在屏幕上', (tester) async {
      final api = InMemoryDownloadsApi(
        books: [FakeDownload(bookId: 'b1', title: 'Book', pagesTotal: 40)],
      )..nextStop = 'somethingNew';
      final controller =
          _controller(api, _Facts(), interval: const Duration(hours: 1));
      await controller.refresh();
      await controller.pumpTurn();
      expect(controller.stopReason, 'somethingNew');

      await _mount(tester, controller);

      expect(find.textContaining('还不认识'), findsOneWidget);
      expect(find.textContaining('somethingNew'), findsNothing,
          reason: 'an identifier is a contract, not a sentence for a person');
      expect(find.textContaining('lowSpace'), findsNothing);
    });

    testWidgets('一个回合自己失败时也说人话，不回显异常', (tester) async {
      final api = _ThrowingPumpApi(
        books: [FakeDownload(bookId: 'b1', title: 'Book', pagesTotal: 40)],
      );
      final controller =
          _controller(api, _Facts(), interval: const Duration(hours: 1));
      await controller.refresh();
      await controller.pumpTurn();
      expect(controller.error, isNotNull,
          reason: 'the turn failed, which is the only thing this field is for');

      await _mount(tester, controller);

      // No stop reason exists for this one: the failure is the turn's own, and
      // it is the field the screen used to leave unread.
      expect(find.textContaining('下载这一步没有完成'), findsOneWidget);
      expect(find.textContaining('bridge closed'), findsNothing,
          reason: 'an exception string is a log line, not a status line');
    });

    testWidgets('全部删除先问一次，取消就什么都没删', (tester) async {
      final api = _BulkAwareApi(books: [
        FakeDownload(
            bookId: 'b1', title: 'One Piece #1', pagesTotal: 6, pagesDone: 4),
        FakeDownload(
            bookId: 'b2',
            title: 'One Piece #2',
            pagesTotal: 10,
            pagesDone: 10,
            state: 'completed'),
      ]);
      final controller =
          _controller(api, _Facts(), interval: const Duration(hours: 1));
      await controller.refresh(withStorage: true);
      await _mount(tester, controller);

      await tester.tap(find.byKey(const Key('downloads-delete-all')));
      await tester.pumpAndSettle();

      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget,
          reason: 'a gesture that empties a server needs one question first');
      // The two numbers the question promises back are the storage card's own:
      // two books, and 6666 + 10000 bytes.
      expect(find.descendant(of: dialog, matching: find.textContaining('2 本')),
          findsOneWidget);
      expect(
          find.descendant(
              of: dialog, matching: find.textContaining('16.3 KB')),
          findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(api.removeAllCalls, 0);
      expect(controller.books, hasLength(2));
      expect(dialog, findsNothing);
    });

    testWidgets('确认之后删光，列表与占用一起清空', (tester) async {
      final api = _BulkAwareApi(books: [
        FakeDownload(
            bookId: 'b1', title: 'One Piece #1', pagesTotal: 6, pagesDone: 4),
        FakeDownload(
            bookId: 'b2',
            title: 'One Piece #2',
            pagesTotal: 10,
            pagesDone: 10,
            state: 'completed'),
      ]);
      final controller =
          _controller(api, _Facts(), interval: const Duration(hours: 1));
      await controller.refresh(withStorage: true);
      await _mount(tester, controller);
      expect(find.text('2 本 · 16.3 KB'), findsOneWidget);

      await tester.tap(find.byKey(const Key('downloads-delete-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-delete-all')));
      await tester.pumpAndSettle();

      expect(api.removeAllCalls, 1,
          reason: 'the one call, not a loop of single deletes');
      expect(controller.books, isEmpty);
      expect(find.byKey(const Key('download-b1')), findsNothing);
      expect(find.text('还没有下载'), findsOneWidget);
      expect(find.text('0 本 · 0 B'), findsOneWidget,
          reason: 'the storage figures are re-read, not left standing');
      expect(find.textContaining('已删除 2 本离线书籍'), findsOneWidget);

      // Let the snackbar's own timer expire, or the test ends holding it.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('第一次读不出来时是错误态和重试，不是「还没有下载」', (tester) async {
      final api = _FlakyListApi(
        books: [
          FakeDownload(
              bookId: 'b1',
              title: 'One Piece #1',
              pagesTotal: 6,
              pagesDone: 6,
              state: 'completed'),
        ],
      );
      final controller =
          _controller(api, _Facts(), interval: const Duration(hours: 1));
      await _mount(tester, controller);

      expect(find.byKey(const Key('downloads-load-failed')), findsOneWidget);
      expect(find.text('还没有下载'), findsNothing,
          reason: 'the list was never read: empty is not the same thing');
      expect(find.textContaining('database is locked'), findsNothing,
          reason: 'an exception string is not a sentence for a person');
      expect(find.byKey(const Key('downloads-retry-load')), findsOneWidget);

      await tester.tap(find.byKey(const Key('downloads-retry-load')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('downloads-load-failed')), findsNothing);
      expect(find.byKey(const Key('download-b1')), findsOneWidget);
    });
  });

  group('通知：只在状态真的变了才响', () {
    // The ticker fires every second whether or not anything moved. Notifying
    // unconditionally is what used to rebuild the shelf's whole tile wall once a
    // second; the shelf now only wraps the download badge in a listener, so an
    // unconditional notify would still repaint it forever for nothing.

    test('空队列连转五次，一个监听器都不惊动', () async {
      final api = InMemoryDownloadsApi();
      final controller = _controller(api, _Facts());
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      for (var i = 0; i < 5; i += 1) {
        await controller.pumpTurn();
      }

      expect(notifications, 0,
          reason: 'an idle queue produces an identical revision every tick');
      controller.stop();
    });

    test('队列真的动了就通知', () async {
      final api = InMemoryDownloadsApi(
        books: [FakeDownload(bookId: 'b1', title: 'Book', pagesTotal: 40)],
      )..pumpPages = 2;
      final controller = _controller(api, _Facts());
      await controller.enqueue('b1');

      var notifications = 0;
      controller.addListener(() => notifications += 1);

      await controller.pumpTurn();

      expect(notifications, greaterThan(0));
      expect(controller.books.single.pagesDone, 16);
      controller.stop();
    });

    test('只有退避原因变了，也要通知', () async {
      // The status line reads `stopReason`; a park with no row moving still has
      // to reach the screen, or the queue looks stuck with no explanation.
      final api = InMemoryDownloadsApi(
        books: [FakeDownload(bookId: 'b1', title: 'Book', pagesTotal: 40)],
      )..pumpPages = 2;
      final controller = _controller(api, _Facts());
      await controller.enqueue('b1');
      await controller.pumpTurn();

      var notifications = 0;
      controller.addListener(() => notifications += 1);

      api.nextStop = 'linkDown';
      await controller.pumpTurn();

      expect(controller.stopReason, 'linkDown');
      expect(notifications, greaterThan(0));
      controller.stop();
    });
  });
}
