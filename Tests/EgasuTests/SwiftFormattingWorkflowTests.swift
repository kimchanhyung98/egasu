import Foundation
import XCTest

final class SwiftFormattingWorkflowTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testBetaWorkflowOnlyRunsManually() throws {
        let workflow = try String(contentsOf: Self.workflowURL, encoding: .utf8)
        let triggers = try XCTUnwrap(
            workflow.components(separatedBy: "\non:\n").last?
                .components(separatedBy: "\npermissions:").first)
        let activeLines = triggers.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
        XCTAssertEqual(activeLines, ["workflow_dispatch:"])
        XCTAssertTrue(triggers.contains("# push:"))
        XCTAssertTrue(triggers.contains("#   branches: [main]"))
        XCTAssertTrue(workflow.contains("github.ref == 'refs/heads/main'"))
        let validation = try XCTUnwrap(workflow.range(of: "run: make check"))
        let commit = try XCTUnwrap(workflow.range(of: "- name: Commit formatting"))
        XCTAssertLessThan(validation.lowerBound, commit.lowerBound)
    }

    func testFormattingIsScopedAndIdempotent() throws {
        let repository = try makeFixture()
        let source = repository.appendingPathComponent("Sources/Nested/Example.swift")
        let excluded = repository.appendingPathComponent(".build/Dependency.swift")
        let original = "fileprivate struct Example {\nlet value=1000000\n}\n"
        try original.write(to: source, atomically: true, encoding: .utf8)
        try original.write(to: excluded, atomically: true, encoding: .utf8)

        XCTAssertNotEqual(try run(["make", "format-check"], in: repository).status, 0)
        try succeed(["make", "format"], in: repository)
        try succeed(["make", "format-check"], in: repository)

        let formatted = try String(contentsOf: source, encoding: .utf8)
        XCTAssertTrue(formatted.contains("    let value = 1000000\n"), formatted)
        XCTAssertTrue(formatted.contains("fileprivate struct Example"), formatted)
        XCTAssertEqual(try String(contentsOf: excluded, encoding: .utf8), original)
        let package = try Data(contentsOf: repository.appendingPathComponent("Package.swift"))
        let test = try Data(contentsOf: repository.appendingPathComponent("Tests/ExampleTests.swift"))
        try succeed(["make", "format"], in: repository)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), formatted)
        XCTAssertEqual(try Data(contentsOf: repository.appendingPathComponent("Package.swift")), package)
        XCTAssertEqual(try Data(contentsOf: repository.appendingPathComponent("Tests/ExampleTests.swift")), test)
    }

    func testCommitIncludesOnlySwiftFilesAndSkipsUnchangedSources() throws {
        let repository = try makeFixture()
        try initializeRemote(for: repository)
        try succeed(["make", "format"], in: repository)
        try "unrelated change\n".write(
            to: repository.appendingPathComponent("README.md"), atomically: true, encoding: .utf8
        )
        try "unrelated lockfile\n".write(
            to: repository.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8
        )

        let result = try runCommitStep(in: repository)
        XCTAssertEqual(result.status, 0, result.output)
        let files = try succeed(["git", "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"], in: repository)
        XCTAssertEqual(
            Set(files.split(separator: "\n").map(String.init)),
            [
                "Package.swift", "Sources/Nested/Example.swift", "Tests/ExampleTests.swift"
            ])
        let head = try succeed(["git", "rev-parse", "HEAD"], in: repository)
        XCTAssertEqual(try succeed(["git", "rev-parse", "origin/main"], in: repository), head)
        XCTAssertEqual(try runCommitStep(in: repository).status, 0)
        XCTAssertEqual(try succeed(["git", "rev-parse", "HEAD"], in: repository), head)
        XCTAssertTrue(try succeed(["git", "status", "--short"], in: repository).contains("README.md"))
    }

    func testPushRejectsAnAdvancedMainWithoutOverwritingIt() throws {
        let repository = try makeFixture()
        try initializeRemote(for: repository)
        let remote = repository.deletingLastPathComponent().appendingPathComponent("remote.git")
        let competing = repository.deletingLastPathComponent().appendingPathComponent("competing")
        try succeed(["git", "clone", remote.path, competing.path], in: repository)
        try succeed(["git", "config", "user.name", "Fixture"], in: competing)
        try succeed(["git", "config", "user.email", "fixture@example.invalid"], in: competing)
        try "new main change\n".write(
            to: competing.appendingPathComponent("README.md"), atomically: true, encoding: .utf8
        )
        try succeed(["git", "add", "README.md"], in: competing)
        try succeed(["git", "commit", "-m", "advance main"], in: competing)
        try succeed(["git", "push", "origin", "main"], in: competing)
        let expected = try succeed(["git", "rev-parse", "HEAD"], in: competing)
        try succeed(["make", "format"], in: repository)

        let result = try runCommitStep(in: repository)
        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("[rejected]"), result.output)
        XCTAssertTrue(
            result.output.contains("fetch first") || result.output.contains("non-fast-forward"), result.output
        )
        XCTAssertEqual(try succeed(["git", "--git-dir", remote.path, "rev-parse", "main"], in: repository), expected)
    }

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("egasu-format-\(UUID().uuidString)")
        temporaryDirectories.append(root)
        let repository = root.appendingPathComponent("checkout")
        for path in ["Sources/Nested", "Tests", ".build"] {
            try FileManager.default.createDirectory(
                at: repository.appendingPathComponent(path), withIntermediateDirectories: true
            )
        }
        for path in ["Makefile", ".swift-format"] {
            try FileManager.default.copyItem(
                at: Self.repositoryRoot.appendingPathComponent(path), to: repository.appendingPathComponent(path)
            )
        }
        for path in ["Package.swift", "Sources/Nested/Example.swift", "Tests/ExampleTests.swift"] {
            try "struct Example {\nlet value=1\n}\n".write(
                to: repository.appendingPathComponent(path), atomically: true, encoding: .utf8
            )
        }
        for path in ["README.md", "Package.resolved"] {
            try "original\n".write(to: repository.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        return repository
    }

    private func initializeRemote(for repository: URL) throws {
        let remote = repository.deletingLastPathComponent().appendingPathComponent("remote.git")
        try succeed(["git", "init", "--bare", "--initial-branch=main", remote.path], in: repository)
        try succeed(["git", "init", "--initial-branch=main"], in: repository)
        try succeed(["git", "config", "user.name", "Fixture"], in: repository)
        try succeed(["git", "config", "user.email", "fixture@example.invalid"], in: repository)
        try succeed(["git", "add", "."], in: repository)
        try succeed(["git", "commit", "-m", "initial"], in: repository)
        try succeed(["git", "remote", "add", "origin", remote.path], in: repository)
        try succeed(["git", "push", "-u", "origin", "main"], in: repository)
    }

    private func runCommitStep(in repository: URL) throws -> (status: Int32, output: String) {
        let workflow = try String(contentsOf: Self.workflowURL, encoding: .utf8)
        let start = try XCTUnwrap(workflow.range(of: "      - name: Commit formatting\n        run: |\n"))
        let script = workflow[start.upperBound...].split(separator: "\n")
            .prefix { $0.hasPrefix("          ") }
            .map { String($0.dropFirst(10)) }.joined(separator: "\n")
        return try run(["bash", "-e", "-o", "pipefail", "-c", script], in: repository)
    }

    @discardableResult
    private func succeed(_ arguments: [String], in directory: URL) throws -> String {
        let result = try run(arguments, in: directory)
        XCTAssertEqual(result.status, 0, result.output)
        guard result.status == 0 else {
            throw NSError(domain: "SwiftFormattingWorkflowTests", code: Int(result.status))
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(_ arguments: [String], in directory: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
        for key in ["DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS"] {
            environment[key] = ProcessInfo.processInfo.environment[key]
        }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let workflowURL = repositoryRoot.appendingPathComponent(".github/workflows/format-swift.yml")
}
