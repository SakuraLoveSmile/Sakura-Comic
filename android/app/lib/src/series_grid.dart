import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'manual_sync_result.dart';
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
import 'outbox_sheet.dart';
import 'readlists_screen.dart';
import 'series_detail.dart';
import 'server_manager.dart';
import 'servers_screen.dart';
import 'settings_screen.dart';
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
    this.initialSettings,
    this.onSettingsChanged,
  });

  final LibraryRepository repository;

  /// Optional server manager — enables the server management entry point.
  final ServerManager? manager;

  /// Optional status line for a degraded core — shown only when the real Rust
  /// core is NOT running (stub fallback / init error). Null (healthy real
  /// core) or a normal screen means nothing to announce, so no banner renders:
  /// the daily-driver shelf has no developer header.
  final String? rustStatus;

  final AppSettings? initialSettings;
  final ValueChanged<AppSettings>? onSettingsChanged;

  @override
  State<SeriesGridScreen> createState() => _SeriesGridScreenState();
}

class _SeriesGridScreenState extends State<SeriesGridScreen>
    with WidgetsBindingObserver {
  late AppSettings _settings = widget.initialSettings ?? const AppSettings();
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
  bool _resettingWall = false;
  Object? _appendError;
  Object? _wallQuery;
  int _wallGeneration = 0;
  int _serverGeneration = 0;
  int _supportGeneration = 0;
  int _statusGeneration = 0;
  int _credentialGeneration = 0;

  Object get _queryKey => (
        _serverGeneration,
        _searchController.text,
        _selectedLibraryId,
        _selectedStatus,
        _selectedTag,
        _selectedGenre,
        _sortKey,
        _ascending,
      );

  bool _currentWall(int generation) => mounted && generation == _wallGeneration;

  int _beginWallReset() {
    final key = _queryKey;
    final changed = key != _wallQuery;
    _wallQuery = key;
    _wallGeneration++;
    _resettingWall = true;
    _loadingMore = false;
    _appendError = null;
    _error = null;
    if (changed) {
      _series = const [];
      _coverPaths = const {};
      _seriesTotal = 0;
    }
    return _wallGeneration;
  }

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
    if (widget.initialSettings == null) {
      widget.repository.loadAppSettings().then((s) {
        if (mounted) setState(() => _settings = s);
      }).catchError((Object _) {
        // Startup remains usable; the settings page exposes the read failure.
      });
    }
    // Stage 5 triggers: cold start syncs, coming back to the foreground
    // reconciles, and pull-to-refresh reconciles on demand.
    WidgetsBinding.instance.addObserver(this);
    _startLive();
    _initDownloads();
    _load();
  }

  void _startLive() {
    final serverGeneration = _serverGeneration;
    _live = LiveSyncController(
      widget.repository,
      reconcile: (trigger) async {
        if (mounted && serverGeneration == _serverGeneration) {
          await _reconcile(trigger, announce: false);
        }
      },
      refresh: () async {
        if (!mounted || serverGeneration != _serverGeneration) return;
        // UI 自动刷新 = 重读本地库；事件载荷从不直接进视图。
        await _loadWall(reset: true);
        if (mounted && serverGeneration == _serverGeneration) {
          await _loadSyncState();
        }
      },
      onOutbox: (status) {
        if (mounted && serverGeneration == _serverGeneration) {
          setState(() => _outbox = status);
        }
      },
      onStreamStatus: (status) {
        if (mounted && serverGeneration == _serverGeneration) {
          setState(() => _liveStatus = status);
        }
      },
    );
    _live!.start();
  }

  @override
  void didUpdateWidget(covariant SeriesGridScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository ||
        oldWidget.manager != widget.manager) {
      _serverChanged();
    }
    if (widget.initialSettings != null && widget.initialSettings != _settings) {
      _settings = widget.initialSettings!;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_settings.autoSyncMetadata) {
        _reconcile('did_become_active');
      }
      // Foreground again: retry the stream now rather than at the end of the
      // last backoff, and drain anything the background window queued.
      _live?.start();
      _live?.resume();
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
    final generation = _serverGeneration;
    final api = await widget.repository.downloadsApi();
    if (!mounted || generation != _serverGeneration) return;
    setState(() {
      _downloads = DownloadController(
        api,
        link: _device.linkClass,
        freeBytes: _device.freeDiskBytes,
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
    // After stop(): a tick in flight can still reach _notifyIfChanged, and
    // ChangeNotifier throws when it notifies after dispose.
    _downloads?.dispose();
    _recoveryTimer?.cancel();
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final generation = _serverGeneration;
    final wall = _loadWall(reset: true);
    final wallGeneration = _wallGeneration;
    try {
      await Future.wait([
        wall,
        _loadSyncState(),
        _loadSyncStatus(),
        _loadCredential(),
      ]);
    } catch (e) {
      if (!mounted ||
          generation != _serverGeneration ||
          wallGeneration != _wallGeneration) {
        return;
      }
      setState(() => _error = e);
    }
    if (mounted && generation == _serverGeneration) _maybeAutoSync();
  }

  Future<void> _loadSyncStatus() async {
    final generation = ++_statusGeneration;
    final server = _serverGeneration;
    final status = await widget.repository.fetchSyncStatus();
    if (!mounted ||
        server != _serverGeneration ||
        generation != _statusGeneration) {
      return;
    }
    setState(() => _syncStatus = status);
  }

  /// The credential verdict is a status line, not content: a store that cannot
  /// answer must leave the wall standing rather than replace it with "加载失败".
  Future<void> _loadCredential() async {
    final generation = ++_credentialGeneration;
    final server = _serverGeneration;
    AuthStateDto? state;
    try {
      state = await widget.repository.fetchCredentialState();
    } catch (_) {
      state = null;
    }
    if (!mounted ||
        server != _serverGeneration ||
        generation != _credentialGeneration) {
      return;
    }
    setState(() => _credential = state);
  }

  Future<void> _loadWall({required bool reset}) async {
    if (!mounted) return;
    if (!reset &&
        (_resettingWall ||
            _loadingMore ||
            _appendError != null ||
            _series.length >= _seriesTotal)) {
      return;
    }
    if (reset) {
      setState(() {
        _beginWallReset();
      });
    }
    final generation = _wallGeneration;
    if (!reset) _loadingMore = true;
    // Capture both repository and query before the first asynchronous boundary.
    final repository = widget.repository;
    final search =
        _searchController.text.isEmpty ? null : _searchController.text;
    final libraryId = _selectedLibraryId;
    final status = _selectedStatus;
    final tag = _selectedTag;
    final genre = _selectedGenre;
    final sort = _sortKey;
    final ascending = _ascending;
    final offset = reset ? 0 : _series.length;
    try {
      final page = await repository.querySeries(
        search: search,
        libraryId: libraryId,
        status: status,
        tag: tag,
        genre: genre,
        sort: sort,
        ascending: ascending,
        limit: 50,
        offset: offset,
      );
      if (!_currentWall(generation)) return;
      final covers = await repository.fetchCoverPaths(
        seriesIds: page.items.map((s) => s.remoteId).toList(),
      );
      if (!_currentWall(generation)) return;
      setState(() {
        _series = reset ? page.items : [..._series, ...page.items];
        _seriesTotal = page.total;
        _coverPaths = reset ? covers : {..._coverPaths, ...covers};
        _error = null;
      });
    } catch (e) {
      if (!_currentWall(generation)) return;
      setState(() {
        if (reset) {
          _error = e;
        } else {
          _appendError = e;
        }
      });
    } finally {
      if (_currentWall(generation)) {
        setState(() {
          _resettingWall = false;
          _loadingMore = false;
        });
      }
    }
  }

  /// Shelves that are NOT the series wall: libraries, filter options,
  /// continue reading, collections, readlists — all SQLite.
  Future<void> _loadSyncState() async {
    final generation = ++_supportGeneration;
    final server = _serverGeneration;
    final results = await Future.wait([
      widget.repository.fetchLibraryCounts(),
      widget.repository.fetchFilterOptions(),
      widget.repository.continueReading(limit: 10),
      widget.repository.listCollections(limit: 200),
      widget.repository.listReadlists(limit: 200),
    ]);
    if (!mounted ||
        server != _serverGeneration ||
        generation != _supportGeneration) {
      return;
    }
    setState(() {
      _libraries = results[0] as List<LibraryCount>;
      _filterOptions = results[1] as FilterOptions;
      _continueReading = results[2] as List<ContinueReadingItem>;
      _collections = (results[3] as PagedCollections).items;
      _readlists = (results[4] as PagedReadlists).items;
    });
  }

  void _loadMore() {
    unawaited(_loadWall(reset: false));
  }

  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    setState(_beginWallReset);
    final generation = _wallGeneration;
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (_currentWall(generation)) _loadWall(reset: true);
    });
  }

  /// First load with an FFI-backed repository: Bootstrap Sync when the server
  /// has never been mirrored, otherwise a Reconcile sweep (mirrors the iOS
  /// `initialLoad`). Both paths read back from SQLite afterwards.
  Future<void> _maybeAutoSync() async {
    if (_autoSynced || !widget.repository.demoSupported) return;
    _autoSynced = true;
    if (!_settings.autoSyncMetadata) return;
    if (_syncStatus.neverSynced) {
      await _sync(announce: false);
    } else {
      await _reconcile('app_launch', announce: false);
    }
  }

  /// Reconcile Sync for one trigger; the wall re-reads SQLite afterwards, so
  /// added / changed / deleted entities all land in the UI in one pass.
  Future<void> _reconcile(String trigger, {bool announce = true}) async {
    if (_syncing || !mounted) return;
    final generation = _serverGeneration;
    setState(() => _syncing = true);
    try {
      final report =
          await widget.repository.reconcileActiveServer(trigger: trigger);
      if (!mounted || generation != _serverGeneration) return;
      await _load();
      if (!mounted || generation != _serverGeneration) return;
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
      if (!mounted || generation != _serverGeneration) return;
      try {
        await _loadSyncStatus();
      } catch (_) {/* retain original failure */}
      if (!mounted || generation != _serverGeneration) return;
      _scheduleRecoveryRetry();
      if (announce) {
        final view = FailurePresentation.from(e);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('同步失败（本地库仍可用）：${view.headline}'),
        ));
      }
    } finally {
      if (mounted && generation == _serverGeneration) {
        setState(() => _syncing = false);
      }
    }
  }

  /// Acceptance chain on tap: 拉取 Series → SQLite → 补齐封面 → 重读本地库.
  Future<ManualSyncResult> _sync({bool announce = true}) async {
    if (!mounted) return const ManualSyncResult.notRun(message: '页面已关闭');
    if (_syncing) return const ManualSyncResult.notRun(message: '正在同步');
    final generation = _serverGeneration;
    final repository = widget.repository;
    setState(() => _syncing = true);
    ManualSyncResult result;
    try {
      final summary = await repository.bootstrapActiveServer();
      if (!mounted || generation != _serverGeneration) {
        return const ManualSyncResult.notRun(message: '服务器已切换');
      }
      await _load();
      result = summary == null
          ? const ManualSyncResult.notRun(message: '没有可同步的服务器或凭据（先添加并连接）')
          : ManualSyncResult.success(
              message: '已同步 ${summary.syncedSeries} 个 Series 到本地库');
    } catch (e) {
      result = ManualSyncResult.failed(e);
      if (mounted && generation == _serverGeneration) {
        try {
          await _loadSyncStatus();
        } catch (_) {/* keep the original sync error */}
        if (mounted && generation == _serverGeneration) {
          _scheduleRecoveryRetry();
        }
      }
    } finally {
      if (mounted && generation == _serverGeneration) {
        setState(() => _syncing = false);
      }
    }
    if (!mounted || generation != _serverGeneration) {
      return const ManualSyncResult.notRun(message: '服务器已切换');
    }
    if (announce) {
      final message = result.error == null
          ? result.message!
          : '同步失败：${FailurePresentation.from(result.error!).headline}';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
    return result;
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
      // A bootstrap/demo that dies mid-write must not strand the UI on the
      // loading state: re-read whatever the core committed (the mirror is
      // transactional) and say what failed.
      await _reloadLocalOnly();
      if (!mounted) return;
      final view = FailurePresentation.from(e);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('演示加载失败：${view.headline}'),
      ));
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  /// Re-read the four local shelves without touching the network. The
  /// auto-sync flag stays as it is: this is a re-read, not a sync decision.
  Future<void> _reloadLocalOnly() async {
    try {
      await Future.wait([
        _loadWall(reset: true),
        _loadSyncState(),
        _loadSyncStatus(),
        _loadCredential(),
      ]);
    } catch (_) {
      // The wall has local data from the last good read; a re-read that fails
      // again must not blank it. The caller's error path still reports.
    }
  }

  Future<void> _loadServerName() async {
    final generation = _serverGeneration;
    final manager = widget.manager;
    if (manager == null) return;
    final id = await manager.activeServerId();
    if (!mounted || generation != _serverGeneration) return;
    if (id == null) {
      if (mounted && _activeServerName != null) {
        setState(() => _activeServerName = null);
      }
      return;
    }
    final profile = await manager.get(serverId: id);
    if (!mounted || generation != _serverGeneration) return;
    setState(() => _activeServerName = profile?.displayName);
  }

  void _serverChanged() {
    if (!mounted) return;
    _serverGeneration++;
    _searchDebounce?.cancel();
    _recoveryTimer?.cancel();
    _recoveryAttempt = 0;
    final generation = _serverGeneration;
    final oldLive = _live;
    _live = null;
    _downloads?.stop();
    _downloads?.dispose();
    _downloads = null;
    widget.repository.invalidateActiveServer();
    setState(() {
      _selectedLibraryId = null;
      _selectedStatus = null;
      _selectedTag = null;
      _selectedGenre = null;
      _searchController.clear();
      _beginWallReset();
      _libraries = const [];
      _continueReading = const [];
      _collections = const [];
      _readlists = const [];
      _filterOptions = const FilterOptions();
      _credential = null;
      _outbox = null;
      _liveStatus = null;
      _activeServerName = null;
      _syncStatus = const SyncStatus();
      _autoSynced = false;
      _syncing = false;
    });
    // Old callbacks have their old generation; stop the old stream before
    // starting another session against the same repository.
    unawaited(() async {
      try {
        await oldLive?.dispose();
      } catch (_) {/* read errors remain visible via reload */}
      if (!mounted || generation != _serverGeneration) return;
      _startLive();
    }());
    _initDownloads();
    _load();
    _loadServerName();
  }

  Future<void> _openServers() async {
    final manager = widget.manager;
    if (manager == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ServersScreen(
          manager: manager,
          onChanged: _serverChanged,
        ),
      ),
    );
    await _load();
    await _loadServerName();
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          repository: widget.repository,
          manager: widget.manager,
          activeServerName: _activeServerName,
          initialSettings: _settings,
          onSettingsChanged: (next) {
            if (!mounted) return;
            setState(() => _settings = next);
            widget.onSettingsChanged?.call(next);
          },
          onServerChanged: _serverChanged,
          onManualSync: () => _sync(announce: false),
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
                repository: widget.repository,
                outbox: _outbox,
                status: _liveStatus,
                onRetry: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final n = await _live?.retryFailed();
                  messenger.showSnackBar(SnackBar(
                    content:
                        Text(n == null || n == 0 ? '没有可重试的上传' : '已重新排队 $n 项'),
                  ));
                },
              ),
            if (_downloads case final downloads?)
              // Scoped to the badge: the controller ticks every second, and
              // listening at the screen level is what used to rebuild the whole
              // tile wall once a second.
              ListenableBuilder(
                listenable: downloads,
                builder: (context, _) => IconButton(
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
            IconButton(
              onPressed: _openSettings,
              tooltip: '设置',
              icon: const Icon(Icons.settings_outlined),
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
            // Developer-status line, degraded-core modes only (see the field
            // doc on [SeriesGridScreen.rustStatus]). Deliberately quiet: a
            // healthy real core must not decorate the daily shelf.
            if (widget.rustStatus != null)
              Container(
                width: double.infinity,
                color: Theme.of(context).colorScheme.errorContainer,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(
                  widget.rustStatus!,
                  key: const ValueKey('core-status-banner'),
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
    if (_series.isEmpty &&
        _seriesTotal == 0 &&
        _libraries.isEmpty &&
        !_resettingWall &&
        _error == null &&
        _searchController.text.isEmpty &&
        _selectedLibraryId == null &&
        _selectedStatus == null &&
        _selectedTag == null &&
        _selectedGenre == null) {
      final isStub = !widget.repository.demoSupported;
      final noServer = widget.manager != null &&
          (_activeServerName == null ||
              _activeServerName == '未选择服务器' ||
              _activeServerName == '未连接服务器');
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                noServer ? Icons.cloud_off_outlined : Icons.menu_book_outlined,
                size: 48,
                color: Colors.grey,
              ),
              const SizedBox(height: 12),
              Text(
                noServer
                    ? '未连接服务器 — 请先添加并连接 Komga 服务器'
                    : isStub
                        ? '演示模式 — 未加载真实核心'
                        : '媒体库暂无内容 — 已连接服务器，可手动同步或加载演示内容',
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
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
                  if (!noServer && !isStub)
                    OutlinedButton.icon(
                      onPressed:
                          _syncing ? null : () => _reconcile('manual_refresh'),
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('立即同步'),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _reconcile('manual_refresh'),
      child: CustomScrollView(
        // Two tests drag this key to trigger pull-to-refresh
        // (`sync_triggers_test.dart`); dropping it would turn them into
        // silent no-ops that still pass.
        key: const ValueKey('shelf-list'),
        // Load-bearing: without it, pull-to-refresh dies whenever the content
        // is shorter than the viewport (empty search result, one-library filter).
        physics: const AlwaysScrollableScrollPhysics(),
        // The wall has to build ahead of the eye or the next page lands after
        // the user has already hit the blank end of the list. The default is
        // 250 px — under one 210 px row of tiles — so the pre-fetch would only
        // fire once the last row was already on screen. Not higher: cacheExtent
        // also pre-resolves covers, so it trades against the image budget.
        cacheExtent: 600,
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _searchField(),
                  if (_resettingWall) const LinearProgressIndicator(),
                  if (_error != null || _appendError != null) ...[
                    Text(
                        FailurePresentation.from((_appendError ?? _error)!)
                            .headline,
                        key: const ValueKey('wall-error-headline')),
                    if (FailurePresentation.from((_appendError ?? _error)!)
                        .detail
                        .isNotEmpty)
                      Text(
                          FailurePresentation.from((_appendError ?? _error)!)
                              .detail,
                          key: const ValueKey('wall-error-detail')),
                    TextButton(
                      onPressed: () {
                        if (_appendError != null) {
                          setState(() => _appendError = null);
                          _loadMore();
                        } else {
                          _loadWall(reset: true);
                        }
                      },
                      child: const Text('重试加载'),
                    ),
                  ],
                  const SizedBox(height: 8),
                  _libraryChips(),
                  const SizedBox(height: 8),
                  _shelfControls(),
                  if (_continueReading.isNotEmpty &&
                      _searchController.text.isEmpty) ...[
                    const SizedBox(height: 12),
                    _continueReadingShelf(),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    '共 $_seriesTotal 个 Series',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 4),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            sliver: _seriesGrid(),
          ),
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
            _chip('${lib.name} ${lib.seriesCount}',
                _selectedLibraryId == lib.remoteId, () {
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
            label: Text(_selectedStatus ?? '状态',
                style: const TextStyle(fontSize: 12)),
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
            label: Text(_selectedTag ?? '标签',
                style: const TextStyle(fontSize: 12)),
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
            label: Text(_selectedGenre ?? '题材',
                style: const TextStyle(fontSize: 12)),
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
          icon: Icon(_ascending ? Icons.arrow_upward : Icons.arrow_downward,
              size: 18),
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
                      color:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
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
                        Text(
                            '第 ${row.page ?? '?'} / ${row.totalPages ?? '?'} 页',
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
    final (maxExtent, spacing) = switch (_settings.gridDensity) {
      'compact' => (110.0, 8.0),
      'spacious' => (180.0, 16.0),
      _ => (140.0, 12.0),
    };
    return SliverGrid(
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: maxExtent,
        mainAxisSpacing: spacing,
        crossAxisSpacing: spacing,
        childAspectRatio: 2 / 3,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final item = _series[index];
          // Only reachable for tiles the viewport (plus cacheExtent) actually
          // needs. Under the old shrinkWrap grid every index was built on every
          // rebuild, so this fired repeatedly and drained the whole library.
          if (index >= _series.length - 5) {
            _loadMore();
          }
          return SeriesWallTile(
            key: ValueKey('series-tile-${item.remoteId}'),
            series: item,
            coverPath: _coverPaths[item.remoteId],
            onTap: () => _openSeries(item.remoteId),
          );
        },
        childCount: _series.length,
        // Tiles are stateless: nothing to keep alive. Repaint boundaries are
        // the delegate default — stated so they are not "added" later.
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: true,
      ),
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
}

/// One tile of the series wall — the local cover file (path from the
/// `thumbnails` table) plus the series name.
///
/// A top-level widget rather than an inline builder closure so the tile is a
/// *type* the tests can count. `find.byType(SeriesWallTile).evaluate().length`
/// is how the wall's laziness is pinned: it must stay proportional to the
/// viewport, not to how many pages have been loaded (`test/shelf_scale_test.dart`).
class SeriesWallTile extends StatelessWidget {
  const SeriesWallTile({
    super.key,
    required this.series,
    required this.coverPath,
    required this.onTap,
  });

  final Series series;

  /// Local file path from SQLite, or null when the cover was never cached.
  final String? coverPath;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _cover(context)),
          const SizedBox(height: 4),
          Text(
            series.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _cover(BuildContext context) {
    final path = coverPath;
    if (path == null) return _placeholder(context);

    // Decode at the size the tile will actually paint at. Without this a
    // 600x900 cover decodes at full resolution (2.16 MB) into a ~140 logical px
    // slot and is scaled down at paint time — across a wall of tiles that is
    // what evicts the image cache and forces re-decodes.
    //
    // `cacheWidth` only, never `cacheHeight`: one dimension keeps the aspect
    // ratio and `BoxFit.cover` crops. Same pattern as the reader
    // (`reader_screen.dart`).
    //
    // Measured with `LayoutBuilder` rather than derived from the grid
    // delegate's `maxCrossAxisExtent`, which is only an upper bound: this
    // reports the real slot width and adapts to density and orientation.
    //
    // The demo cover (`demo_png.rs`) is hard-coded 200x300, so on a `spacious`
    // tile this target exceeds the source and the codec upscales. Real Komga
    // thumbnails are >= 600 px, so the daily-driver wall only ever downsamples.
    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.of(context).devicePixelRatio;
        final targetPx = (constraints.maxWidth * dpr).round();
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            File(path),
            fit: BoxFit.cover,
            cacheWidth: targetPx > 0 ? targetPx : null,
            errorBuilder: (_, __, ___) => _placeholder(context),
          ),
        );
      },
    );
  }

  Widget _placeholder(BuildContext context) {
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
  const _LiveSyncBadge({
    required this.repository,
    required this.outbox,
    required this.status,
    required this.onRetry,
  });

  final LibraryRepository repository;
  final OutboxStatusDto? outbox;
  final String? status;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final failed = outbox?.failed ?? 0;
    final queued = (outbox?.total ?? 0) - failed;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: IconButton(
        tooltip: [
          if (queued > 0) '$queued 项客户端写操作待上传',
          if (failed > 0) '$failed 项已放弃（点击查看）',
          if (status != null) status!,
          if (queued == 0 && failed == 0 && status == null) '事件流正常',
        ].join('；'),
        onPressed: () {
          showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            builder: (_) => OutboxSheet(
              repository: repository,
              initialStatus: outbox,
              onRetry: onRetry,
            ),
          );
        },
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
