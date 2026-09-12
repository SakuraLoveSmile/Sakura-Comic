import 'dart:async';

import 'package:comic_app/src/reader_api.dart';
import 'package:comic_app/src/reader_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('dispose waits for a pending offset before closing the session',
      () async {
    final api = _GatedOffsetApi();
    final controller = ReaderController(api: api);

    final report = controller.reportPageOffset(.5);
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    await Future<void>.delayed(Duration.zero);

    expect(api.closeCalls, 0);
    api.offsetGate.complete();
    await report;
    await controller.closed;

    expect(api.offsets, [.5]);
    expect(api.closeCalls, 1);
  });

  test('a failed offset is retried by close before session close', () async {
    final api = _GatedOffsetApi()..failNextOffset = true;
    final controller = ReaderController(api: api);

    api.offsetGate.complete();
    await controller.reportPageOffset(.75);
    controller.dispose();
    await controller.closed;

    expect(api.offsets, [.75, .75]);
    expect(api.closeCalls, 1);
  });
}

class _GatedOffsetApi extends InMemoryReaderApi {
  final Completer<void> offsetGate = Completer<void>();
  final List<double?> offsets = [];
  bool failNextOffset = false;
  int closeCalls = 0;

  @override
  Future<void> setPageOffset(double? ratio) async {
    offsets.add(ratio);
    if (failNextOffset) {
      failNextOffset = false;
      throw StateError('write failed');
    }
    if (!offsetGate.isCompleted) await offsetGate.future;
    await super.setPageOffset(ratio);
  }

  @override
  Future<bool> close() async {
    closeCalls++;
    return true;
  }
}
