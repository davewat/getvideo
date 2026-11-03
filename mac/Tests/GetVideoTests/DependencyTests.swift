import XCTest

/// The package has no third-party dependencies, which is why there is nothing for a vulnerability
/// scanner to find. If one is added, the scanner needs Package.resolved to see its exact version.
final class DependencyTests: XCTestCase {
    func testDependenciesAreEitherAbsentOrPinned() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let hasDependencies = manifest.contains(".package(")
        let pinned = FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.resolved").path)
        XCTAssertTrue(!hasDependencies || pinned,
                      "Package.swift lists a dependency but Package.resolved is not committed, so the vulnerability scan cannot see which version is used. Commit Package.resolved.")
    }
}
