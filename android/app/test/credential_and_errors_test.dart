import 'dart:convert';
import 'dart:io';

import 'package:comic_app/src/error_presentation.dart';
import 'package:comic_app/src/library_repository.dart';
import 'package:comic_app/src/models.dart';
import 'package:comic_app/src/rust/ffi/application.dart';
import 'package:comic_app/src/rust/sync/bootstrap.dart';
import 'package:comic_app/src/series.dart';
import 'package:comic_app/src/rust/ffi/error.dart';
import 'package:comic_app/src/rust_core_api.dart';
import 'package:comic_app/src/series_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// `specs/contracts/fixtures/errors/codes.json` is the contract; Rust and Swift
/// each load it from their own test suites. This file closes the third side: the
/// Dart enum is generated from Rust, so without this leg a rename could reach
/// Dart as a silently different name and the UI would fall back to `unknown` for
/// a code it means to act on.
Map<String, dynamic> loadCodeContract() {
  final file = File('../../specs/contracts/fixtures/errors/codes.json');
  expect(file.existsSync(), isTrue, reason: 'fixture must be read from the repo, not copied');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

List<Map<String, dynamic>> get contractCodes =>
    (loadCodeContract()['codes'] as List).cast<Map<String, dynamic>>();

void main() {
  group('the shared error-code contract', () {
    test('the generated Dart enum is exactly the fixture list, in order', () {
      final fixture = contractCodes.map((entry) => entry['code'] as String).toList();
      // `describeEnum`-style naming on purpose: the wire name is the generated
      // enum's own name, so a rename on either side shows up here as a diff.
      final dart = ErrorCode.values.map((code) => code.name).toList();
      expect(dart, fixture);
    });

    test('each code\'s two policy bits match the fixture', () {
      for (final entry in contractCodes) {
        final code = ErrorCode.values.firstWhere((c) => c.name == entry['code']);
        final error = CoreError(
          code: code,
          message: 'from the fixture',
          retryable: entry['retryable'] as bool,
          needsUser: entry['needsUser'] as bool,
        );
        final view = FailurePresentation.from(error);
        expect(view.retryable, entry['retryable'], reason: '${code.name} retryable');
        expect(view.needsReauth, entry['needsUser'], reason: '${code.name} needsUser');
      }
    });

    test('no other code\'s sentence asks the user for a credential', () {
      // The point of `needsUser` in the UI: exactly one code may suggest that
      // the key is the problem. If another headline mentioned re-entering it,
      // a lost tunnel would send the user to change a working key.
      for (final code in ErrorCode.values) {
        final text = failureHeadline(code);
        if (code == ErrorCode.authExpired) {
          expect(text, contains('API Key'));
        } else {
          expect(
            text,
            isNot(anyOf(contains('API Key'), contains('重新输入'))),
            reason: '${code.name} must not ask for a credential',
          );
        }
      }
    });

    test('every code has its own headline, and unknown does not borrow one', () {
      final headlines = ErrorCode.values.map(failureHeadline).toList();
      expect(headlines.toSet().length, ErrorCode.values.length,
          reason: 'two codes sharing a sentence means one of them is unlabelled');
      expect(failureHeadline(ErrorCode.unknown), isNot(contains('登录')));
    });
  });

  group('a failure that is not a CoreError', () {
    test('is rendered honestly and never sends the user to re-authenticate', () {
      // A platform-channel error or a Dart bug says nothing about a credential.
      final view = FailurePresentation.from(StateError('bad state'));
      expect(view.code, isNull);
      expect(view.needsReauth, isFalse);
      expect(view.retryable, isFalse);
      expect(view.headline, '操作没有完成');
      expect(view.detail, contains('bad state'));
    });
  });

  group('the shelf\'s re-authenticate entry', () {
    // One testWidgets per state on purpose. Pumping a second SeriesGridScreen
    // into the same position reuses the first one's State, so `initState` never
    // runs again and the verdict under test would be the previous case\'s.
    Future<void> showShelf(WidgetTester tester, String? state) async {
      await tester.pumpWidget(MaterialApp(
        home: SeriesGridScreen(repository: _CredentialRepository(state)),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('is absent when the server was never contacted', (tester) async {
      await showShelf(tester, null);
      expect(find.byKey(const ValueKey('credential-banner')), findsNothing);
    });

    testWidgets('is absent for unknown, which is not the same as being wrong', (tester) async {
      await showShelf(tester, 'unknown');
      expect(find.byKey(const ValueKey('credential-banner')), findsNothing);
    });

    testWidgets('is absent for a working key', (tester) async {
      await showShelf(tester, 'valid');
      expect(find.byKey(const ValueKey('credential-banner')), findsNothing);
    });

    testWidgets('appears for a rejected credential, naming the fix', (tester) async {
      await showShelf(tester, 'expired');
      expect(find.byKey(const ValueKey('credential-banner')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('credential-headline'))).data,
        contains('API Key'),
      );
      // No ServerManager on this device means no way to edit a credential, so
      // the banner must not offer a button that goes nowhere.
      expect(find.byKey(const ValueKey('credential-reauth')), findsNothing);
    });

    testWidgets('a credential read that fails outright leaves the wall standing',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SeriesGridScreen(repository: _BrokenCredentialRepository()),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('credential-banner')), findsNothing);
      // The shelf itself is still there, not an error screen.
      expect(find.text('书架'), findsOneWidget);
    });
  });
}

class _CredentialRepository extends LibraryRepository {
  _CredentialRepository(this.state);

  final String? state;

  @override
  Future<AuthStateDto?> fetchCredentialState() async => state == null
      ? null
      : AuthStateDto(serverId: 's1', state: state!, at: '2026-08-31T12:04:00.000Z');

  @override
  Future<List<Series>> fetchSeries({int limit = 50, int offset = 0}) async => const [];

  @override
  Future<PagedSeries> querySeries({
    String? search,
    String? libraryId,
    String? status,
    String? tag,
    String? genre,
    String sort = 'name',
    bool ascending = true,
    int limit = 50,
    int offset = 0,
  }) async =>
      const PagedSeries(items: [], total: 0);

  @override
  Future<Map<String, String>> fetchCoverPaths() async => const {};

  @override
  Future<BootstrapSummary?> bootstrapActiveServer({bool resume = true}) async => null;

  @override
  Future<int> syncCovers() async => 0;

  @override
  bool get demoSupported => false;

  @override
  Future<BootstrapSummary> loadDemo() async => throw UnimplementedError();

  @override
  Stream<List<Series>> observeSeries() => Stream.value(const []);
}

/// A repository whose credential read fails outright — the shelf must survive it.
class _BrokenCredentialRepository extends _CredentialRepository {
  _BrokenCredentialRepository() : super('valid');

  @override
  Future<AuthStateDto?> fetchCredentialState() async {
    throw const SocketException('sqlite is busy');
  }
}
