import XCTest
@testable import KomgaStore
@testable import KomgaSync

/// Stage 5 acceptance battery: both platforms replay the SAME scenario JSON
/// from `specs/contracts/fixtures/sync`, so "SQLite 与 Komga 一致" is one
/// shared contract rather than two hand-written suites that could drift.
final class SyncScenarioTests: XCTestCase {
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../specs/contracts/fixtures/sync")
            .standardizedFileURL
    }

    func testReconcileConvergesWithSSEDisabled() async throws {
        try await runShipped("scenario-reconcile.json")
    }

    func testInterruptResumesAndOfflineRecovers() async throws {
        try await runShipped("scenario-interrupt.json")
    }

    /// Run a shipped scenario and report every failing step with its detail.
    private func runShipped(_ name: String) async throws {
        let url = fixtureURL.appendingPathComponent(name)
        let scenario = try SyncScenario.load(from: url)
        XCTAssertEqual(
            scenario.sse, "disabled",
            "\(name) must run with SSE unavailable — that is the Stage 5 criterion"
        )
        XCTAssertFalse(scenario.snapshots.isEmpty)

        let store = try KomgaStore()
        let reports = await SyncScenario.run(store: store, scenario: scenario)
        XCTAssertEqual(reports.count, scenario.steps.count)

        for report in reports {
            print("[\(report.ok ? "ok" : "FAIL")] \(report.label)")
            for line in report.detail {
                print("      - \(line)")
            }
        }
        let failures = reports.filter { !$0.ok }
            .map { "\($0.label): \($0.detail.joined(separator: "; "))" }
        XCTAssertTrue(failures.isEmpty, "\(name) failed: \(failures)")
    }
}
