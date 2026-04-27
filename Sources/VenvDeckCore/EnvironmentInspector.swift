import Foundation

public struct EnvironmentInspector {
    private let diskUsageService: DiskUsageService
    private let offlinePackageScanner: OfflinePackageScanner

    public init(
        diskUsageService: DiskUsageService = DiskUsageService(),
        offlinePackageScanner: OfflinePackageScanner = OfflinePackageScanner()
    ) {
        self.diskUsageService = diskUsageService
        self.offlinePackageScanner = offlinePackageScanner
    }

    public func inspect(candidate: EnvironmentCandidate, includePackageCount: Bool = true) -> EnvironmentRecord {
        let recoveredInterpreter = candidate.interpreterPath ?? activatedInterpreterPath(in: candidate.url)
        let enrichedCandidate = EnvironmentCandidate(
            url: candidate.url,
            kind: candidate.kind,
            manager: candidate.manager,
            source: candidate.source,
            interpreterPath: recoveredInterpreter,
            health: recoveredInterpreter == nil ? candidate.health : .healthy
        )
        let offlinePackages = offlinePackageScanner.scanPackages(in: candidate.url)
        let runnablePythonVersion = pythonVersion(for: enrichedCandidate)
        let version = runnablePythonVersion ?? metadataPythonVersion(in: candidate.url) ?? "Unknown"
        let size = diskUsageService.size(of: candidate.url)
        let modified = (try? candidate.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let packageCount = includePackageCount ? (try? loadPackages(for: enrichedCandidate).count) ?? offlinePackages.count : 0
        let health: EnvironmentHealth
        if runnablePythonVersion != nil {
            health = .healthy
        } else if candidate.health == .missingInterpreter && !offlinePackages.isEmpty {
            health = .metadataOnly
        } else {
            health = candidate.health
        }

        return EnvironmentRecord(
            name: candidate.url.lastPathComponent,
            path: candidate.url,
            kind: candidate.kind,
            manager: candidate.manager,
            source: candidate.source,
            interpreterPath: recoveredInterpreter,
            pythonVersion: version,
            sizeBytes: size,
            packageCount: packageCount,
            health: health,
            lastModified: modified
        )
    }

    public func loadPackages(for environment: EnvironmentRecord) throws -> [PackageRecord] {
        let candidate = EnvironmentCandidate(
            url: environment.path,
            kind: environment.kind,
            manager: environment.manager,
            source: environment.source,
            interpreterPath: environment.interpreterPath,
            health: environment.health
        )
        return try loadPackages(for: candidate)
    }

    public func loadPackages(for candidate: EnvironmentCandidate) throws -> [PackageRecord] {
        if candidate.kind == .conda,
           let conda = ProcessRunner.findExecutable(named: "conda"),
           let packages = tryCondaPackages(for: candidate, conda: conda) {
            return packages
        }

        if candidate.interpreterPath != nil,
           let packages = tryPipPackages(for: candidate) {
            return packages
        }

        let offlinePackages = offlinePackageScanner.scanPackages(in: candidate.url)
        if !offlinePackages.isEmpty {
            return offlinePackages
        }

        if candidate.interpreterPath == nil {
            throw EnvViewerError.missingInterpreter
        }

        return []
    }

    private func tryCondaPackages(for candidate: EnvironmentCandidate, conda: URL) -> [PackageRecord]? {
        guard let result = try? ProcessRunner.run(
            executable: conda,
            arguments: ["list", "-p", candidate.url.path, "--json"],
            timeout: 25
        ) else {
            return nil
        }

        guard result.exitCode == 0, let data = result.stdout.data(using: .utf8) else {
            return nil
        }

        return try? PackageParser.parseCondaList(data: data)
    }

    private func tryPipPackages(for candidate: EnvironmentCandidate) -> [PackageRecord]? {
        do {
            return try loadPipPackages(for: candidate)
        } catch {
            return nil
        }
    }

    public func uninstallPackage(_ package: PackageRecord, from environment: EnvironmentRecord) throws {
        if let interpreter = environment.interpreterPath,
           package.installer.lowercased() == "pip" {
            try uninstallPipPackage(package, from: environment, using: interpreter)
            return
        }

        try uninstallMetadataPackage(package, from: environment)
    }

    public func uninstallPipPackage(_ package: PackageRecord, from environment: EnvironmentRecord) throws {
        guard let interpreter = environment.interpreterPath else {
            try uninstallMetadataPackage(package, from: environment)
            return
        }

        try uninstallPipPackage(package, from: environment, using: interpreter)
    }

    private func uninstallPipPackage(_ package: PackageRecord, from environment: EnvironmentRecord, using interpreter: URL) throws {
        let result = try ProcessRunner.run(
            executable: interpreter,
            arguments: ["-m", "pip", "uninstall", "-y", package.name],
            timeout: 120
        )

        guard result.exitCode == 0 else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw EnvViewerError.processFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func loadPipPackages(for candidate: EnvironmentCandidate) throws -> [PackageRecord] {
        guard let interpreter = candidate.interpreterPath else {
            throw EnvViewerError.missingInterpreter
        }

        let inspect = try? ProcessRunner.run(
            executable: interpreter,
            arguments: ["-m", "pip", "inspect", "--local"],
            timeout: 25
        )

        if let inspect,
           inspect.exitCode == 0,
           let data = inspect.stdout.data(using: .utf8),
           let packages = try? PackageParser.parsePipInspect(data: data) {
            return packages
        }

        let list = try ProcessRunner.run(
            executable: interpreter,
            arguments: ["-m", "pip", "list", "--format=json"],
            timeout: 25
        )

        guard list.exitCode == 0, let data = list.stdout.data(using: .utf8) else {
            let detail = list.stderr.isEmpty ? list.stdout : list.stderr
            throw EnvViewerError.processFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return try PackageParser.parsePipList(data: data)
    }

    private func uninstallMetadataPackage(_ package: PackageRecord, from environment: EnvironmentRecord) throws {
        guard let metadataLocation = package.metadataLocation else {
            throw EnvViewerError.unsupportedAction("This package has no local metadata path to remove.")
        }

        let environmentPath = environment.path.standardizedFileURL.path
        let metadataPath = metadataLocation.standardizedFileURL.path
        guard metadataPath.hasPrefix(environmentPath + "/") else {
            throw EnvViewerError.unsupportedAction("Package metadata is outside this environment.")
        }

        let record = metadataLocation.appendingPathComponent("RECORD")
        guard let content = try? String(contentsOf: record, encoding: .utf8) else {
            throw EnvViewerError.unsupportedAction("Metadata-only uninstall requires a RECORD file.")
        }

        let sitePackages = metadataLocation.deletingLastPathComponent()
        var targets = Set<URL>()

        for line in content.split(whereSeparator: \.isNewline) {
            let columns = splitRecordLine(String(line))
            guard let relativePath = columns.first, !relativePath.isEmpty else {
                continue
            }

            let target = sitePackages.appendingPathComponent(relativePath).standardizedFileURL
            guard target.path.hasPrefix(environmentPath + "/") else {
                continue
            }
            targets.insert(target)
        }

        targets.insert(metadataLocation.standardizedFileURL)

        let sortedTargets = targets.sorted {
            $0.pathComponents.count > $1.pathComponents.count
        }

        var removedAny = false
        for target in sortedTargets where FileManager.default.fileExists(atPath: target.path) {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: target, resultingItemURL: &resultingURL)
            removedAny = true
        }

        guard removedAny else {
            throw EnvViewerError.unsupportedAction("No installed package files were found to remove.")
        }
    }

    private func pythonVersion(for candidate: EnvironmentCandidate) -> String? {
        guard let interpreter = candidate.interpreterPath else {
            return nil
        }

        guard let result = try? ProcessRunner.run(executable: interpreter, arguments: ["--version"], timeout: 5),
              result.exitCode == 0
        else {
            return nil
        }

        let combined = result.stdout.isEmpty ? result.stderr : result.stdout
        return combined
            .replacingOccurrences(of: "Python ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func activatedInterpreterPath(in environmentURL: URL) -> URL? {
        let activatePath = environmentURL.appendingPathComponent("bin/activate")
        guard FileManager.default.fileExists(atPath: activatePath.path) else {
            return nil
        }

        let command = "source \(shellQuote(activatePath.path)) >/dev/null 2>&1 && command -v python"
        guard let result = try? ProcessRunner.runShell(command, timeout: 5, currentDirectoryURL: environmentURL),
              result.exitCode == 0
        else {
            return nil
        }

        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: path)
    }

    private func metadataPythonVersion(in environmentURL: URL) -> String? {
        let pyvenvConfig = environmentURL.appendingPathComponent("pyvenv.cfg")
        let values = EnvironmentClassifier.readPyvenvConfig(at: pyvenvConfig)

        if let version = values["version"], !version.isEmpty {
            return normalizedPythonVersion(version)
        }

        if let versionInfo = values["version_info"], !versionInfo.isEmpty {
            return normalizedPythonVersion(versionInfo)
        }

        for key in ["executable", "base-executable", "base_executable", "home"] {
            if let inferred = values[key].flatMap(inferPythonVersionFromPath) {
                return inferred
            }
        }

        for libName in ["lib", "lib64", "Lib"] {
            let libURL = environmentURL.appendingPathComponent(libName, isDirectory: true)
            guard let directories = try? FileManager.default.contentsOfDirectory(
                at: libURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for directory in directories {
                if let inferred = inferPythonVersionFromPath(directory.lastPathComponent) {
                    return inferred
                }
            }
        }

        return nil
    }

    private func normalizedPythonVersion(_ rawValue: String) -> String? {
        let match = rawValue.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression)
        guard let match else {
            return nil
        }

        return String(rawValue[match])
    }

    private func inferPythonVersionFromPath(_ path: String) -> String? {
        normalizedPythonVersion(path)
    }

    private func splitRecordLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false

        for character in line {
            if character == "\"" {
                inQuotes.toggle()
            } else if character == "," && !inQuotes {
                fields.append(current.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
                current = ""
            } else {
                current.append(character)
            }
        }

        fields.append(current.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        return fields
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
