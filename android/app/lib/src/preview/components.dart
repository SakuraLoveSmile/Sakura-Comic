import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'models.dart';
import 'theme.dart';

/// Shared prototype widgets: covers, state surfaces and the shelf's toolbar.
///
/// Covers are drawn, not loaded. The prototype must run on a device with no
/// server and no bundled artwork, and a drawn cover still answers the questions
/// the review is about — how big a cover is, how a title wraps under it, how the
/// grid breathes — without pretending to be a real thumbnail.

const List<Color> _coverPalette = <Color>[
  Color(0xFF3F51B5),
  Color(0xFF00695C),
  Color(0xFF6A1B9A),
  Color(0xFFB71C1C),
  Color(0xFF37474F),
  Color(0xFF006064),
  Color(0xFF4E342E),
  Color(0xFF283593),
  Color(0xFF1B5E20),
  Color(0xFF880E4F),
  Color(0xFF01579B),
  Color(0xFF33691E),
];

/// A series cover: deterministic colour band + title, in a fixed 2:3 frame.
class SeriesCover extends StatelessWidget {
  const SeriesCover({
    super.key,
    required this.series,
    this.showTitle = true,
    this.borderRadius = ComicTokens.radiusCard,
  });

  final PreviewSeries series;
  final bool showTitle;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final base = _coverPalette[series.coverSeed % _coverPalette.length];
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            base.withValues(alpha: 0.92),
            Color.lerp(base, Colors.black, 0.55)!
          ],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // A spine and a light block: enough structure that the eye reads the
          // rectangle as a book rather than as a coloured placeholder.
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
                width: 6, color: Colors.black.withValues(alpha: 0.22)),
          ),
          Positioned(
            left: 16,
            right: 12,
            top: 16,
            child: Container(
              height: 3,
              color: Colors.white.withValues(alpha: 0.35),
            ),
          ),
          if (showTitle)
            Positioned(
              left: 14,
              right: 12,
              bottom: 14,
              child: Text(
                series.name,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                  shadows: const [Shadow(blurRadius: 6, color: Colors.black54)],
                ),
              ),
            ),
          if (series.completeness != CatalogCompleteness.complete)
            const Positioned(
              top: 8,
              right: 8,
              child: _MiniBadge(icon: Icons.cloud_sync_outlined, label: '目录未全'),
            ),
          if (series.books
              .any((b) => b.downloadState == DownloadState.complete))
            const Positioned(
              bottom: 8,
              right: 8,
              child: _MiniBadge(icon: Icons.download_done, label: ''),
            ),
        ],
      ),
    );
  }
}

class _MiniBadge extends StatelessWidget {
  const _MiniBadge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: label.isEmpty ? 4 : 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(ComicTokens.radiusChip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white),
          if (label.isNotEmpty) ...[
            const SizedBox(width: 3),
            Text(label,
                style: const TextStyle(fontSize: 10, color: Colors.white)),
          ],
        ],
      ),
    );
  }
}

/// A book thumbnail for detail rows and the download list.
class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    required this.seriesName,
    required this.seed,
    this.width = 56,
  });

  final String seriesName;
  final int seed;
  final double width;

  @override
  Widget build(BuildContext context) {
    final base = _coverPalette[seed % _coverPalette.length];
    return Container(
      width: width,
      height: width / ComicTokens.coverAspectRatio,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            base.withValues(alpha: 0.85),
            Color.lerp(base, Colors.black, 0.6)!
          ],
        ),
      ),
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Text(
          seriesName,
          textAlign: TextAlign.center,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style:
              const TextStyle(fontSize: 9, color: Colors.white70, height: 1.15),
        ),
      ),
    );
  }
}

/// A full-width state surface: icon, headline, explanation, actions.
///
/// Used by every "there is nothing here" path, so an empty search, a first run
/// with no server and a failed load cannot drift into three different visual
/// languages.
class PreviewStateView extends StatelessWidget {
  const PreviewStateView({
    super.key,
    required this.icon,
    required this.headline,
    required this.detail,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
    this.tone = StateTone.neutral,
  });

  final IconData icon;
  final String headline;
  final String detail;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final StateTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (tone) {
      StateTone.neutral => scheme.onSurfaceVariant,
      StateTone.warning => const Color(0xFFFFB74D),
      StateTone.error => scheme.error,
      StateTone.success => const Color(0xFF81C784),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ComicTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: color),
            const SizedBox(height: ComicTokens.spaceMd),
            Text(
              headline,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: ComicTokens.spaceXs),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (primaryLabel != null) ...[
              const SizedBox(height: ComicTokens.spaceLg),
              FilledButton(
                onPressed: onPrimary,
                child: Text(primaryLabel!),
              ),
            ],
            if (secondaryLabel != null) ...[
              const SizedBox(height: ComicTokens.spaceXs),
              TextButton(onPressed: onSecondary, child: Text(secondaryLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

enum StateTone { neutral, warning, error, success }

/// A one-line banner for the states that must stay *findable* without owning
/// the screen: syncing, uploads pending, a failed sync.
class PreviewBanner extends StatelessWidget {
  const PreviewBanner({
    super.key,
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.tone = StateTone.neutral,
  });

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final StateTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (tone) {
      StateTone.neutral => scheme.onSurfaceVariant,
      StateTone.warning => const Color(0xFFFFB74D),
      StateTone.error => scheme.error,
      StateTone.success => const Color(0xFF81C784),
    };
    return Container(
      margin: const EdgeInsets.fromLTRB(
        ComicTokens.spaceMd,
        0,
        ComicTokens.spaceMd,
        ComicTokens.spaceXs,
      ),
      padding: const EdgeInsets.symmetric(
          horizontal: ComicTokens.spaceSm, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(ComicTokens.radiusCard),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: ComicTokens.spaceXs),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurface),
            ),
          ),
          if (actionLabel != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(minimumSize: const Size(0, 36)),
              child: Text(actionLabel!),
            ),
        ],
      ),
    );
  }
}

/// A metadata chip that never relies on colour alone: the label always spells
/// out what the state is.
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    required this.icon,
    this.tone = StateTone.neutral,
  });

  final String label;
  final IconData icon;
  final StateTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (tone) {
      StateTone.neutral => scheme.onSurfaceVariant,
      StateTone.warning => const Color(0xFFFFB74D),
      StateTone.error => scheme.error,
      StateTone.success => const Color(0xFF81C784),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(ComicTokens.radiusChip),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          // A chip is often the shortest place a long state has to fit — a
          // rejected credential, an incompletely mirrored series. It ellipsises
          // rather than pushing its row wider than the screen.
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// A section header used by every screen that splits into titled blocks.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ComicTokens.spaceMd,
        ComicTokens.spaceSm,
        ComicTokens.spaceSm,
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// A drawn comic page.
///
/// The prototype has no page images and must not pretend otherwise: every page
/// is a labelled rectangle with panels, which is enough to judge zooming,
/// page-fit, spreads and toolbar overlays — the things the review is about.
class DrawnPage extends StatelessWidget {
  const DrawnPage({
    super.key,
    required this.pageNumber,
    required this.totalPages,
    this.highlight = false,
  });

  final int pageNumber;
  final int totalPages;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _PagePainter(pageNumber, highlight),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            '$pageNumber / $totalPages',
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ),
      ),
    );
  }
}

class _PagePainter extends CustomPainter {
  _PagePainter(this.page, this.highlight);

  final int page;
  final bool highlight;

  @override
  void paint(Canvas canvas, Size size) {
    final paper = Paint()
      ..color = highlight ? const Color(0xFFEDE7F6) : const Color(0xFFF2F2F2);
    canvas.drawRect(Offset.zero & size, paper);
    final ink = Paint()
      ..color = const Color(0xFF1A1A1A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    // Three rows of panels, with the middle row split: the composition changes
    // with the page number so paging is visible at a glance.
    final margin = size.width * 0.06;
    final top = size.height * 0.06;
    final usable = size.height * 0.86;
    const rows = 3;
    final rowHeight = usable / rows;
    for (var row = 0; row < rows; row++) {
      final rect = Rect.fromLTWH(
        margin,
        top + row * rowHeight,
        size.width - margin * 2,
        rowHeight - 10,
      );
      canvas.drawRect(rect, ink);
      final split = (page + row) % 3 == 0 ? 1 : 2;
      if (split == 2) {
        final midX = rect.left + rect.width / 2;
        canvas.drawLine(
          Offset(midX, rect.top),
          Offset(midX, rect.bottom),
          ink,
        );
      }
      final fill = Paint()
        ..color = const Color(0xFF1A1A1A)
            .withValues(alpha: 0.08 + ((page + row) % 4) * 0.05);
      canvas.drawRect(rect.deflate(6), fill);
    }
  }

  @override
  bool shouldRepaint(_PagePainter oldDelegate) =>
      oldDelegate.page != page || oldDelegate.highlight != highlight;
}

/// The zoom + page-group state the reader screen owns.
///
/// Kept in one place because zoom, page index and mode changes have to be reset
/// together: a stale scale on a page that no longer exists is the classic
/// "reader is stuck zoomed out" bug the milestone explicitly calls out.
class ReaderViewState {
  ReaderViewState({
    required this.mode,
    required this.direction,
    required int initialPage,
  }) : currentPage = initialPage;

  String mode;
  String direction;
  int currentPage;

  /// 1.0 = fit page, up to 4.0 by pinch.
  double scale = 1.0;
  Offset offset = Offset.zero;

  /// True when a whole spread is shown (double mode) — used by the toolbar.
  bool get isSpread => mode == 'double';
  bool get isWebtoon => mode == 'webtoon';
  bool get isZoomed => scale > 1.01;

  /// Size of one pointer step in the page group.
  int get groupSize => mode == 'double' ? 2 : 1;

  /// Page-group index the PageController should be on for [currentPage].
  int get groupIndex =>
      mode == 'double' ? (currentPage - 1) ~/ 2 : currentPage - 1;

  void resetZoom() {
    scale = 1.0;
    offset = Offset.zero;
  }
}

/// Human wording for a page-load failure, mirroring the production
/// `FailurePresentation` categories without importing the FFI enum.
String pageFailureHeadline(String code) {
  switch (code) {
    case 'auth':
      return '登录已失效，需要重新输入 API Key';
    case 'network':
      return '连不上服务器';
    case 'notFound':
      return '服务器上已经没有这一页了';
    case 'decode':
      return '这一页的图片无法解码';
    default:
      return '这一页没有加载成功';
  }
}

/// A grid delegate whose tile height is supplied by the caller.
///
/// `SliverGridDelegateWithMaxCrossAxisExtent` sizes tiles from a fixed aspect
/// ratio, which cannot express "the cover is 2:3 and the text gets whatever it
/// needs". This exposes `mainAxisExtent` while keeping the same column maths.
class GridViewExtentDelegate extends SliverGridDelegate {
  const GridViewExtentDelegate({
    required this.spec,
    required this.mainAxisExtent,
  });

  final GridDensitySpec spec;
  final double mainAxisExtent;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final crossAxisCount =
        (constraints.crossAxisExtent / (spec.maxCrossAxisExtent + spec.spacing))
            .ceil()
            .clamp(1, 8);
    final usable =
        constraints.crossAxisExtent - spec.spacing * (crossAxisCount - 1);
    final tileWidth = usable / crossAxisCount;
    return SliverGridRegularTileLayout(
      crossAxisCount: crossAxisCount,
      mainAxisStride: mainAxisExtent + spec.spacing,
      crossAxisStride: tileWidth + spec.spacing,
      childMainAxisExtent: mainAxisExtent,
      childCrossAxisExtent: tileWidth,
      reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
    );
  }

  @override
  bool shouldRelayout(GridViewExtentDelegate oldDelegate) =>
      oldDelegate.mainAxisExtent != mainAxisExtent || oldDelegate.spec != spec;
}

/// The height one series tile needs at [maxCrossAxisExtent] and the ambient text
/// scale: a 2:3 cover, then however many lines the title and the two detail
/// lines actually take.
double seriesCardHeight(
  BuildContext context,
  double maxCrossAxisExtent,
  (int, int) lineCounts,
) {
  final theme = Theme.of(context);
  final scaler = MediaQuery.textScalerOf(context);
  final (nameLines, detailLines) = lineCounts;
  final tileWidth = maxCrossAxisExtent;

  double measure(String sample, TextStyle? style, int maxLines) {
    final painter = TextPainter(
      text: TextSpan(text: sample, style: style),
      maxLines: maxLines,
      textDirection: Directionality.of(context),
      textScaler: scaler,
    )..layout(maxWidth: tileWidth);
    return painter.height;
  }

  final nameStyle =
      theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600);
  final detailStyle = theme.textTheme.labelSmall;
  // Measured on the longest sample in the prototype's own shelf, so the tile
  // fits its cards rather than its average card.
  final nameHeight = measure('水星领航员 ×', nameStyle, nameLines);
  final counterHeight = measure('已读 37/70 册', detailStyle, 1);
  final downloadHeight = measure('已下载 12 册 · 3 册进行中', detailStyle, detailLines);
  return tileWidth / ComicTokens.coverAspectRatio +
      6 +
      nameHeight +
      counterHeight +
      (detailLines > 1 ? downloadHeight : 0) +
      4;
}
