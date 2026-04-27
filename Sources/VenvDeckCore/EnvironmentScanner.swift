import Foundation

public final class EnvironmentScanner {
    private let fileManager: FileManager
    private let inspector: EnvironmentInspector
    private let roots: [ScanRoot]
    private let includeHomeScan: Bool
    private let includePackageCounts: Bool
    private let maxHomeDepth: Int

    public init(
        fileManager: FileManager = .default,
        inspector: EnvironmentInspector = EnvironmentInspector(),
        roots: [ScanRoot]? = nil,
        includeHomeScan: Bool = true,
        includePackageCounts: Bool = true,
        maxHomeDepth: Int = 5
    ) {
        self.fileManager = fileManager
        self.inspector = inspector
        self.roots = roots ?? ScanRootPolicy.defaultRoots(fileManager: fileManager)
        self.includeHomeScan = includeHomeScan
        self.includePackageCounts = includePackageCounts
        self.maxHomeDepth = maxHomeDepth
    }

    public func scan(progress: @escaping (ScanProgress) -> Void = { _ in }) async -> [EnvironmentRecord] {
        await Task.detached(priority: .userInitiated) {
            self.scanSynchronously(progress: progress)
        }.value
    }

    public static func deduplicate(_ candidates: [EnvironmentCandidate]) -> [EnvironmentCandidate] {
        var seen: Set<String> = []
        var result: [EnvironmentCandidate] = []

        for candidate in candidates {
            let key = candidate.url.resolvingSymlinksInPath().standardizedFileURL.path
            if seen.insert(key).inserted {
                result.append(candidate)
            }
        }

        return result
    }

    private func scanSynchronously(progress: @escaping (ScanProgress) -> Void) -> [EnvironmentRecord] {
        progress(ScanProgress(message: "Finding scan roots", discoveredCount: 0))
        var candidates: [EnvironmentCandidate] = []

        for root in roots where root.enabled {
            guard fileManager.fileExists(atPath: root.url.path) else {
                continue
            }

            progress(ScanProgress(message: "Scanning \(root.label)", discoveredCount: candidates.count))
            if root.source == "home" {
                if includeHomeScan {
                    candidates.append(contentsOf: discoverInHome(root.url))
                }
            } else {
                candidates.append(contentsOf: discoverUnderKnownRoot(root))
            }
        }

        let unique = Self.deduplicate(candidates)
        progress(ScanProgress(message: "Inspecting \(unique.count) environments", discoveredCount: unique.count))

        let records = unique.map { candidate in
            inspector.inspect(candidate: candidate, includePackageCount: includePackageCounts)
        }

        progress(ScanProgress(message: "Scan complete", discoveredCount: records.count))
        return records.sorted {
            if $0.sizeBytes == $1.sizeBytes {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.sizeBytes > $1.sizeBytes
        }
    }

    private func discoverUnderKnownRoot(_ root: ScanRoot) -> [EnvironmentCandidate] {
        var candidates: [EnvironmentCandidate] = []

        if let candidate = EnvironmentClassifier.classify(url: root.url, source: root.source) {
            candidates.append(candidate)
        }

        guard let enumerator = fileManager.enumerator(
            at: root.url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return candidates
        }

        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true
            else {
                continue
            }

            if enumerator.level > 4 {
                enumerator.skipDescendants()
                continue
            }

            if let candidate = EnvironmentClassifier.classify(url: item, source: root.source) {
                candidates.append(candidate)
                enumerator.skipDescendants()
            }
        }

        return candidates
    }

    private func discoverInHome(_ home: URL) -> [EnvironmentCandidate] {
        var candidates: [EnvironmentCandidate] = []
        guard let enumerator = fileManager.enumerator(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return candidates
        }

        for case let item as URL in enumerator {
            if enumerator.level > maxHomeDepth {
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey]) else {
                continue
            }

            if values.isDirectory == true {
                if ScanRootPolicy.shouldSkipDuringHomeScan(item, home: home) {
                    enumerator.skipDescendants()
                    continue
                }

                if let candidate = EnvironmentClassifier.classify(url: item, source: "home") {
                    candidates.append(candidate)
                    enumerator.skipDescendants()
                }
            } else if item.lastPathComponent == "pyvenv.cfg" {
                let envURL = item.deletingLastPathComponent()
                if let candidate = EnvironmentClassifier.classify(url: envURL, source: "home") {
                    candidates.append(candidate)
                }
            }
        }

        return candidates
    }
}
