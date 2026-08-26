import Foundation

/// API contract version policy — mirrors `specs/openapi/compatibility.md`
/// and the Rust side (`android/komga_core/src/api/contract.rs`).
///
/// The OpenAPI snapshot (specs/openapi/komga-openapi.yaml) is the single
/// source of truth. Bump `contractVersion` whenever the snapshot or the
/// policy changes — both clients must match exactly.
public enum KomgaContract {
    /// Client contract version — must equal Rust `ApiContract::CONTRACT_VERSION`.
    public static let contractVersion = "0.2.0"

    /// Snapshot pin (info.version of the OpenAPI file).
    public static let snapshotVersion = "1.26.3"

    /// Lowest server version this contract accepts.
    public static let minimumServerVersion = (major: 1, minor: 26)

    /// Outcome of checking a server's `build.version` against the policy.
    public enum VersionCheck: Equatable, Sendable {
        /// Within the snapshot line (1.26.x).
        case accepted
        /// Higher minor on the same major — accepted, capability recorded.
        case newerMinor(String)
        /// Version missing or unparseable — accepted, capability recorded.
        case unknownVersion
    }

    /// Policy decision for a server version (see compatibility.md table).
    public static func check(serverVersion: String?) throws -> VersionCheck {
        guard let serverVersion else { return .unknownVersion }
        guard let (major, minor, _) = parse(serverVersion) else { return .unknownVersion }

        // Komga's deprecation policy: endpoints marked deprecated are removed
        // in the next major, so a higher major is the hard compatibility
        // boundary.
        if major > minimumServerVersion.major {
            throw KomgaAPIError.apiCompatibility(
                "server version \(serverVersion) has a newer major than the contract (snapshot \(snapshotVersion))"
            )
        }
        if major < minimumServerVersion.major
            || (major == minimumServerVersion.major && minor < minimumServerVersion.minor) {
            throw KomgaAPIError.apiCompatibility(
                "server version \(serverVersion) is below the contract minimum (snapshot \(snapshotVersion))"
            )
        }
        if major == minimumServerVersion.major && minor > minimumServerVersion.minor {
            return .newerMinor(serverVersion)
        }
        return .accepted
    }

    /// Capabilities contributed by the version check (see compatibility.md).
    public static func capabilities(from check: VersionCheck) -> [String] {
        switch check {
        case .accepted:
            return []
        case .newerMinor(let version):
            return ["newer-than-snapshot:\(version)"]
        case .unknownVersion:
            return ["unknown-version"]
        }
    }

    /// Parse `major.minor.patch`-style versions; tolerates a leading `v`,
    /// extra numeric segments and suffixes ("1.26.3-SNAPSHOT").
    private static func parse(_ raw: String) -> (Int, Int, Int)? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") { trimmed.removeFirst() }
        let parts = trimmed
            .split(whereSeparator: { $0 == "." || $0 == "-" })
            .compactMap { Int($0) }
        guard let major = parts.first else { return nil }
        let minor = parts.count > 1 ? parts[1] : 0
        let patch = parts.count > 2 ? parts[2] : 0
        return (major, minor, patch)
    }
}