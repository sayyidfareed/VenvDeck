import Foundation

public struct OfflinePackageScanner {
    private let fileManager: FileManager
    private let sizeEstimator: PackageSizeEstimator

    public init(
        fileManager: FileManager = .default,
        sizeEstimator: PackageSizeEstimator = PackageSizeEstimator()
    ) {
        self.fileManager = fileManager
        self.sizeEstimator = sizeEstimator
    }

    public func scanPackages(in environmentURL: URL) -> [PackageRecord] {
        let sitePackages = sitePackageDirectories(in: environmentURL)
        var records: [PackageRecord] = []
        var seenMetadataPaths = Set<String>()

        for directory in sitePackages {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for item in contents {
                let name = item.lastPathComponent
                guard name.hasSuffix(".dist-info") || name.hasSuffix(".egg-info") else {
                    continue
                }

                let metadataPath = item.standardizedFileURL.path
                guard seenMetadataPaths.insert(metadataPath).inserted,
                      let record = packageRecord(from: item)
                else {
                    continue
                }

                records.append(record)
            }
        }

        return records.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func sitePackageDirectories(in environmentURL: URL) -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()

        func appendIfPresent(_ url: URL) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                return
            }

            let path = url.standardizedFileURL.path
            if seen.insert(path).inserted {
                found.append(url)
            }
        }

        appendIfPresent(environmentURL.appendingPathComponent("Lib/site-packages", isDirectory: true))
        appendIfPresent(environmentURL.appendingPathComponent("lib/site-packages", isDirectory: true))

        for libName in ["lib", "lib64"] {
            let libURL = environmentURL.appendingPathComponent(libName, isDirectory: true)
            guard let pythonDirs = try? fileManager.contentsOfDirectory(
                at: libURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for pythonDir in pythonDirs where pythonDir.lastPathComponent.hasPrefix("python") {
                appendIfPresent(pythonDir.appendingPathComponent("site-packages", isDirectory: true))
            }
        }

        return found
    }

    private func packageRecord(from metadataLocation: URL) -> PackageRecord? {
        let metadataFile = preferredMetadataFile(in: metadataLocation)
        guard let metadataFile,
              let metadata = try? String(contentsOf: metadataFile, encoding: .utf8)
        else {
            return fallbackPackageRecord(from: metadataLocation)
        }

        let headers = metadataHeaders(from: metadata)
        guard let name = headers["name"], let version = headers["version"] else {
            return fallbackPackageRecord(from: metadataLocation)
        }

        let directURL = directURLMetadata(in: metadataLocation)
        return PackageRecord(
            name: name,
            version: version,
            installer: installer(in: metadataLocation),
            requested: hasFile(named: "REQUESTED", in: metadataLocation) ? true : nil,
            metadataLocation: metadataLocation,
            sizeBytes: sizeEstimator.sizeForDistribution(metadataLocation: metadataLocation),
            editable: directURL?.dirInfo?.editable ?? false,
            directURL: directURL?.url
        )
    }

    private func fallbackPackageRecord(from metadataLocation: URL) -> PackageRecord? {
        let parsed = parseNameAndVersion(fromMetadataDirectoryName: metadataLocation.lastPathComponent)
        guard let parsed else {
            return nil
        }

        return PackageRecord(
            name: parsed.name,
            version: parsed.version,
            installer: installer(in: metadataLocation),
            requested: hasFile(named: "REQUESTED", in: metadataLocation) ? true : nil,
            metadataLocation: metadataLocation,
            sizeBytes: sizeEstimator.sizeForDistribution(metadataLocation: metadataLocation),
            editable: directURLMetadata(in: metadataLocation)?.dirInfo?.editable ?? false,
            directURL: directURLMetadata(in: metadataLocation)?.url
        )
    }

    private func preferredMetadataFile(in metadataLocation: URL) -> URL? {
        let candidates: [URL]
        if metadataLocation.pathExtension == "egg-info" && isRegularFile(metadataLocation) {
            candidates = [metadataLocation]
        } else {
            candidates = [
                metadataLocation.appendingPathComponent("METADATA"),
                metadataLocation.appendingPathComponent("PKG-INFO")
            ]
        }

        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    private func metadataHeaders(from metadata: String) -> [String: String] {
        var headers: [String: String] = [:]

        for line in metadata.split(whereSeparator: \.isNewline) {
            guard !line.isEmpty else {
                break
            }

            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                continue
            }

            headers[String(parts[0]).lowercased()] = String(parts[1])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return headers
    }

    private func parseNameAndVersion(fromMetadataDirectoryName directoryName: String) -> (name: String, version: String)? {
        let suffixes = [".dist-info", ".egg-info"]
        guard let suffix = suffixes.first(where: { directoryName.hasSuffix($0) }) else {
            return nil
        }

        let base = String(directoryName.dropLast(suffix.count))
        guard let separator = base.lastIndex(of: "-") else {
            return nil
        }

        let name = String(base[..<separator]).replacingOccurrences(of: "_", with: "-")
        let version = String(base[base.index(after: separator)...])
        guard !name.isEmpty, !version.isEmpty else {
            return nil
        }

        return (name, version)
    }

    private func installer(in metadataLocation: URL) -> String {
        let installerFile = metadataLocation.appendingPathComponent("INSTALLER")
        guard let value = try? String(contentsOf: installerFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return "metadata"
        }

        return value
    }

    private func directURLMetadata(in metadataLocation: URL) -> OfflineDirectURL? {
        let url = metadataLocation.appendingPathComponent("direct_url.json")
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? JSONDecoder().decode(OfflineDirectURL.self, from: data)
    }

    private func hasFile(named fileName: String, in directory: URL) -> Bool {
        fileManager.fileExists(atPath: directory.appendingPathComponent(fileName).path)
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}

private struct OfflineDirectURL: Decodable {
    let url: String?
    let dirInfo: OfflineDirInfo?

    enum CodingKeys: String, CodingKey {
        case url
        case dirInfo = "dir_info"
    }
}

private struct OfflineDirInfo: Decodable {
    let editable: Bool?
}
