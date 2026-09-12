import 'rust/ffi/error.dart';

/// How the UI answers a core failure: one sentence the user can act on, and
/// whether to offer the single action that can fix it.
///
/// This exists because the core now says *what kind* of failure happened
/// ([CoreError.code]) instead of only how it read in English. A shelf that
/// printed `authentication failed` for a lost tunnel and for a revoked key
/// looked identical while the two need opposite responses — one waits it out,
/// the other has to type something.
///
/// The wording is per-code, not per-message: the message is the core's own
/// diagnostic text and is free to change, so it goes in the details line and
/// never in the headline.
class FailurePresentation {
  const FailurePresentation({
    required this.code,
    required this.headline,
    required this.detail,
    required this.retryable,
    required this.needsReauth,
  });

  /// The code this was built from, or `null` when the failure was not a
  /// [CoreError] at all (a Dart-side bug, a platform-channel error).
  final ErrorCode? code;

  /// One line for the banner.
  final String headline;

  /// The core's own text, for the expandable detail.
  final String detail;

  /// True when waiting is the right move and the UI should not raise a prompt.
  final bool retryable;

  /// True only for a rejected credential: the one failure that cannot resolve
  /// without the user.
  final bool needsReauth;

  /// An unknown failure says nothing, so it must not claim more than "it did
  /// not work" — and must not send the user to re-enter a key that may be fine.
  factory FailurePresentation.unknown([Object? error]) {
    return FailurePresentation(
      code: null,
      headline: '操作没有完成',
      detail: error?.toString() ?? '',
      retryable: false,
      needsReauth: false,
    );
  }

  /// Map anything thrown across the bridge. A [CoreError] keeps its code and
  /// policy bits; everything else is treated as unknown rather than guessed at
  /// from its text.
  factory FailurePresentation.from(Object error) {
    if (error is! CoreError) return FailurePresentation.unknown(error);
    return FailurePresentation(
      code: error.code,
      headline: _headlineFor(error.code),
      detail: error.message,
      // The policy comes from the code list the three platforms share
      // (`specs/contracts/fixtures/errors/codes.json`), which the core already
      // applied when it built `retryable`. Re-deriving a headline-only `true`
      // here would let the UI retry something the core stopped on.
      retryable: error.retryable,
      needsReauth: error.needsUser,
    );
  }

  static String _headlineFor(ErrorCode code) {
    switch (code) {
      case ErrorCode.authExpired:
        return '登录已失效，需要重新输入 API Key';
      case ErrorCode.networkUnavailable:
        return '连不上服务器，本地内容仍然可以浏览';
      case ErrorCode.notFound:
        return '服务器上已经没有这个内容了';
      case ErrorCode.conflict:
        return '服务器上的阅读进度和这里不一致，已按更晚的操作处理';
      case ErrorCode.rateLimited:
        return '服务器暂时不接受更多请求，稍后会自动重试';
      case ErrorCode.serverError:
        return '服务器返回了错误';
      case ErrorCode.contractUnsupported:
        return '这个 Komga 版本超出当前客户端的契约范围';
      case ErrorCode.invalidInput:
        return '请求的内容不完整，请重试';
      case ErrorCode.decodeFailed:
        return '服务器返回的数据不符合接口约定';
      case ErrorCode.databaseFailure:
        return '本地数据库写入失败';
      case ErrorCode.databaseBusy:
        return '本地数据库正被占用，稍后自动重试';
      case ErrorCode.storageFailure:
        return '设备存储空间不足或写入被拒绝';
      case ErrorCode.idle:
        return '这次没有新事件';
      case ErrorCode.unknown:
        return '操作没有完成';
    }
  }
}

/// The banner sentence for one code. Top-level so a status line can name the
/// failure without inventing an exception object just to render it; it still
/// goes through the exhaustive switch above, which is what makes a code added
/// on the Rust side a compile error here rather than a silent fallback.
String failureHeadline(ErrorCode code) =>
    FailurePresentation._headlineFor(code);

/// The credential verdict for one server, as the shelf reads it.
enum CredentialStatus {
  /// Never contacted, or a note this build cannot parse. Not a problem.
  unknown,
  valid,
  expired,
}

CredentialStatus credentialStatusOf(String? state) {
  switch (state) {
    case 'valid':
      return CredentialStatus.valid;
    case 'expired':
      return CredentialStatus.expired;
    default:
      return CredentialStatus.unknown;
  }
}
