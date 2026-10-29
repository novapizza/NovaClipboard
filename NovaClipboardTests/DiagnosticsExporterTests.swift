import XCTest
import os
@testable import NovaClipboard

final class DiagnosticsExporterTests: XCTestCase {
    func testReportIncludesSectionsAndOwnLogLines() {
        let marker = "diagnostics-test-\(UUID().uuidString)"
        Logger(subsystem: DiagnosticsExporter.subsystem, category: "Test").info("\(marker, privacy: .public)")
        Logger(subsystem: DiagnosticsExporter.subsystem, category: "Test").error("\(marker, privacy: .public)-error")

        let report = DiagnosticsExporter.report(.init(store: "store-line", monitor: "monitor-line", screenshots: "shots-line"))

        XCTAssertTrue(report.contains("store-line"))
        XCTAssertTrue(report.contains("monitor-line"))
        XCTAssertTrue(report.contains("shots-line"))
        XCTAssertTrue(report.contains(HistoryStoreLocation.url.path))
        XCTAssertTrue(report.contains("\(marker)-error"), "error-level lines must reach the report")
        XCTAssertTrue(report.contains("info: \(marker)"), "info-level lines must reach the report")
    }
}
