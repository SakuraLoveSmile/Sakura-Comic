import 'package:flutter/material.dart';

import 'preview_data.dart';
import 'theme.dart';

/// Everything the shelf's tool area owns.
///
/// Held by the shell rather than by the shelf widget so switching bottom tabs
/// and coming back cannot lose a search, a filter or a sort — the milestone
/// requires that state to survive navigation.
class ShelfToolsState {
  ShelfToolsState();

  String query = '';
  String? libraryId;
  String? status;
  String? tag;
  String sortKey = 'name';
  bool ascending = true;
  bool filtersExpanded = false;

  bool get isFiltered =>
      query.trim().isNotEmpty ||
      libraryId != null ||
      status != null ||
      tag != null;

  String get sortLabel {
    switch (sortKey) {
      case 'sortName':
        return '排序名';
      case 'dateAdded':
        return '加入日期';
      case 'dateUpdated':
        return '最近更新';
      case 'booksCount':
        return '册数';
      default:
        return '名称';
    }
  }
}

/// The shelf's search / filter / sort block.
///
/// One component rather than three scattered controls: the milestone moves
/// search, filtering and sorting out of the top bar and into one tool area, and
/// this is that area.
class ShelfToolbar extends StatefulWidget {
  const ShelfToolbar({
    super.key,
    required this.state,
    required this.onChanged,
    required this.tags,
    required this.statuses,
    required this.onOpenLibraries,
  });

  final ShelfToolsState state;

  /// Called after the state object was mutated in place.
  final VoidCallback onChanged;
  final List<String> tags;
  final List<String> statuses;
  final VoidCallback onOpenLibraries;

  @override
  State<ShelfToolbar> createState() => _ShelfToolbarState();
}

class _ShelfToolbarState extends State<ShelfToolbar> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.state.query);

  @override
  void didUpdateWidget(ShelfToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A scenario switch can replace the query behind the toolbar's back.
    if (widget.state.query != _controller.text) {
      _controller.text = widget.state.query;
      _controller.selection =
          TextSelection.collapsed(offset: _controller.text.length);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            ComicTokens.spaceMd,
            ComicTokens.spaceXs,
            ComicTokens.spaceXs,
            ComicTokens.spaceXs,
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('shelf-search'),
                  controller: _controller,
                  onChanged: (value) {
                    state.query = value;
                    widget.onChanged();
                  },
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: '搜索系列、作者、标签',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: state.query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清除',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _controller.clear();
                              state.query = '';
                              widget.onChanged();
                            },
                          ),
                  ),
                ),
              ),
              IconButton(
                key: const Key('shelf-filter-toggle'),
                tooltip: '筛选',
                isSelected: state.filtersExpanded,
                icon: Badge(
                  isLabelVisible: state.libraryId != null ||
                      state.status != null ||
                      state.tag != null,
                  child: const Icon(Icons.tune),
                ),
                onPressed: () {
                  state.filtersExpanded = !state.filtersExpanded;
                  widget.onChanged();
                },
              ),
              IconButton(
                key: const Key('shelf-sort'),
                tooltip: '排序：${state.sortLabel}',
                icon: Icon(state.ascending ? Icons.sort : Icons.sort_by_alpha),
                onPressed: () => _showSortSheet(context),
              ),
            ],
          ),
        ),
        if (state.filtersExpanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              ComicTokens.spaceMd,
              0,
              ComicTokens.spaceMd,
              ComicTokens.spaceXs,
            ),
            child: Wrap(
              spacing: ComicTokens.spaceXs,
              runSpacing: 6,
              children: [
                FilterChip(
                  label: Text(state.libraryId == null
                      ? '全部媒体库'
                      : '媒体库：$previewLibraryName'),
                  selected: state.libraryId != null,
                  onSelected: (_) => widget.onOpenLibraries(),
                ),
                for (final status in widget.statuses)
                  FilterChip(
                    label: Text(_statusLabel(status)),
                    selected: state.status == status,
                    onSelected: (selected) {
                      state.status = selected ? status : null;
                      widget.onChanged();
                    },
                  ),
                for (final tag in widget.tags)
                  FilterChip(
                    label: Text(tag),
                    selected: state.tag == tag,
                    onSelected: (selected) {
                      state.tag = selected ? tag : null;
                      widget.onChanged();
                    },
                  ),
                if (state.isFiltered)
                  ActionChip(
                    avatar: const Icon(Icons.clear, size: 16),
                    label: const Text('清除筛选'),
                    onPressed: () {
                      _controller.clear();
                      state
                        ..query = ''
                        ..libraryId = null
                        ..status = null
                        ..tag = null;
                      widget.onChanged();
                    },
                  ),
              ],
            ),
          ),
        if (state.isFiltered)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              ComicTokens.spaceMd,
              0,
              ComicTokens.spaceMd,
              ComicTokens.spaceXs,
            ),
            child: Text(
              '已筛选：排序 ${state.sortLabel}${state.ascending ? ' 升序' : ' 降序'}'
              '${state.query.isEmpty ? '' : ' · 关键词「${state.query}」'}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  Future<void> _showSortSheet(BuildContext context) async {
    final state = widget.state;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in const [
              ('name', '名称'),
              ('sortName', '排序名'),
              ('dateAdded', '加入日期'),
              ('dateUpdated', '最近更新'),
              ('booksCount', '册数'),
            ])
              ListTile(
                title: Text(entry.$2),
                trailing:
                    state.sortKey == entry.$1 ? const Icon(Icons.check) : null,
                onTap: () {
                  state.sortKey = entry.$1;
                  Navigator.of(sheetContext).pop();
                  widget.onChanged();
                },
              ),
            const Divider(),
            SwitchListTile(
              title: const Text('升序'),
              value: state.ascending,
              onChanged: (value) {
                state.ascending = value;
                Navigator.of(sheetContext).pop();
                widget.onChanged();
              },
            ),
          ],
        ),
      ),
    );
  }

  String _statusLabel(String status) {
    switch (status.toUpperCase()) {
      case 'ONGOING':
        return '连载中';
      case 'ENDED':
        return '已完结';
      case 'ABANDONED':
        return '已弃坑';
      case 'HIATUS':
        return '休载';
      default:
        return status;
    }
  }
}
