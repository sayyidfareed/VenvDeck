import XCTest
@testable import VenvDeckCore

final class EnvironmentCoreTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VenvDeckTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testClassifiesPyvenvAsVenvWithMissingInterpreter() throws {
        let env = tempRoot.appendingPathComponent(".venv", isDirectory: true)
        try FileManager.default.createDirectory(at: env, withIntermediateDirectories: true)
        try "home = /usr/bin\ninclude-system-site-packages = false\n".write(
            to: env.appendingPathComponent("pyvenv.cfg"),
            atomically: true,
            encoding: .utf8
        )

        let candidate = try XCTUnwrap(EnvironmentClassifier.classify(url: env))
        XCTAssertEqual(candidate.kind, .venv)
        XCTAssertEqual(candidate.health, .missingInterpreter)
    }

    func testRecoversPythonVersionFromPyvenvConfig() throws {
        let env = tempRoot.appendingPathComponent(".venv312", isDirectory: true)
        try FileManager.default.createDirectory(at: env, withIntermediateDirectories: true)
        try """
        home = /usr/bin
        version_info = 3.12.8.final.0
        include-system-site-packages = false
        """.write(to: env.appendingPathComponent("pyvenv.cfg"), atomically: true, encoding: .utf8)

        let candidate = try XCTUnwrap(EnvironmentClassifier.classify(url: env))
        let record = EnvironmentInspector().inspect(candidate: candidate, includePackageCount: false)
        XCTAssertEqual(record.pythonVersion, "3.12.8")
    }

    func testFindsVersionedPythonInterpreter() throws {
        let env = tempRoot.appendingPathComponent(".versioned", isDirectory: true)
        let bin = env.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "home = /usr/bin\n".write(to: env.appendingPathComponent("pyvenv.cfg"), atomically: true, encoding: .utf8)
        let python = bin.appendingPathComponent("python3.12")
        try "#!/bin/sh\necho Python 3.12.7\n".write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

        let candidate = try XCTUnwrap(EnvironmentClassifier.classify(url: env))
        XCTAssertEqual(candidate.interpreterPath?.lastPathComponent, "python3.12")
        let record = EnvironmentInspector().inspect(candidate: candidate, includePackageCount: false)
        XCTAssertEqual(record.health, .healthy)
        XCTAssertEqual(record.pythonVersion, "3.12.7")
    }

    func testRecoversInterpreterThroughActivationScript() throws {
        let env = tempRoot.appendingPathComponent(".activated", isDirectory: true)
        let bin = env.appendingPathComponent("bin", isDirectory: true)
        let hiddenBin = env.appendingPathComponent("hidden-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hiddenBin, withIntermediateDirectories: true)
        try "home = /usr/bin\n".write(to: env.appendingPathComponent("pyvenv.cfg"), atomically: true, encoding: .utf8)
        try "export PATH=\"\(hiddenBin.path):$PATH\"\n".write(
            to: bin.appendingPathComponent("activate"),
            atomically: true,
            encoding: .utf8
        )
        let python = hiddenBin.appendingPathComponent("python")
        try "#!/bin/sh\necho Python 3.13.1\n".write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

        let candidate = try XCTUnwrap(EnvironmentClassifier.classify(url: env))
        XCTAssertNil(candidate.interpreterPath)
        let record = EnvironmentInspector().inspect(candidate: candidate, includePackageCount: false)
        XCTAssertEqual(record.interpreterPath?.path, python.path)
        XCTAssertEqual(record.health, .healthy)
        XCTAssertEqual(record.pythonVersion, "3.13.1")
    }

    func testClassifiesPoetryAndPipxPaths() throws {
        let poetry = tempRoot.appendingPathComponent("Library/Caches/pypoetry/virtualenvs/demo", isDirectory: true)
        let pipx = tempRoot.appendingPathComponent(".local/pipx/venvs/black", isDirectory: true)

        for url in [poetry, pipx] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try "home = /usr/bin\n".write(to: url.appendingPathComponent("pyvenv.cfg"), atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: url.appendingPathComponent("bin"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.appendingPathComponent("bin/python").path, contents: Data())
        }

        XCTAssertEqual(EnvironmentClassifier.classify(url: poetry)?.kind, .poetry)
        XCTAssertEqual(EnvironmentClassifier.classify(url: pipx)?.kind, .pipx)
    }

    func testClassifiesPyenvPythonInstall() throws {
        let install = tempRoot.appendingPathComponent(".pyenv/versions/3.10.13", isDirectory: true)
        try FileManager.default.createDirectory(at: install.appendingPathComponent("bin"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: install.appendingPathComponent("bin/python").path, contents: Data())

        let candidate = try XCTUnwrap(EnvironmentClassifier.classify(url: install, source: "pyenv"))
        XCTAssertEqual(candidate.kind, .pyenvPython)
        XCTAssertEqual(candidate.manager, "pyenv")
    }

    func testHomeScanSkipsNoisyFolders() {
        let home = URL(fileURLWithPath: "/Users/example")
        XCTAssertTrue(ScanRootPolicy.shouldSkipDuringHomeScan(home.appendingPathComponent("Library"), home: home))
        XCTAssertTrue(ScanRootPolicy.shouldSkipDuringHomeScan(home.appendingPathComponent("project/node_modules"), home: home))
        XCTAssertFalse(ScanRootPolicy.shouldSkipDuringHomeScan(home.appendingPathComponent("Documents/project"), home: home))
    }

    func testDeduplicatesByResolvedPath() throws {
        let env = tempRoot.appendingPathComponent("env", isDirectory: true)
        try FileManager.default.createDirectory(at: env, withIntermediateDirectories: true)
        let candidate = EnvironmentCandidate(
            url: env,
            kind: .venv,
            manager: "venv",
            source: "test",
            interpreterPath: nil,
            health: .missingInterpreter
        )

        XCTAssertEqual(EnvironmentScanner.deduplicate([candidate, candidate]).count, 1)
    }

    func testParsesPipInspectJson() throws {
        let sitePackages = tempRoot.appendingPathComponent("site-packages", isDirectory: true)
        let packageDir = sitePackages.appendingPathComponent("demo")
        let distInfo = sitePackages.appendingPathComponent("demo-1.0.dist-info")
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: distInfo, withIntermediateDirectories: true)
        try "print('hi')".write(to: packageDir.appendingPathComponent("__init__.py"), atomically: true, encoding: .utf8)
        try "demo/__init__.py,,\n".write(to: distInfo.appendingPathComponent("RECORD"), atomically: true, encoding: .utf8)

        let json = """
        {
          "version": "1",
          "pip_version": "25.0",
          "installed": [
            {
              "metadata": { "name": "demo", "version": "1.0" },
              "metadata_location": "\(distInfo.path)",
              "installer": "pip",
              "requested": true,
              "direct_url": { "url": "file:///tmp/demo", "dir_info": { "editable": true } }
            }
          ],
          "environment": {}
        }
        """

        let packages = try PackageParser.parsePipInspect(data: Data(json.utf8))
        XCTAssertEqual(packages.count, 1)
        XCTAssertEqual(packages[0].name, "demo")
        XCTAssertEqual(packages[0].version, "1.0")
        XCTAssertEqual(packages[0].requested, true)
        XCTAssertEqual(packages[0].editable, true)
        XCTAssertNotNil(packages[0].sizeBytes)
    }

    func testParsesPipListFallbackJson() throws {
        let json = """
        [
          { "name": "pip", "version": "25.0" },
          { "name": "local", "version": "0.1", "editable_project_location": "/tmp/local" }
        ]
        """

        let packages = try PackageParser.parsePipList(data: Data(json.utf8))
        XCTAssertEqual(packages.count, 2)
        XCTAssertTrue(packages.contains { $0.name == "local" && $0.editable })
    }

    func testOfflineScannerReadsDistInfoFromBrokenVenv() throws {
        let env = tempRoot.appendingPathComponent(".broken", isDirectory: true)
        let sitePackages = env.appendingPathComponent("lib/python3.12/site-packages", isDirectory: true)
        let packageDir = sitePackages.appendingPathComponent("demo_pkg", isDirectory: true)
        let distInfo = sitePackages.appendingPathComponent("demo_pkg-1.2.3.dist-info", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: distInfo, withIntermediateDirectories: true)
        try "home = /usr/bin\n".write(to: env.appendingPathComponent("pyvenv.cfg"), atomically: true, encoding: .utf8)
        try "print('demo')".write(to: packageDir.appendingPathComponent("__init__.py"), atomically: true, encoding: .utf8)
        try "Name: demo-pkg\nVersion: 1.2.3\n".write(to: distInfo.appendingPathComponent("METADATA"), atomically: true, encoding: .utf8)
        try "pip\n".write(to: distInfo.appendingPathComponent("INSTALLER"), atomically: true, encoding: .utf8)
        try Data().write(to: distInfo.appendingPathComponent("REQUESTED"))
        try "demo_pkg/__init__.py,,\ndemo_pkg-1.2.3.dist-info/METADATA,,\n".write(
            to: distInfo.appendingPathComponent("RECORD"),
            atomically: true,
            encoding: .utf8
        )

        let packages = OfflinePackageScanner().scanPackages(in: env)
        XCTAssertEqual(packages.count, 1)
        XCTAssertEqual(packages[0].name, "demo-pkg")
        XCTAssertEqual(packages[0].version, "1.2.3")
        XCTAssertEqual(packages[0].installer, "pip")
        XCTAssertEqual(packages[0].requested, true)
        XCTAssertNotNil(packages[0].sizeBytes)

        let candidate = try XCTUnwrap(EnvironmentClassifier.classify(url: env))
        let record = EnvironmentInspector().inspect(candidate: candidate)
        XCTAssertEqual(record.kind, .venv)
        XCTAssertEqual(record.health, .metadataOnly)
        XCTAssertEqual(record.packageCount, 1)
        XCTAssertEqual(try EnvironmentInspector().loadPackages(for: record).map(\.name), ["demo-pkg"])
    }

    func testMetadataUninstallMovesRecordedFilesToTrash() throws {
        let env = tempRoot.appendingPathComponent(".broken", isDirectory: true)
        let sitePackages = env.appendingPathComponent("lib/python3.12/site-packages", isDirectory: true)
        let packageDir = sitePackages.appendingPathComponent("demo_pkg", isDirectory: true)
        let packageFile = packageDir.appendingPathComponent("__init__.py")
        let distInfo = sitePackages.appendingPathComponent("demo_pkg-1.2.3.dist-info", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: distInfo, withIntermediateDirectories: true)
        try "print('demo')".write(to: packageFile, atomically: true, encoding: .utf8)
        try "Name: demo-pkg\nVersion: 1.2.3\n".write(to: distInfo.appendingPathComponent("METADATA"), atomically: true, encoding: .utf8)
        try "demo_pkg/__init__.py,,\ndemo_pkg-1.2.3.dist-info/METADATA,,\n".write(
            to: distInfo.appendingPathComponent("RECORD"),
            atomically: true,
            encoding: .utf8
        )

        let package = try XCTUnwrap(OfflinePackageScanner().scanPackages(in: env).first)
        let record = EnvironmentRecord(
            name: ".broken",
            path: env,
            kind: .venv,
            manager: "venv",
            source: "test",
            interpreterPath: nil,
            pythonVersion: "3.12",
            sizeBytes: 0,
            packageCount: 1,
            health: .metadataOnly,
            lastModified: nil
        )

        try EnvironmentInspector().uninstallPackage(package, from: record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: distInfo.path))
    }

    func testLocalPyenvInstallIfPresent() async throws {
        let pyenv = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pyenv/versions/3.10.13")
        guard FileManager.default.fileExists(atPath: pyenv.path) else {
            throw XCTSkip("Local pyenv 3.10.13 install is not present.")
        }

        let scanner = EnvironmentScanner(
            roots: [ScanRoot(url: pyenv, label: "pyenv 3.10.13", source: "pyenv")],
            includeHomeScan: false,
            includePackageCounts: false
        )
        let records = await scanner.scan()

        XCTAssertTrue(records.contains { $0.kind == .pyenvPython && $0.path.path == pyenv.path })
    }
}
