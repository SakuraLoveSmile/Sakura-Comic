import SwiftUI
import KomgaAPI
import KomgaDiagnostics

public enum AppErrorCategory: String, Sendable, Equatable {
    case network
    case auth
    case server
    case local
    case unknown

    public var systemImage: String {
        switch self {
        case .network: return "wifi.slash"
        case .auth: return "lock.trianglebadge.exclamationmark"
        case .server: return "server.rack"
        case .local: return "internaldrive"
        case .unknown: return "exclamationmark.circle"
        }
    }

    public var title: String {
        switch self {
        case .network: return "网络错误"
        case .auth: return "认证失效"
        case .server: return "服务器错误"
        case .local: return "存储错误"
        case .unknown: return "错误"
        }
    }
}

public enum AppErrorAction: Sendable, Equatable {
    case retry
    case reauth
    case checkConfig
    case cleanStorage
    case none

    public var buttonTitle: String? {
        switch self {
        case .retry: return "重试"
        case .reauth: return "重新登录"
        case .checkConfig: return "检查配置"
        case .cleanStorage: return "清理空间"
        case .none: return nil
        }
    }
}

public struct AppErrorPresentation: Sendable, Equatable {
    public let category: AppErrorCategory
    public let action: AppErrorAction
    public let headline: String
    public let detail: String
    public let canRetry: Bool
    public let needsReauth: Bool

    public static func from(_ error: Error) -> AppErrorPresentation {
        if let coreError = error as? CoreError {
            return from(coreError: coreError)
        }
        if let apiError = error as? KomgaAPIError {
            return from(coreError: apiError.coreError)
        }
        if let urlError = error as? URLError {
            return AppErrorPresentation(
                category: .network,
                action: .retry,
                headline: "网络连接失败，本地内容仍可浏览",
                detail: urlError.localizedDescription,
                canRetry: true,
                needsReauth: false
            )
        }

        // Generic error fallback
        let desc = error.localizedDescription
        let lower = desc.lowercased()
        if lower.contains("401") || lower.contains("403") || lower.contains("unauthorized") {
            return AppErrorPresentation(
                category: .auth,
                action: .reauth,
                headline: "登录已失效，需要重新输入凭据",
                detail: desc,
                canRetry: false,
                needsReauth: true
            )
        }
        if lower.contains("network") || lower.contains("connect") || lower.contains("timeout") {
            return AppErrorPresentation(
                category: .network,
                action: .retry,
                headline: "连不上服务器，本地内容仍可浏览",
                detail: desc,
                canRetry: true,
                needsReauth: false
            )
        }

        return AppErrorPresentation(
            category: .unknown,
            action: .retry,
            headline: "操作未能完成",
            detail: desc,
            canRetry: true,
            needsReauth: false
        )
    }

    public static func from(coreError: CoreError) -> AppErrorPresentation {
        let category: AppErrorCategory
        let action: AppErrorAction
        let headline: String

        switch coreError.code {
        case .authExpired:
            category = .auth
            action = .reauth
            headline = "登录已失效，需要重新输入 API Key 或密码"
        case .networkUnavailable:
            category = .network
            action = .retry
            headline = "连不上服务器，本地内容仍然可以浏览"
        case .notFound:
            category = .server
            action = .none
            headline = "服务器上已经没有这个内容了"
        case .conflict:
            category = .server
            action = .none
            headline = "服务器上的阅读进度和这里不一致，已按更晚的操作处理"
        case .rateLimited:
            category = .server
            action = .retry
            headline = "服务器暂时不接受更多请求，稍后会自动重试"
        case .serverError:
            category = .server
            action = .retry
            headline = "服务器返回了错误"
        case .contractUnsupported:
            category = .server
            action = .checkConfig
            headline = "这个 Komga 版本超出当前客户端的契约范围"
        case .invalidInput:
            category = .server
            action = .retry
            headline = "请求的内容不完整，请重试"
        case .decodeFailed:
            category = .server
            action = .checkConfig
            headline = "服务器返回的数据不符合接口约定"
        case .databaseFailure:
            category = .local
            action = .none
            headline = "本地数据库写入失败"
        case .databaseBusy:
            category = .local
            action = .retry
            headline = "本地数据库正被占用，稍后自动重试"
        case .storageFailure:
            category = .local
            action = .cleanStorage
            headline = "设备存储空间不足或写入被拒绝"
        case .idle:
            category = .unknown
            action = .none
            headline = "这次没有新事件"
        case .unknown:
            category = .unknown
            action = .retry
            headline = "操作没有完成"
        }

        return AppErrorPresentation(
            category: category,
            action: action,
            headline: headline,
            detail: coreError.message,
            canRetry: coreError.retryable,
            needsReauth: coreError.needsUser
        )
    }
}

public struct ErrorBannerView: View {
    public let presentation: AppErrorPresentation
    public var onRetry: (() -> Void)?
    public var onReauth: (() -> Void)?
    public var onDismiss: (() -> Void)?

    @State private var showDetail = false

    public init(
        error: Error,
        onRetry: (() -> Void)? = nil,
        onReauth: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.presentation = AppErrorPresentation.from(error)
        self.onRetry = onRetry
        self.onReauth = onReauth
        self.onDismiss = onDismiss
    }

    public init(
        presentation: AppErrorPresentation,
        onRetry: (() -> Void)? = nil,
        onReauth: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.presentation = presentation
        self.onRetry = onRetry
        self.onReauth = onReauth
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: presentation.category.systemImage)
                    .foregroundStyle(bannerColor)
                    .font(.subheadline)

                Text(presentation.headline)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                Spacer()

                if let actionTitle = presentation.action.buttonTitle {
                    Button(actionTitle) {
                        switch presentation.action {
                        case .retry: onRetry?()
                        case .reauth: onReauth?()
                        default: onRetry?()
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .tint(bannerColor)
                    .controlSize(.small)
                }

                if let onDismiss {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !presentation.detail.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showDetail.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(showDetail ? "收起详情" : "查看技术详情")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Image(systemName: showDetail ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if showDetail {
                    Text(presentation.detail)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(10)
        .background(bannerColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(bannerColor.opacity(0.25), lineWidth: 1)
        )
    }

    private var bannerColor: Color {
        switch presentation.category {
        case .auth: return .orange
        case .network: return .blue
        case .server: return .red
        case .local: return .purple
        case .unknown: return .red
        }
    }
}
