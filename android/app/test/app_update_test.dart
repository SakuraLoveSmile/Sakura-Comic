import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:comic_app/src/app_update.dart';

/// The updater's decision, without a socket: release flags, tag ordering and
/// "is it newer" are where a check quietly lies to the person holding the
/// phone, so each of them is pinned here instead of in a device test.
void main() {
  Map<String, Object?> release({
    required String tag,
    bool prerelease = false,
    bool draft = false,
    List<String> assets = const [],
    String body = '',
  }) =>
      {
        'tag_name': tag,
        'name': tag,
        'prerelease': prerelease,
        'draft': draft,
        'html_url': 'https://github.com/SakuraLoveSmile/Sakura-Comic/releases/tag/$tag',
        'published_at': '2026-11-26T10:00:00Z',
        'body': body,
        'assets': [
          for (final name in assets)
            {
              'name': name,
              'browser_download_url':
                  'https://github.com/SakuraLoveSmile/Sakura-Comic/releases/download/$tag/$name',
            },
        ],
      };

  group('parseReleases', () {
    test('keeps published releases and drops drafts', () {
      final body = jsonEncode([
        release(tag: 'v0.3.0'),
        release(tag: 'v0.4.0', draft: true),
        release(tag: 'v0.3.1-preview.1', prerelease: true),
      ]);

      final parsed = parseReleases(body);
      expect(parsed.map((r) => r.tag), ['v0.3.0', 'v0.3.1-preview.1']);
      expect(parsed.last.prerelease, isTrue);
      expect(parsed.first.version, '0.3.0');
    });

    test('hands back the arm64 APK when the release carries every ABI', () {
      final parsed = parseReleases(jsonEncode([
        release(tag: 'v0.3.0', assets: [
          'app-x86_64-release.apk',
          'app-armeabi-v7a-release.apk',
          'app-arm64-v8a-release.apk',
          'app-release.aab',
        ]),
      ]));

      expect(parsed.single.apkUrl.toString(), endsWith('app-arm64-v8a-release.apk'));
      expect(parsed.single.downloadUrl, parsed.single.apkUrl);
    });

    test('a release with no APK still offers its page', () {
      final parsed = parseReleases(jsonEncode([release(tag: 'v0.3.0')]));
      expect(parsed.single.apkUrl, isNull);
      expect(parsed.single.downloadUrl.toString(), contains('/releases/tag/v0.3.0'));
    });

    test('a payload that is not a list is an error, not an empty result', () {
      expect(() => parseReleases('{"message":"Not Found"}'),
          throwsFormatException);
    });
  });

  group('compareVersions', () {
    test('orders by the numbers first', () {
      expect(compareVersions('0.3.0', '0.2.0'), greaterThan(0));
      expect(compareVersions('v0.2.0', '0.3.0'), lessThan(0));
      expect(compareVersions('0.3.0', '0.3.0'), 0);
      expect(compareVersions('0.10.0', '0.9.9'), greaterThan(0));
    });

    test('a release beats its own pre-releases', () {
      expect(compareVersions('0.3.0', '0.3.0-preview.1'), greaterThan(0));
      expect(compareVersions('0.3.0-preview.1', '0.3.0'), lessThan(0));
      expect(compareVersions('0.3.0-preview.2', '0.3.0-preview.10'), lessThan(0),
          reason: 'preview.2 is two previews before preview.10, not ten');
    });

    test('a build number is not a version', () {
      expect(compareVersions('0.3.0+4', '0.3.0'), 0);
      expect(compareVersions('0.3.0+4', '0.3.1'), lessThan(0));
    });
  });

  group('pickUpdate', () {
    final releases = [
      AppRelease(
          tag: 'v0.3.0',
          name: 'v0.3.0',
          prerelease: false,
          notes: '',
          pageUrl: Uri.parse('https://example.test/v0.3.0')),
      AppRelease(
          tag: 'v0.3.1-preview.2',
          name: 'v0.3.1-preview.2',
          prerelease: true,
          notes: '',
          pageUrl: Uri.parse('https://example.test/v0.3.1-preview.2')),
      AppRelease(
          tag: 'v0.2.0',
          name: 'v0.2.0',
          prerelease: false,
          notes: '',
          pageUrl: Uri.parse('https://example.test/v0.2.0')),
    ];

    test('the stable channel never answers with a preview', () {
      final picked = pickUpdate(
          releases: releases,
          channel: UpdateChannel.release,
          currentVersion: '0.2.0');
      expect(picked?.tag, 'v0.3.0');
    });

    test('the preview channel takes the newest, preview or not', () {
      final picked = pickUpdate(
          releases: releases,
          channel: UpdateChannel.preview,
          currentVersion: '0.2.0');
      expect(picked?.tag, 'v0.3.1-preview.2');
    });

    test('a preview build is still offered the newer stable release', () {
      final picked = pickUpdate(
          releases: releases,
          channel: UpdateChannel.preview,
          currentVersion: '0.3.1-preview.2');
      expect(picked, isNull,
          reason: 'preview.2 predates 0.3.1 stable, but this list has no 0.3.1');

      final withStable = [
        ...releases,
        AppRelease(
            tag: 'v0.3.1',
            name: 'v0.3.1',
            prerelease: false,
            notes: '',
            pageUrl: Uri.parse('https://example.test/v0.3.1')),
      ];
      final updated = pickUpdate(
          releases: withStable,
          channel: UpdateChannel.preview,
          currentVersion: '0.3.1-preview.2');
      expect(updated?.tag, 'v0.3.1');
    });

    test('being current is not an update, even on the same version', () {
      expect(
          pickUpdate(
              releases: releases,
              channel: UpdateChannel.release,
              currentVersion: '0.3.0'),
          isNull);
      expect(
          pickUpdate(
              releases: releases,
              channel: UpdateChannel.release,
              currentVersion: '1.0.0'),
          isNull);
    });
  });

  group('UpdateChecker', () {
    test('asks the project releases endpoint and answers what it found', () async {
      Uri? asked;
      final checker = UpdateChecker(fetch: (uri) async {
        asked = uri;
        return jsonEncode([
          release(tag: 'v0.3.0', assets: ['app-arm64-v8a-release.apk']),
        ]);
      });

      final result = await checker.check(
          channel: UpdateChannel.release, currentVersion: '0.2.0+3');

      expect(asked.toString(),
          'https://api.github.com/repos/SakuraLoveSmile/Sakura-Comic/releases?per_page=30');
      expect(result.upToDate, isFalse);
      expect(result.available?.tag, 'v0.3.0');
      expect(result.currentVersion, '0.2.0+3');
    });

    test('the same version on the shelf is up to date', () async {
      final checker = UpdateChecker(
          fetch: (_) async => jsonEncode([release(tag: 'v0.2.0')]));
      final result = await checker.check(
          channel: UpdateChannel.release, currentVersion: '0.2.0+3');
      expect(result.upToDate, isTrue);
    });

    test('a failed request surfaces as an error, not as up to date', () async {
      final checker = UpdateChecker(
          fetch: (_) async => throw const FormatException('offline'));
      await expectLater(
          checker.check(
              channel: UpdateChannel.release, currentVersion: '0.2.0'),
          throwsFormatException);
    });
  });
}
