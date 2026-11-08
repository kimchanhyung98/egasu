import Foundation
import XCTest

final class PricingSnapshotScriptTests: XCTestCase {
    func testRegenerationRetainsRetiredRatesAndUpdatesCurrentModels() throws {
        let source = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("script/update_pricing_snapshots.sh"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "<< 'PY'\n"))
        let end = try XCTUnwrap(source.range(of: "\nPY\n", range: start.upperBound..<source.endIndex))
        let script = String(source[start.upperBound..<end.lowerBound])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("egasu-pricing-snapshots-\(UUID().uuidString)")
        let resources = directory.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let previous = """
        {"retrieved_at":"2026-01-01T00:00:00Z","models":{
          "retired":{"i":15,"o":75,"cw":18.75,"cr":1.5,"ia":30},
          "active":{"i":99,"o":99,"cw":99,"cr":99}
        }}
        """
        for name in Self.snapshotNames {
            try previous.write(to: resources.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try """
        {"active":{"input_cost_per_token":0.000001,"output_cost_per_token":0.000002},
         "new":{"input_cost_per_token":0.000003,"output_cost_per_token":0.000004}}
        """.write(to: directory.appendingPathComponent("litellm.json"), atomically: true, encoding: .utf8)
        try """
        {"provider":{"models":{
          "active":{"cost":{"input":1,"output":2}},
          "new":{"cost":{"input":3,"output":4}}
        }}}
        """.write(to: directory.appendingPathComponent("models_dev.json"), atomically: true, encoding: .utf8)

        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script, directory.path, resources.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))

        for name in Self.snapshotNames {
            let data = try Data(contentsOf: resources.appendingPathComponent(name))
            let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let models = try XCTUnwrap(snapshot["models"] as? [String: [String: Double]])
            XCTAssertEqual(models["retired"], ["i": 15, "o": 75, "cw": 18.75, "cr": 1.5, "ia": 30])
            XCTAssertEqual(models["active"]?["i"], 1)
            XCTAssertEqual(models["active"]?["o"], 2)
            XCTAssertEqual(models["new"]?["i"], 3)
            XCTAssertEqual(models["new"]?["o"], 4)
            XCTAssertNotEqual(snapshot["retrieved_at"] as? String, "2026-01-01T00:00:00Z")
        }
    }

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let snapshotNames = ["pricing_litellm_snapshot.json", "pricing_models_dev_snapshot.json"]
}
