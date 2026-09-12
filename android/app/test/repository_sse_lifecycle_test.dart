import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:comic_app/src/auth_store.dart';
import 'package:comic_app/src/library_repository.dart';
import 'package:comic_app/src/rust_core_api.dart';
import 'package:comic_app/src/rust/model/server_profile.dart';
import 'package:comic_app/src/server_manager.dart';

import 'fakes.dart';

class _StreamApi extends MemoryRustCoreApi {
  final polled = <String>[];
  final stopped = <String>[];
  final reconciled = <String>[];

  @override
  Future<SsePollResult?> ssePoll(
      {required String dbPath,
      required String serverId,
      required String baseUrl,
      required String apiKey,
      required String stateJson}) async {
    polled.add(serverId);
    return null;
  }

  @override
  Future<void> sseStop(
      {required String dbPath, required String serverId}) async {
    stopped.add(serverId);
  }

  @override
  Future<String> sseReconciled(
      {required String dbPath,
      required String serverId,
      required String stateJson}) async {
    reconciled.add(serverId);
    return stateJson;
  }
}

class _DelayedSecrets extends InMemorySecretStore {
  final entered = Completer<void>();
  final released = Completer<void>();
  @override
  Future<String?> read(String ref) async {
    if (!entered.isCompleted) entered.complete();
    await released.future;
    return 'fixture-only';
  }
}

void main() {
  _StreamApi api() {
    final api = _StreamApi();
    for (final id in ['old', 'new']) {
      api.servers[id] = ServerProfile(
          id: id,
          displayName: id,
          baseUrl: 'http://127.0.0.1:1',
          authType: AuthType.apiKey,
          credentialRef: id,
          capabilities: const []);
    }
    api.activeId = 'old';
    return api;
  }

  test('stop closes the polled server after the active profile changes',
      () async {
    final core = api();
    final manager = ServerManager(
        dbPath: '/tmp/unused.sqlite',
        api: core,
        secrets: InMemorySecretStore({'old': 'fixture', 'new': 'fixture'}));
    final repo = RustLibraryRepository(
        dbPath: '/tmp/unused.sqlite', api: core, serverManager: manager);
    await repo.ssePoll(stateJson: '');
    expect(core.polled, ['old']);
    await manager.switchTo(serverId: 'new');
    // The new active profile must not silently receive the old stream's state.
    await repo.ssePoll(stateJson: 'old-state');
    expect(core.polled, ['old']);
    await repo.sseStop();
    expect(core.stopped, ['old', 'old']);
    await repo.sseReconciled(stateJson: 'old-state');
    expect(core.reconciled, isEmpty);
    await repo.ssePoll(stateJson: '');
    expect(core.polled, ['old', 'new']);
    await repo.sseStop();
    expect(core.stopped, ['old', 'old', 'new']);
  });

  for (final changeServer in [false, true]) {
    test(
        'pending credential lookup cannot open a stream after ${changeServer ? 'switch' : 'stop'}',
        () async {
      final core = api();
      final secrets = _DelayedSecrets();
      final manager = ServerManager(
          dbPath: '/tmp/unused.sqlite', api: core, secrets: secrets);
      final repo = RustLibraryRepository(
          dbPath: '/tmp/unused.sqlite', api: core, serverManager: manager);
      final pending = repo.ssePoll(stateJson: '');
      await secrets.entered.future;
      if (changeServer) await manager.switchTo(serverId: 'new');
      await repo.sseStop();
      secrets.released.complete();
      expect(await pending, isNull);
      expect(core.polled, isEmpty);
      expect(core.stopped, changeServer ? ['old'] : isEmpty);
    });
  }
}
