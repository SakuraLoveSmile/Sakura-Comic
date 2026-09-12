import 'package:comic_app/src/reader_offset.dart';
import 'package:flutter_test/flutter_test.dart';

/// The geometry behind 条漫定位: a page number is not a position.
///
/// These are the tests that decide whether "读到一半关掉，下次回到原处" is real,
/// and they are pure arithmetic on purpose — the same function the widget calls,
/// checked against numbers instead of against a screenshot.
void main() {
  ({int page, double top, double height}) page(
          int n, double top, double height) =>
      (page: n, top: top, height: height);

  group('测量视口位置', () {
    test('页面比视口高时，报出页内比例', () {
      // Page 2 spans 0..5000 in a 800px viewport scrolled to y=1000: a quarter
      // of the way down page 2.
      final measured = ReaderOffsetGeometry.measure(
        viewportTop: 1000,
        pages: [page(2, 0, 5000), page(3, 5000, 1000)],
      );
      expect(measured.page, 2);
      expect(measured.ratio, closeTo(0.2, 1e-9));
    });

    test('页首报 null，而不是 0.0', () {
      // The distinction the database depends on: "no offset recorded" and "at the
      // top" are different claims, and only one of them is true here.
      final measured = ReaderOffsetGeometry.measure(
        viewportTop: 0,
        pages: [page(1, 0, 5000)],
      );
      expect(measured.page, 1);
      expect(measured.ratio, isNull, reason: '页首不是"页内 0%"这个断言');
    });

    test('尚未进入的下一页不报比例', () {
      // The viewport is in the gap before page 7: the reader is looking at the
      // end of the previous page, not 0% into this one.
      final measured = ReaderOffsetGeometry.measure(
        viewportTop: 100,
        pages: [page(7, 300, 4000)],
      );
      expect(measured.page, 7);
      expect(measured.ratio, isNull);
    });

    test('视口落在页间空隙时，仍指向最近的一页', () {
      final measured = ReaderOffsetGeometry.measure(
        viewportTop: 4800,
        pages: [page(1, 0, 4000), page(2, 5000, 3000)],
      );
      expect(measured.page, 2, reason: '间距不该让阅读器失去页码');
    });

    test('跨在页首的那一页优先', () {
      // Page 2's last 100px are on screen. The reader is looking at page 2, even
      // though most of the viewport is page 3.
      final measured = ReaderOffsetGeometry.measure(
        viewportTop: 3900,
        pages: [page(2, 0, 4000), page(3, 4000, 4000)],
      );
      expect(measured.page, 2);
      expect(measured.ratio, closeTo(0.975, 1e-9));
    });

    test('已经离开的那一页不再报位置', () {
      // Scrolled well past page 1's bottom edge: page 1 owns nothing now. If it
      // insisted on "100%" while page 2 reported "2%", the stored position would
      // jump backwards every time the handoff landed on the other side.
      final left = ReaderOffsetGeometry.measure(
        viewportTop: 6000,
        pages: [page(1, 0, 5000), page(2, 5000, 5000)],
      );
      expect(left.page, 2, reason: '现在在第二页上');
      expect(left.ratio, closeTo(0.2, 1e-9));

      final past = ReaderOffsetGeometry.measure(
        viewportTop: 6000,
        pages: [page(1, 0, 5000)],
      );
      expect(past.ratio, isNull);
    });

    test('过冲回弹报出的越界值被夹紧', () {
      // The scroll physics let the viewport drift a little past the page it is
      // still on; the ratio that comes out must stay in 0..1.
      final overscrolled = ReaderOffsetGeometry.measure(
        viewportTop: 4980,
        pages: [page(1, 0, 5000)],
      );
      expect(overscrolled.ratio, closeTo(0.996, 1e-3));
      expect(overscrolled.ratio, lessThanOrEqualTo(1.0));

      final notFinite = ReaderOffsetGeometry.measure(
        viewportTop: double.nan,
        pages: [page(1, 0, 5000)],
      );
      expect(notFinite.ratio, isNull, reason: '第一帧的布局数字不可信时不要写库');

      expect(
        ReaderOffsetGeometry.measure(
          viewportTop: 0,
          pages: const [],
        ).page,
        isNull,
      );
    });
  });

  group('恢复位置', () {
    test('把页内比例换算成滚动偏移', () {
      // Page 2 starts 100px below the viewport top and is 5000px tall; landing
      // 50% down means scrolling 100 + 2500 further than we already are.
      final target = ReaderOffsetGeometry.scrollTarget(
        pageTop: 100,
        viewportTop: 0,
        pageHeight: 5000,
        ratio: 0.5,
        currentScrollOffset: 0,
        maxScrollExtent: 20000,
      );
      expect(target, closeTo(2600, 1e-9));
    });

    test('换算结果被夹在可滚动范围内', () {
      // A saved 90% of a page that has since been re-rendered shorter: the target
      // is past the end, and asking the controller to scroll past maxScrollExtent
      // throws rather than clamps.
      final target = ReaderOffsetGeometry.scrollTarget(
        pageTop: 100,
        viewportTop: 0,
        pageHeight: 5000,
        ratio: 0.9,
        currentScrollOffset: 0,
        maxScrollExtent: 2000,
      );
      expect(target, 2000);
    });

    test('比例越界被夹紧', () {
      final negative = ReaderOffsetGeometry.scrollTarget(
        pageTop: 0,
        viewportTop: 0,
        pageHeight: 1000,
        ratio: -0.5,
        currentScrollOffset: 0,
        maxScrollExtent: 10000,
      );
      expect(negative, 0);
    });
  });
}
