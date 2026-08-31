import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'collections_screen.dart';
import 'download_controller.dart';
import 'downloads_screen.dart';
import 'reader_device.dart';
import 'libraries_screen.dart';
import 'library_repository.dart';
import 'live_sync.dart';
import 'error_presentation.dart';
import 'rust/ffi/error.dart' show ErrorCode;
import 'rust_core_api.dart' show AuthStateDto, OutboxStatusDto;
import 'models.dart';
import 'readlists_screen.dart';
import 'series_detail.dart';
import 'server_manager.dart';
import 'servers_screen.dart';
import 'series.dart';

/// The media library browser — reading series/books/collections/readlists/
/// progress from the local store ([LibraryRepository]); network is confined
/// to sync/demo/cover actions (Local First: 本地数据库负责展示). Everything
/// renders with the network disconnected.
///
/// Tabs: 书架 (wall + continue reading + search/filters/sort) / 合集 / 书单.
class SeriesGridScreen extends StatefulWidget {
  const SeriesGridScreen({
    super.key,
    this.repository = const StubLibraryRepository(),
    this.manager,
    this.rustStatus,
  });

  final LibraryRepository repository;

  /// Optional server manager — enables the server management entry point.
  final ServerManager? manager;

  /// Optional FFI connectivity banner (e.g. "Rust core FFI 已连接").
  final String? rustStatus;

  @override
  State<SeriesGridScreen> createState() => _SeriesGridScreenState();
}

class _SeriesGridScreenState extends State<SeriesGridScreen>
    with WidgetsBindingObserver {
  List<Series> _series = const [];
  Map<String, String> _coverPaths = const {};
  Object? _error;
  String? _activeServerName;
  bool _syncing = false;
  bool _autoSynced = false;
  SyncStatus _syncStatus = const SyncStatus();

  /// Stage 10: what the last credentialed contact proved. Drives the
  /// re-authenticate banner and nothing else.
  AuthStateDto? _credential;

  /// Offline recovery. The shell has no connectivity plugin, so "the network
  /// came back" is detected the honest way: retry a sweep that failed, on a
  /// bounded backoff, and let the first success *be* the recovery moment
  /// (`network_recovered`).
  static const List<Duration> _recoveryDelays = [
    Duration(seconds: 15),
    Duration(seconds: 60),
    Duration(seconds: 300),
  ];
  Timer? _recoveryTimer;
  int _recoveryAttempt = 0;

  // Stage 4 query state (全部本地：SQLite).
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  String? _selectedLibraryId;
  String? _selectedStatus;
  String? _selectedTag;
  String? _selectedGenre;
  String _sortKey = 'name';
  bool _ascending = true;
  int _seriesTotal = 0;
  bool _loadingMore = false;

  List<ContinueReadingItem> _continueReading = const [];
  List<LibraryCount> _libraries = const [];
  FilterOptions _filterOptions = const FilterOptions();
  List<CollectionItem> _collections = const [];
  List<ReadlistItem> _readlists = const [];

  // Stage 6: the event stream + Outbox drainer. Owns no rules of its own — the
  // core decides backoff, conflicts and cleanup; this only decides when to ask.
  LiveSyncController? _live;

  // Stage 9: the download queue. Created here, above every route, because a download
  // that stopped the moment the user opened a book would be the wrong shape of
  // "the user is not watching".
  DownloadController? _downloads;
  final ReaderDevice _device = ReaderDevice();
  OutboxStatusDto? _outbox;
  String? _liveStatus;

  @override
  void initState() {
    super.initState();
    // Stage 5 triggers: cold start syncs, coming back to the foreground
    // reconciles, and pull-to-refresh reconciles on demand.
    WidgetsBinding.instance.addObserver(this);
    _live = LiveSyncController(
      widget.repository,
      reconcile: (trigger) => _reconcile(trigger, announce: false),
      refresh: () async {
        // UI 自动刷新 = 重读本地库；事件载荷从不直接进视图。
        await _loadWall(reset: true);
        await _loadSyncState();
      },
      onOutbox: (status) {
        if (mounted) setState(() => _outbox = status);
      },
      onStreamStatus: (status) {
        if (mounted) setState(() => _liveStatus = status);
      },
    );
    _live!.start();
    _initDownloads();
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _reconcile('did_become_active');
      // Foreground again: retry the stream now rather than at the end of the
      // last backoff, and drain anything the background window queued.
      _live!.start();
      _live!.resume();
      // The queue is durable and the transfer is not: coming back pays the sweep the
      // core runs on the first pump, and picks up mid-page-list.
      _downloads?.resume();
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Backgrounded: stop listening. Events missed here cannot be replayed
      // (the server sends no resume token), which is why resume() sweeps.
      _live?.stop();
      _downloads?.stop();
    }
  }

  /// Build the download controller once the active credential is known.
  Future<void> _initDownloads() async {
    final api = await widget.repository.downloadsApi();
    if (!mounted) return;
    setState(() {
      _downloads = DownloadController(
        api,
        link: _device.linkClass,
        freeBytes: _device.freeDiskBytes,
        onUpdate: () {
          if (mounted) setState(() {});
        },
      )..start();
    });
  }

  /// Schedules the next recovery attempt after a sweep failed offline.
  void _scheduleRecoveryRetry() {
    if (_recoveryAttempt >= _recoveryDelays.length) return;
    _recoveryTimer?.cancel();
    _recoveryTimer = Timer(_recoveryDelays[_recoveryAttempt++], () {
      _reconcile('network_recovered');
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _live?.dispose();
    _downloads?.stop();
    _recoveryTimer?.cancel();
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await Future.wait([
        _loadWall(reset: true),
        _loadSyncState(),
        _loadCovers(),
        _loadSyncStatus(),
        _loadCredential(),
      ]);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
    _maybeAutoSync();
  }

  Future<void> _loadSyncStatus() async {
    final status = await widget.repository.fetchSyncStatus();
    if (!mounted) return;
    setState(() => _syncStatus = status);
  }

  /// The credential verdict is a status line, not content: a store that cannot
  /// answer must leave the wall standing rather than replace it with "加载失败".
  Future<void> _loadCredential() async {
    AuthStateDto? state;
    try {
      state = await widget.repository.fetchCredentialState();
    } catch (_) {
      state = null;
    }
    if (!mounted) return;
    setState(() => _credential = state);
  }

  Future<void> _loadCovers() async {
    final covers = await widget.repository.fetchCoverPaths();
    if (!mounted) return;
    setState(() => _coverPaths = covers);
  }

  Future<void> _loadWall({required bool reset}) async {
    final offset = reset ? 0 : _series.length;
    final page = await widget.repository.querySeries(
      search: _searchController.text.isEmpty ? null : _searchController.text,
      libraryId: _selectedLibraryId,
      status: _selectedStatus,
      tag: _selectedTag,
      genre: _selectedGenre,
      sort: _sortKey,
      ascending: _ascending,
      limit: 50,
      offset: offset,
    );
    if (!mounted) return;
    setState(() {
      _series = reset ? page.items : [..._series, ...page.items];
      _seriesTotal = page.total;
      _error = null;
    });
  }

  /// Shelves that are NOT the series wall: libraries, filter options,
  /// continue reading, collections, readlists — all SQLite.
  Future<void> _loadSyncState() async {
    final results = await Future.wait([
      widget.repository.fetchLibraryCounts(),
      widget.repository.fetchFilterOptions(),
      widget.repository.continueReading(limit: 10),
      widget.repository.listCollections(limit: 200),
      widget.repository.listReadlists(limit: 200),
    ]);
    if (!mounted) return;
    setState(() {
      _libraries = results[0] as List<LibraryCount>;
      _filterOptions = results[1] as FilterOptions;
      _continueReading = results[2] as List<ContinueReadingItem>;
      _collections = (results[3] as PagedCollections).items;
      _readlists = (results[4] as PagedReadlists).items;
    });
  }

  void _loadMore() {
    if (_loadingMore || _series.length >= _seriesTotal) return;
    _loadingMore = true;
    _loadWall(reset: false).whenComplete(() => _loadingMore = false);
  }

  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      _loadWall(reset: true);
    });
  }

  /// First load with an FFI-backed repository: Bootstrap Sync when the server
  /// has never been mirrored, otherwise a Reconcile sweep (mirrors the iOS
  /// `initialLoad`). Both paths read back from SQLite afterwards.
  Future<void> _maybeAutoSync() async {
    if (_autoSynced || !widget.repository.demoSupported) return;
    _autoSynced = true;
    if (_syncStatus.neverSynced) {
      await _sync(announce: false);
    } else {
      await _reconcile('app_launch', announce: false);
    }
  }

  /// Reconcile Sync for one trigger; the wall re-reads SQLite afterwards, so
  /// added / changed / deleted entities all land in the UI in one pass.
  Future<void> _reconcile(String trigger, {bool announce = true}) async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      final report = await widget.repository.reconcileActiveServer(trigger: trigger);
      await _load();
      // Reaching the server again ends the recovery ladder.
      _recoveryTimer?.cancel();
      _recoveryAttempt = 0;
      // ...and it is also the moment the event stream should not sit out its
      // backoff any longer.
      _live?.resume();
      if (!mounted || report == null) return;
      if (announce) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(report.message)));
      }
    } catch (e) {
      // An unreachable server must never take the shelf down with it: the
      // local mirror keeps serving (and `sync_state` says what failed), and
      // the sweep is retried as the network-recovery trigger.
      await _loadSyncStatus();
      _scheduleRecoveryRetry();
      if (!mounted) return;
      if (announce) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('同步失败（本地库仍可用）: $e')));
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  /// Acceptance chain on tap: 拉取 Series → SQLite → 补齐封面 → 重读本地库.
  Future<void> _sync({bool announce = true}) async {
    setState(() => _syncing = true);
    try {
      final summary = await widget.repository.bootstrapActiveServer();
      await _load();
      if (!mounted) return;
      if (announce) {
        final message = summary == null
            ? '没有可同步的服务器（先添加并连接）'
            : '已同步 ${summary.syncedSeries} 个 Series 到本地库';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e) {
      await _loadSyncStatus();
      _scheduleRecoveryRetry();
      if (!mounted) return;
      if (announce) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('同步失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  /// Offline demo: fixture full media library + generated covers.
  Future<void> _loadDemo() async {
    setState(() => _syncing = true);
    try {
      final summary = await widget.repository.loadDemo();
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('演示数据：${summary.syncedSeries} 个 Series')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('演示加载失败: $e')));
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _loadServerName() async {
    final manager = widget.manager;
    if (manager == null) return;
    final id = await manager.activeServerId();
    if (id == null) {
      if (mounted && _activeServerName != null) {
        setState(() => _activeServerName = null);
      }
      return;
    }
    final profile = await manager.get(serverId: id);
    if (!mounted) return;
    setState(() => _activeServerName = profile?.displayName);
  }

  Future<void> _openServers() async {
    final manager = widget.manager;
    if (manager == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ServersScreen(
          manager: manager,
          onChanged: () {
            _load();
            _loadServerName();
          },
        ),
      ),
    );
    await _load();
    await _loadServerName();
  }

  @override
  Widget build(BuildContext context) {
    final manager = widget.manager;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_activeServerName ?? 'Library'),
          actions: [
            // Outbox badge (SQLite only, so it is truthful while offline).
            if ((_outbox?.total ?? 0) > 0 || _liveStatus != null)
              _LiveSyncBadge(
                outbox: _outbox,
                status: _liveStatus,
                onRetry: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final n = await _live?.retryFailed();
                  messenger.showSnackBar(SnackBar(
                    content: Text(n == null || n == 0 ? '没有可重试的上传' : '已重新排队 $n 项'),
                  ));
                },
              ),
            if (_downloads case final downloads?)
              IconButton(
                key: const Key('open-downloads'),
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => DownloadsScreen(controller: downloads),
                    ),
                  );
                },
                // No controller yet means the credential has not resolved, which is
                // also the moment the queue has nothing to show. The icon arrives
                // when the data behind it does, rather than being tappable to a
                // blank screen.
                tooltip: downloads.hasWork ? '下载（进行中）' : '下载',
                icon: Badge(
                  isLabelVisible: downloads.hasWork,
                  label: Text('${downloads.books.length}'),
                  child: const Icon(Icons.download_outlined),
                ),
              ),
            IconButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => LibrariesScreen(
                      repository: widget.repository,
                      selectedLibraryId: _selectedLibraryId,
                      onSelected: (libraryId) {
                        setState(() => _selectedLibraryId = libraryId);
                        _loadWall(reset: true);
                      },
                    ),
                  ),
                );
              },
              tooltip: '图书馆',
              icon: const Icon(Icons.library_books_outlined),
            ),
            if (manager != null)
              IconButton(
                onPressed: _openServers,
                tooltip: '服务器',
                icon: const Icon(Icons.dns_outlined),
              ),
            if (widget.repository.demoSupported)
              IconButton(
                onPressed: _syncing ? null : _loadDemo,
                tooltip: '演示（本地媒体库）',
                icon: const Icon(Icons.auto_awesome_outlined),
              ),
            IconButton(
              onPressed: _syncing ? null : _sync,
              tooltip: '同步',
              icon: _syncing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: '书架'),
              Tab(text: '合集'),
              Tab(text: '书单'),
            ],
          ),
        ),
        body: Column(
          children: [
            if (widget.rustStatus != null)
              Container(
                width: double.infinity,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(
                  widget.rustStatus!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            _syncStatusBanner(),
            _credentialBanner(),
            Expanded(
              child: TabBarView(
                children: [
                  _buildBody(),
                  CollectionsScreen(
                    repository: widget.repository,
                    collections: _collections,
                    coverPaths: _coverPaths,
                  ),
                  ReadlistsScreen(
                    repository: widget.repository,
                    readlists: _readlists,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Stage 5 sync state (`sync_state`) surfaced where the shelf is read.
  Widget _syncStatusBanner() {
    return Container(
      key: const ValueKey('sync-status'),
      width: double.infinity,
      color: _syncStatus.failed
          ? Theme.of(context).colorScheme.errorContainer
          : Theme.of(context).colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Text(
        _syncStatus.label,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  /// A rejected credential is the one failure the user has to fix themselves, so
  /// it gets a line of its own and a way out of it. `unknown` deliberately gets
  /// neither: never having asked is not the same as being wrong, and a banner
  /// that appears on a fresh install would send the user to change a key that
  /// works.
  Widget _credentialBanner() {
    if (credentialStatusOf(_credential?.state) != CredentialStatus.expired) {
      return const SizedBox.shrink();
    }
    return Material(
      key: const ValueKey('credential-banner'),
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Row(
          children: [
            const Icon(Icons.lock_outline, size: 16),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                failureHeadline(ErrorCode.authExpired),
                key: const ValueKey('credential-headline'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            // No manager means no way to edit a credential on this device, so
            // the banner says what is wrong without offering a dead button.
            if (widget.manager != null)
              TextButton(
                key: const ValueKey('credential-reauth'),
                onPressed: _openServers,
                child: const Text('重新登录'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(child: Text('加载失败: $_error'));
    }
    if (_series.isEmpty && _seriesTotal == 0 && _libraries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('暂无 Series — 添加服务器并同步后显示封面墙'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              children: [
                if (widget.manager != null)
                  FilledButton.tonal(
                    onPressed: _openServers,
                    child: const Text('管理服务器'),
                  ),
                if (widget.repository.demoSupported)
                  FilledButton(
                    onPressed: _syncing ? null : _loadDemo,
                    child: const Text('加载演示媒体库'),
                  ),
              ],
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _reconcile('manual_refresh'),
      child: ListView(
        key: const ValueKey('shelf-list'),
        padding: const EdgeInsets.all(12),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
        _searchField(),
        const SizedBox(height: 8),
        _libraryChips(),
        const SizedBox(height: 8),
        _shelfControls(),
        if (_continueReading.isNotEmpty && _searchController.text.isEmpty) ...[
          const SizedBox(height: 12),
          _continueReadingShelf(),
        ],
        const SizedBox(height: 12),
        Text(
          '共 $_seriesTotal 个 Series',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        _seriesGrid(),
        ],
      ),
    );
  }

  Widget _searchField() {
    return TextField(
      controller: _searchController,
      onChanged: _onSearchChanged,
      decoration: const InputDecoration(
        hintText: '搜索 Series（本地 FTS）…',
        prefixIcon: Icon(Icons.search),
        isDense: true,
        border: OutlineInputBorder(),
      ),
    );
  }

  Widget _libraryChips() {
    return SizedBox(
      height: 32,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _chip('全部', _selectedLibraryId == null, () {
            setState(() => _selectedLibraryId = null);
            _loadWall(reset: true);
          }),
          for (final lib in _libraries)
            _chip('${lib.name} ${lib.seriesCount}', _selectedLibraryId == lib.remoteId, () {
              setState(() => _selectedLibraryId = lib.remoteId);
              _loadWall(reset: true);
            }),
        ],
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: selected,
        onSelected: (_) => onTap(),
      ),
    );
  }

  Widget _shelfControls() {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        PopupMenuButton<String>(
          initialValue: _selectedStatus,
          onSelected: (value) {
            setState(() => _selectedStatus = value);
            _loadWall(reset: true);
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: '全部', child: Text('全部状态')),
            for (final s in _filterOptions.statuses)
              PopupMenuItem(value: s, child: Text(s)),
          ],
          child: Chip(
            avatar: const Icon(Icons.filter_alt_outlined, size: 16),
            label: Text(_selectedStatus ?? '状态', style: const TextStyle(fontSize: 12)),
          ),
        ),
        PopupMenuButton<String>(
          initialValue: _selectedTag,
          onSelected: (value) {
            setState(() => _selectedTag = value);
            _loadWall(reset: true);
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: '全部', child: Text('全部标签')),
            for (final t in _filterOptions.tags)
              PopupMenuItem(value: t, child: Text(t)),
          ],
          child: Chip(
            avatar: const Icon(Icons.tag, size: 16),
            label: Text(_selectedTag ?? '标签', style: const TextStyle(fontSize: 12)),
          ),
        ),
        PopupMenuButton<String>(
          initialValue: _selectedGenre,
          onSelected: (value) {
            setState(() => _selectedGenre = value);
            _loadWall(reset: true);
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: '全部', child: Text('全部题材')),
            for (final g in _filterOptions.genres)
              PopupMenuItem(value: g, child: Text(g)),
          ],
          child: Chip(
            avatar: const Icon(Icons.theaters_outlined, size: 16),
            label: Text(_selectedGenre ?? '题材', style: const TextStyle(fontSize: 12)),
          ),
        ),
        PopupMenuButton<String>(
          initialValue: _sortKey,
          onSelected: (value) {
            setState(() => _sortKey = value);
            _loadWall(reset: true);
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'name', child: Text('按名称')),
            PopupMenuItem(value: 'sortName', child: Text('按排序名')),
            PopupMenuItem(value: 'dateAdded', child: Text('按加入日期')),
            PopupMenuItem(value: 'dateUpdated', child: Text('按最近更新')),
            PopupMenuItem(value: 'booksCount', child: Text('按册数')),
          ],
          child: Chip(
            avatar: const Icon(Icons.sort, size: 16),
            label: Text(_sortLabel(), style: const TextStyle(fontSize: 12)),
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: _ascending ? '升序' : '降序',
          icon: Icon(_ascending ? Icons.arrow_upward : Icons.arrow_downward, size: 18),
          onPressed: () {
            setState(() => _ascending = !_ascending);
            _loadWall(reset: true);
          },
        ),
      ],
    );
  }

  String _sortLabel() {
    switch (_sortKey) {
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

  Widget _continueReadingShelf() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('继续阅读', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        SizedBox(
          height: 96,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _continueReading.length,
            itemBuilder: (context, index) {
              final row = _continueReading[index];
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: InkWell(
                  onTap: () => _openSeries(row.seriesId),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: 200,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(row.seriesName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall),
                        Text(row.bookTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(
                          value: (row.progressPercent ?? 0) / 100.0,
                          minHeight: 4,
                        ),
                        const SizedBox(height: 2),
                        Text('第 ${row.page ?? '?'} / ${row.totalPages ?? '?'} 页',
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _seriesGrid() {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 140,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 2 / 3,
      ),
      itemCount: _series.length,
      itemBuilder: (context, index) {
        final item = _series[index];
        if (index >= _series.length - 5) {
          _loadMore();
        }
        return InkWell(
          onTap: () => _openSeries(item.remoteId),
          borderRadius: BorderRadius.circular(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _coverFor(item)),
              const SizedBox(height: 4),
              Text(
                item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }

  void _openSeries(String seriesId) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SeriesDetailScreen(
          repository: widget.repository,
          downloads: _downloads,
          seriesId: seriesId,
          onChanged: () {
            _load();
          },
        ),
      ),
    );
  }

  /// The cover wall tile: the local file path comes from SQLite
  /// (`thumbnails` table) and the image is rendered straight from disk.
  Widget _coverFor(Series item) {
    final path = _coverPaths[item.remoteId];
    if (path != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(path),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _coverPlaceholder(),
        ),
      );
    }
    return _coverPlaceholder();
  }

  Widget _coverPlaceholder() {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.menu_book_outlined),
    );
  }
}



/// The Stage 6 status pill: queued uploads, and a way to release given-up ones.
class _LiveSyncBadge extends StatelessWidget {
  const _LiveSyncBadge({required this.outbox, required this.status, required this.onRetry});

  final OutboxStatusDto? outbox;
  final String? status;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final failed = outbox?.failed ?? 0;
    final queued = (outbox?.total ?? 0) - failed;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: IconButton(
        tooltip: [
          if (queued > 0) '$queued 项客户端写操作待上传',
          if (failed > 0) '$failed 项已放弃（点开重试）',
          if (status != null) status!,
          if (queued == 0 && failed == 0 && status == null) '事件流正常',
        ].join('；'),
        onPressed: failed > 0 ? () => onRetry() : null,
        icon: Icon(
          failed > 0
              ? Icons.cloud_off
              : queued > 0
                  ? Icons.cloud_upload_outlined
                  : Icons.cloud_done_outlined,
        ),
      ),
    );
  }
}
