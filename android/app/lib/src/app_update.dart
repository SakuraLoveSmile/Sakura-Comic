import 'dart:convert';
import 'dart:io';

/// Where this app is published: the same repository the release workflow
/// tags and the README points at.
const String kUpdateRepo = 'SakuraLoveSmile/Sakura-Comic';

/// Which releases a person is willing to run.
///
/// The two channels are not two apps: a preview is the same APK a stable
/// release is, published from a tag GitHub marks as a pre-release. Choosing
/// [preview] therefore only widens what a check is allowed to answer with —
/// a newer stable still wins, because the pick is by version.
enum UpdateChannel {
  /// Only releases GitHub does not mark as a pre-release.
  release,

  /// Pre-releases too.
  preview;

  static UpdateChannel fromStorage(String? raw) =>
      raw == preview.name ? preview : release;
}

/// One release, as much of it as this app has a use for.
class AppRelease {
  const AppRelease({
    required this.tag,
    required this.name,
    required this.prerelease,
    required this.notes,
    this.pageUrl,
    this.apkUrl,
    this.publishedAt,
  });

  /// `v0.3.0` or `v0.3.0-preview.1`.
  final String tag;

  final String name;
  final bool prerelease;

  /// The release body, shown as-is: whoever wrote the tag wrote it for this.
  final String notes;

  final Uri? pageUrl;

  /// The APK a phone can actually install, when the release carries one.
  final Uri? apkUrl;

  final DateTime? publishedAt;

  /// The tag without its `v`, which is what a version comparison wants.
  String get version => tag.startsWith('v') ? tag.substring(1) : tag;

  /// What 「去下载」 should open: the APK when there is one, the release page
  /// otherwise. A release with neither is a check the UI must not offer.
  Uri? get downloadUrl => apkUrl ?? pageUrl;
}

/// One check's answer: the newest release this build may run, or nothing.
class UpdateCheck {
  const UpdateCheck({required this.currentVersion, this.available});

  final String currentVersion;

  /// `null` when this build is already the newest one the channel allows.
  final AppRelease? available;

  bool get upToDate => available == null;
}

/// Reads GitHub's release list and answers "is there anything newer".
///
/// The fetch is injected so the decision can be tested without a socket, and
/// so a caller that already has an HTTP client does not grow a second one.
class UpdateChecker {
  const UpdateChecker({this.fetch = githubReleases, this.repo = kUpdateRepo});

  final Future<String> Function(Uri uri) fetch;
  final String repo;

  /// `per_page=30` — a year of releases for this project, and one request.
  Uri get releasesUri =>
      Uri.parse('https://api.github.com/repos/$repo/releases?per_page=30');

  Future<UpdateCheck> check({
    required UpdateChannel channel,
    required String currentVersion,
  }) async {
    final body = await fetch(releasesUri);
    final releases = parseReleases(body);
    return UpdateCheck(
      currentVersion: currentVersion,
      available: pickUpdate(
        releases: releases,
        channel: channel,
        currentVersion: currentVersion,
      ),
    );
  }
}

/// The default transport: one GET, no cache, no token (the repository is public).
Future<String> githubReleases(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    // GitHub answers 403 to a request with no User-Agent at all.
    request.headers.set(HttpHeaders.userAgentHeader, 'Comic-Android');
    request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('releases request failed: ${response.statusCode}', uri: uri);
    }
    return body;
  } finally {
    client.close(force: true);
  }
}

/// Parse the releases payload. Drafts are dropped: a draft is a release nobody
/// has published, and it must never look like an update to the person holding
/// the phone.
List<AppRelease> parseReleases(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! List) {
    throw const FormatException('releases payload was not a list');
  }
  final releases = <AppRelease>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    if (item['draft'] == true) continue;
    final tag = item['tag_name'];
    if (tag is! String || tag.trim().isEmpty) continue;
    final name = item['name'];
    final html = item['html_url'];
    final body = item['body'];
    final published = item['published_at'];
    releases.add(AppRelease(
      tag: tag.trim(),
      name: name is String && name.trim().isNotEmpty ? name.trim() : tag.trim(),
      prerelease: item['prerelease'] == true,
      notes: body is String ? body : '',
      pageUrl: html is String ? Uri.tryParse(html) : null,
      apkUrl: _pickApk(item['assets']),
      publishedAt: published is String ? DateTime.tryParse(published) : null,
    ));
  }
  return releases;
}

/// Which APK this build hands a phone, most specific first. The release
/// workflow publishes one per ABI; a device that installs the wrong one either
/// cannot run it or emulates it.
Uri? _pickApk(Object? assets) {
  if (assets is! List) return null;
  final byName = <String, Uri>{};
  for (final asset in assets) {
    if (asset is! Map) continue;
    final name = asset['name'];
    final url = asset['browser_download_url'];
    if (name is! String || url is! String) continue;
    final parsed = Uri.tryParse(url);
    if (parsed != null) byName[name] = parsed;
  }
  for (final name in const [
    'app-arm64-v8a-release.apk',
    'app-armeabi-v7a-release.apk',
    'app-x86_64-release.apk',
    'app-release.apk',
  ]) {
    final url = byName[name];
    if (url != null) return url;
  }
  return null;
}

/// The newest release on [channel] that is strictly newer than
/// [currentVersion], or `null` when this build is already the newest.
///
/// The whole point of keeping this a pure function: `prerelease` flags, tag
/// ordering and "is it newer" are the parts that silently get a release
/// wrong, and they are exactly the parts a socket would hide.
AppRelease? pickUpdate({
  required List<AppRelease> releases,
  required UpdateChannel channel,
  required String currentVersion,
}) {
  AppRelease? best;
  for (final release in releases) {
    if (channel == UpdateChannel.release && release.prerelease) continue;
    if (compareVersions(release.version, currentVersion) <= 0) continue;
    if (best == null || compareVersions(release.version, best.version) > 0) {
      best = release;
    }
  }
  return best;
}

/// Compare two version strings: `0.3.0` vs `v0.3.0-preview.1` vs `0.2.0+3`.
///
/// Rules, in the order they matter: the dot-separated numbers decide first; a
/// build suffix (`+3`) is not part of the version for this comparison, because
/// every release carries a different one and "+4 is newer than +3" is already
/// said by the tag; a release (`0.3.0`) beats its own pre-releases
/// (`0.3.0-preview.1`), which is what makes a preview channel settle onto the
/// stable build once it ships.
int compareVersions(String a, String b) {
  final left = _Version.parse(a);
  final right = _Version.parse(b);
  for (var index = 0; index < 3; index++) {
    final diff = left.core[index] - right.core[index];
    if (diff != 0) return diff.sign;
  }
  final leftPre = left.pre;
  final rightPre = right.pre;
  if (leftPre == null && rightPre == null) return 0;
  if (leftPre == null) return 1;
  if (rightPre == null) return -1;
  return _comparePre(leftPre, rightPre);
}

int _comparePre(String a, String b) {
  final left = a.split('.');
  final right = b.split('.');
  for (var index = 0; index < left.length || index < right.length; index++) {
    final l = index < left.length ? left[index] : '';
    final r = index < right.length ? right[index] : '';
    if (l == r) continue;
    final ln = int.tryParse(l);
    final rn = int.tryParse(r);
    if (ln != null && rn != null) return ln.compareTo(rn);
    // A missing segment sorts before a present one: preview.1 < preview.1.a
    if (l.isEmpty) return -1;
    if (r.isEmpty) return 1;
    return l.compareTo(r);
  }
  return 0;
}

class _Version {
  _Version(this.core, this.pre);

  final List<int> core;
  final String? pre;

  static _Version parse(String raw) {
    var text = raw.trim();
    if (text.startsWith('v') || text.startsWith('V')) text = text.substring(1);
    // A build number (`+3`) orders builds of the same version, not versions.
    final plus = text.indexOf('+');
    if (plus >= 0) text = text.substring(0, plus);
    final dash = text.indexOf('-');
    final coreText = dash >= 0 ? text.substring(0, dash) : text;
    final pre = dash >= 0 ? text.substring(dash + 1) : null;
    final parts = coreText.split('.');
    final core = <int>[0, 0, 0];
    for (var index = 0; index < 3 && index < parts.length; index++) {
      core[index] = int.tryParse(parts[index]) ?? 0;
    }
    return _Version(core, (pre == null || pre.isEmpty) ? null : pre);
  }
}
