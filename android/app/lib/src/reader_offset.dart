/// The arithmetic behind "where in this page is the reader?", kept out of the
/// widget so it can be tested against real render boxes instead of guessed at
/// through a screenshot.
///
/// The whole feature rests on one observation: a page number is not a position.
/// A 5000px webtoon strip and a 1600px manga page are both "page 62", and losing
/// which one you were halfway down is the difference between resuming and
/// re-scrolling.
class ReaderOffsetGeometry {
  const ReaderOffsetGeometry._();

  /// Ignore movement smaller than this. It is the same threshold the controller
  /// uses, repeated here so one drag does not become a write per pixel.
  static const double minimumRatioDelta = 0.005;

  /// Which page owns the top of the viewport, and how far into it that is.
  ///
  /// [pages] must be in layout order and each entry is that page's box; the
  /// boxes come from the keys the column keeps for exactly this reason.
  ///
  /// The returned `ratio` is `null` — not `0.0` — whenever "inside the page" is
  /// not a meaningful thing to say:
  ///
  /// * the page no longer covers the top edge, so the reader has left it,
  /// * the page is entirely below the fold, so the reader has not entered it,
  /// * the page has no height yet, as during the first layout pass,
  /// * the numbers are not finite.
  ///
  /// Note what is *not* on that list: a page that fits the viewport. Whether a
  /// page scrolls is not this function's business — the caller only asks for a
  /// ratio when it has somewhere to scroll to. Deciding "a short page has no
  /// inside" here would be wrong the moment a page is shorter than a tall screen
  /// but the reader has still scrolled past its start.
  ///
  /// That distinction is the whole reason this returns a nullable: writing `0.0`
  /// where the answer is unknown tells the next open "the reader was at the top",
  /// which is a claim we cannot make.
  static ({int? page, double? ratio}) measure({
    required double viewportTop,
    required List<({int page, double top, double height})> pages,
  }) {
    if (pages.isEmpty) return (page: null, ratio: null);

    ({int page, double top, double height})? best;
    double? nearestBelow;
    var straddlesTop = false;

    for (final candidate in pages) {
      final bottom = candidate.top + candidate.height;
      // The page covering the top edge wins outright: it is the one the reader is
      // looking at, even if only its last line is on screen.
      if (candidate.top <= viewportTop && bottom > viewportTop) {
        best = candidate;
        straddlesTop = true;
        break;
      }
      // Otherwise remember the first page below the fold, so a viewport that
      // landed in a gap between pages still names a page.
      if (candidate.top >= viewportTop) {
        final distance = candidate.top - viewportTop;
        if (nearestBelow == null || distance < nearestBelow) {
          nearestBelow = distance;
          best = candidate;
        }
      }
    }

    if (best == null) return (page: null, ratio: null);
    if (!straddlesTop) {
      // The page is entirely below the fold: the reader has not entered it yet.
      return (page: best.page, ratio: null);
    }
    if (best.height <= 0) return (page: best.page, ratio: null);

    // A page that no longer covers the top edge owns no position. That happens
    // when the viewport has scrolled past its bottom — the boundary between two
    // pages is fuzzy by up to the margin above, so the two can briefly disagree —
    // and it is why this cannot just clamp: this page would call itself "100%"
    // while the next page calls itself "2%", and the stored value would jump
    // backwards every time the handoff landed on the other side.
    //
    // The caller, meanwhile, only reports an offset for the page it is already
    // on, so a null here is not a lost position: the next page is about to
    // report its own.
    if (viewportTop >= best.top + best.height) {
      return (page: best.page, ratio: null);
    }

    final scrolled = (viewportTop - best.top) / best.height;
    if (!scrolled.isFinite || scrolled <= 0) {
      return (page: best.page, ratio: null);
    }
    return (page: best.page, ratio: scrolled.clamp(0.0, 1.0));
  }

  /// The scroll offset that puts [ratio] of page [page] at the top of the
  /// viewport, given where that page currently sits.
  ///
  /// [pageTop] is the page's current global top and [viewportTop] the viewport's,
  /// so `pageTop - viewportTop` is how far below the fold it is right now.
  static double scrollTarget({
    required double pageTop,
    required double viewportTop,
    required double pageHeight,
    required double ratio,
    required double currentScrollOffset,
    required double maxScrollExtent,
  }) {
    final withinPage = (ratio.clamp(0.0, 1.0)) * pageHeight;
    final target = currentScrollOffset + (pageTop - viewportTop) + withinPage;
    return target.clamp(0.0, maxScrollExtent < 0 ? 0.0 : maxScrollExtent);
  }
}
