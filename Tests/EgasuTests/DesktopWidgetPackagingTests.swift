import Foundation
import XCTest

final class DesktopWidgetPackagingTests: XCTestCase {
    func testHostAndExtensionUseSeparateDevelopmentAndReleaseGroups() throws {
        for development in [true, false] {
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staging) }
            let host = staging.appendingPathComponent("egasu.app")
            let widget = staging.appendingPathComponent("EgasuWidgets.appex")
            let directory = "Contents/Info.plist"
            let bundleID = development ? "com.example.egasu.dev" : "com.example.egasu"
            let scheme = development ? "egasu-dev" : "egasu"
            for (bundle, id) in [(host, bundleID), (widget, bundleID + ".widgets")] {
                let file = bundle.appendingPathComponent(directory)
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try write(
                    ["CFBundleIdentifier": id, "CFBundleShortVersionString": "1.0", "CFBundleVersion": "42"], to: file)
            }

            let rights = staging.appendingPathComponent("host.entitlements")
            let signedRights = staging.appendingPathComponent("widget.entitlements")
            let cloud = ["iCloud." + bundleID]
            try write(["com.apple.developer.icloud-container-identifiers": cloud], to: rights)
            let signer = staging.appendingPathComponent("codesign")
            try """
            #!/bin/bash
            case "$1" in
              -dv) echo TeamIdentifier=TESTTEAM01 >&2 ;;
              --force) cp "$6" "$WIDGET_ENTITLEMENTS" ;;
              --verify) exit 0 ;;
              *) exit 1 ;;
            esac
            """.write(to: signer, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: signer.path)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            let process = Process()
            process.executableURL = root.appendingPathComponent("script/embed_widget_extension.sh")
            process.arguments = [
                host.path, widget.path, "Test Identity", rights.path, development ? "development" : "release"
            ]
            process.environment = [
                "PATH": staging.path + ":/usr/bin:/bin", "WIDGET_ENTITLEMENTS": signedRights.path
            ]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let group = "TESTTEAM01." + bundleID + ".widgets"
            let hostRights = try read(rights)
            let widgetRights = try read(signedRights)
            XCTAssertEqual(hostRights["com.apple.developer.icloud-container-identifiers"] as? [String], cloud)
            XCTAssertNil(hostRights["com.apple.security.app-sandbox"])
            XCTAssertEqual(hostRights["com.apple.security.application-groups"] as? [String], [group])
            XCTAssertEqual(widgetRights["com.apple.security.application-groups"] as? [String], [group])
            XCTAssertEqual(widgetRights["com.apple.security.app-sandbox"] as? Bool, true)
            XCTAssertNil(widgetRights["com.apple.developer.icloud-container-identifiers"])
            let hostInfo = try read(host.appendingPathComponent(directory))
            let widgetInfo = try read(host.appendingPathComponent("Contents/PlugIns/EgasuWidgets.appex/" + directory))
            for info in [hostInfo, widgetInfo] {
                XCTAssertEqual(info["EgasuWidgetAppGroup"] as? String, group)
                XCTAssertEqual(info["EgasuWidgetURLScheme"] as? String, scheme)
            }
            let types = hostInfo["CFBundleURLTypes"] as? [[String: Any]]
            XCTAssertEqual(types?.first?["CFBundleURLSchemes"] as? [String], [scheme])
        }
    }

    private func write(_ plist: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    private func read(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }
}
