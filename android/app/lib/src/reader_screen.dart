import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'reader_controller.dart';

/// The Stage 7 reader.
///
/// Three modes over one layout contract:
///   * 单页 / 双页 — paged, horizontal for LTR / RTL, vertical for Vertical;
///   * 条漫 — one continuous vertical column.
/// Which spread is on screen, in which order its pages sit, and which swipe or
/// tap advances all come from the core's layout, so Android and Apple cannot
/// disagree about what "next page" means.
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    required this.controller,
    this.title,
  });

  final ReaderController controller;
  final String? title;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> with WidgetsBindingObserver {
  PageController? _paged;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_onController);
    widget.controller.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_onController);
    widget.controller.dispose();
    super.dispose();
  }

  /// Background and memory pressure are the two moments the reader can act on
  /// before the OS acts for it. Pausing releases the decoded bitmaps; coming back
  /// re-describes the device, because the link may have changed while the app
  /// slept and the prefetch window has to follow it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(widget.controller.resumed());
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        unawaited(widget.controller.paused());
    }
  }

  @override
  void didHaveMemoryPressure() {
    unawaited(widget.controller.onMemoryPressure());
  }

  void _onController() {
    if (!mounted) return;
    setState(() {});
    // The webtoon column owns its scroll offset; paged modes use a PageView.
    if (!widget.controller.isWebtoon) {
      _paged ??= PageController(initialPage: widget.controller.spread);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: controller.background,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.black.withValues(alpha: 0.45),
          foregroundColor: Colors.white,
          title: Text(
            widget.title ?? controller.book?.bookId ?? '阅读',
            style: const TextStyle(fontSize: 15),
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              tooltip: '阅读设置',
              icon: const Icon(Icons.tune),
              onPressed: () => _showSettings(context, controller),
            ),
          ],
        ),
        body: Stack(
          children: [
            if (controller.error != null)
              Positioned(
                left: 0,
                right: 0,
                top: kToolbarHeight + 8,
                child: Material(
                  color: Colors.black54,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      controller.error!,
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                ),
              ),
            Center(
              child: switch ((controller.busy, controller.pageCount)) {
                (true, _) => const CircularProgressIndicator(),
                (false, 0) => const _EmptyState(),
                _ => controller.isWebtoon
                    ? _WebtoonColumn(controller: controller)
                    : _PagedView(
                        controller: controller,
                        pageController: _paged ??= PageController(
                          initialPage: controller.spread,
                        ),
                      ),
              },
            ),
            if (!controller.busy && controller.pageCount > 0)
              Align(
                alignment: Alignment.bottomCenter,
                child: _BottomBar(controller: controller),
              ),
            if (controller.isWaitingForPage)
              const Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '这本书没有可显示的页面',
              style: TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
}

/// Paged rendering: single page or double-page spread per screen.
class _PagedView extends StatelessWidget {
  const _PagedView({required this.controller, required this.pageController});

  final ReaderController controller;
  final PageController pageController;

  @override
  Widget build(BuildContext context) {
    final layout = controller.layout;
    if (layout == null) return const SizedBox.shrink();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (detail) => _handleTap(context, detail),
      child: PageView.builder(
        controller: pageController,
        // RTL manga reads right-to-left: the page list still runs forward, the
        // scroll direction is what mirrors. Vertical paging scrolls downward.
        scrollDirection: controller.isVertical ? Axis.vertical : Axis.horizontal,
        reverse: !controller.isVertical && layout.reversed,
        itemCount: controller.spreadCount,
        onPageChanged: (index) {
          final spread = controller.spreads[index];
          if (spread.isNotEmpty && spread.first != controller.page) {
            controller.turnTo(spread.first);
          }
        },
        itemBuilder: (context, index) {
          final spread = controller.spreads[index];
          final ordered = layout.reversed ? spread.reversed.toList() : spread;
          return Padding(
            padding: EdgeInsets.symmetric(
              horizontal: controller.isVertical ? 0 : controller.pageGap / 2,
              vertical: controller.isVertical ? controller.pageGap / 2 : 0,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final page in ordered)
                  Expanded(
                    child: _PageImage(controller: controller, page: page),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// The tap halves come from the contract (`tapNext` / `tapPrev`), so a
  /// right-to-left book advances by tapping the left half of the screen.
  void _handleTap(BuildContext context, TapUpDetails detail) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final size = box.size;
    final local = detail.localPosition;
    final layout = controller.layout!;
    final advance = switch (layout.tapNext) {
      'left' => local.dx < size.width / 2,
      'right' => local.dx > size.width / 2,
      'top' => local.dy < size.height / 2,
      _ => local.dy > size.height / 2,
    };
    final retreat = switch (layout.tapPrev) {
      'left' => local.dx < size.width / 2,
      'right' => local.dx > size.width / 2,
      'top' => local.dy < size.height / 2,
      _ => local.dy > size.height / 2,
    };
    if (advance) {
      controller.next();
    } else if (retreat && !(advance)) {
      controller.previous();
    }
  }
}

/// 条漫: one long vertical column, virtualized so a 500-page webtoon keeps a
/// bounded number of decoded images alive.
class _WebtoonColumn extends StatelessWidget {
  const _WebtoonColumn({required this.controller});

  final ReaderController controller;

  @override
  Widget build(BuildContext context) {
    final pages = [for (final spread in controller.rawSpreads) ...spread];
    return ListView.builder(
      // RTL never reverses a single column; there is nothing to mirror.
      itemCount: pages.length,
      itemBuilder: (context, index) => Padding(
        padding: EdgeInsets.only(bottom: controller.pageGap),
        child: _PageImage(
          controller: controller,
          page: pages[index],
          fit: BoxFit.fitWidth,
        ),
      ),
    );
  }
}

class _PageImage extends StatelessWidget {
  const _PageImage({required this.controller, required this.page, this.fit});

  final ReaderController controller;
  final int page;
  final BoxFit? fit;

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
        future: controller.imageFor(page),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Center(
              child: snapshot.connectionState == ConnectionState.done
                  ? const Icon(Icons.image_not_supported_outlined,
                      color: Colors.white38)
                  : const CircularProgressIndicator(strokeWidth: 2),
            );
          }
          final path = snapshot.data!;
          // Image.file with cacheWidth: the core hands over a file, and Flutter
          // decodes it at the width it will actually draw at. A 4K page decoded
          // at full size is the surest way to drop frames on a fast flip.
          return InteractiveViewer(
            maxScale: 4,
            child: Image.file(
              File(path),
              fit: fit ?? BoxFit.contain,
              cacheWidth: (MediaQuery.of(context).size.width *
                      MediaQuery.of(context).devicePixelRatio)
                  .round(),
              errorBuilder: (_, __, ___) => const Center(
                child: Icon(Icons.broken_image_outlined, color: Colors.white38),
              ),
            ),
          );
        },
      );
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.controller});

  final ReaderController controller;

  @override
  Widget build(BuildContext context) {
    final layout = controller.layout;
    return SafeArea(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.45),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              IconButton(
                onPressed: controller.previous,
                icon: Icon(
                  controller.isVertical
                      ? Icons.keyboard_arrow_up
                      : (layout?.reversed ?? false)
                          ? Icons.arrow_forward
                          : Icons.arrow_back,
                  color: Colors.white,
                ),
                tooltip: '上一页',
              ),
              Expanded(
                child: Slider(
                  value: controller.page.clamp(1, controller.pageCount).toDouble(),
                  max: controller.pageCount.toDouble(),
                  divisions: controller.pageCount > 1 ? controller.pageCount - 1 : null,
                  label: '${controller.page}/${controller.pageCount}',
                  onChanged: (value) => controller.turnTo(value.round()),
                ),
              ),
              Text(
                '${controller.page} / ${controller.pageCount}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              IconButton(
                onPressed: controller.next,
                icon: Icon(
                  controller.isVertical
                      ? Icons.keyboard_arrow_down
                      : (layout?.reversed ?? false)
                          ? Icons.arrow_back
                          : Icons.arrow_forward,
                  color: Colors.white,
                ),
                tooltip: '下一页',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _showSettings(BuildContext context, ReaderController controller) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141414),
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('阅读模式',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final entry in const {
                    'single': '单页',
                    'double': '双页',
                    'webtoon': '条漫',
                  }.entries)
                    ChoiceChip(
                      label: Text(entry.value),
                      selected: controller.mode == entry.key,
                      onSelected: (_) => controller.setMode(entry.key),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const Text('阅读方向',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final entry in const {
                    'ltr': '左→右',
                    'rtl': '右→左',
                    'vertical': '纵向',
                  }.entries)
                    ChoiceChip(
                      label: Text(entry.value),
                      selected: controller.direction == entry.key,
                      onSelected: (_) => controller.setDirection(entry.key),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const Text('背景',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final entry in const {
                    'black': '黑',
                    'gray': '灰',
                    'white': '白',
                  }.entries)
                    ChoiceChip(
                      label: Text(entry.value),
                      selected: controller.backgroundName == entry.key,
                      onSelected: (_) => controller.setBackground(entry.key),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              _GapTile(controller: controller),
              _BrightnessTile(controller: controller),
              SwitchListTile(
                value: controller.settings?.keepScreenAwake ?? true,
                onChanged: controller.setKeepScreenAwake,
                title: const Text('屏幕常亮', style: TextStyle(color: Colors.white)),
              ),
              SwitchListTile(
                value: controller.settings?.restorePosition ?? true,
                onChanged: controller.setRestorePosition,
                title: const Text('阅读位置恢复', style: TextStyle(color: Colors.white)),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: controller.markUnread,
                      icon: const Icon(Icons.mark_email_unread_outlined),
                      label: const Text('标为未读'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: controller.markRead,
                      icon: const Icon(Icons.mark_email_read_outlined),
                      label: const Text('标为已读'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

class _GapTile extends StatelessWidget {
  const _GapTile({required this.controller});

  final ReaderController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Slider(
        value: (controller.settings?.pageGap.toInt() ?? 8).toDouble(),
        max: 64,
        divisions: 16,
        label: '页间距 ${controller.settings?.pageGap.toInt() ?? 8}',
        onChanged: (value) => controller.setPageGap(value.round()),
      ),
    );
  }
}

class _BrightnessTile extends StatelessWidget {
  const _BrightnessTile({required this.controller});

  final ReaderController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Slider(
        value: controller.brightness,
        min: 0.05,
        max: 1,
        label: '亮度 ${(controller.brightness * 100).round()}%',
        onChanged: controller.setBrightness,
      ),
    );
  }
}

