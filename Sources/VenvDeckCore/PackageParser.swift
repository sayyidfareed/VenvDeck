import Foundation

public enum PackageParser {
    public static func parsePipInspect(data: Data, sizeEstimator: PackageSizeEstimator = PackageSizeEstimator()) throws -> [PackageRecord] {
        let report = try JSONDecoder().decode(PipInspectReport.self, from: data)
        return report.installed.compactMap { item in
            guard let name = item.metadata.name, let version = item.metadata.version else {
                return nil
            }

            let metadataURL = item.metadataLocation.map(URL.init(fileURLWithPath:))
            let size = metadataURL.flatMap { sizeEstimator.sizeForDistribution(metadataLocation: $0) }

            return PackageRecord(
                name: name,
                version: version,
                installer: item.installer ?? "pip",
                requested: item.requested,
                metadataLocation: metadataURL,
                sizeBytes: size,
                editable: item.directURL?.dirInfo?.editable ?? false,
                directURL: item.directURL?.url
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func parsePipList(data: Data) throws -> [PackageRecord] {
        let items = try JSONDecoder().decode([PipListItem].self, from: data)
        return items.map {
            PackageRecord(
                name: $0.name,
                version: $0.version,
                installer: "pip",
                requested: nil,
                metadataLocation: nil,
                sizeBytes: nil,
                editable: $0.editableProjectLocation != nil,
                directURL: $0.editableProjectLocation
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func parseCondaList(data: Data) throws -> [PackageRecord] {
        let items = try JSONDecoder().decode([CondaListItem].self, from: data)
        return items.map {
            PackageRecord(
                name: $0.name,
                version: $0.version,
                installer: "conda",
                requested: nil,
                metadataLocation: nil,
                sizeBytes: $0.size.map(Int64.init),
                editable: false,
                directURL: $0.url
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

public struct PackageSizeEstimator {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func sizeForDistribution(metadataLocation: URL) -> Int64? {
        let record = metadataLocation.appendingPathComponent("RECORD")
        guard fileManager.fileExists(atPath: record.path),
              let content = try? String(contentsOf: record, encoding: .utf8)
        else {
            return nil
        }

        let sitePackages = metadataLocation.deletingLastPathComponent()
        var total: Int64 = 0

        for line in content.split(whereSeparator: \.isNewline) {
            let columns = splitRecordLine(String(line))
            guard let relativePath = columns.first, !relativePath.isEmpty else {
                continue
            }
            let fileURL = sitePackages.appendingPathComponent(relativePath)
            if let size = allocatedSize(of: fileURL) {
                total += size
            }
        }

        return total
    }

    private func allocatedSize(of url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ]) else {
            return nil
        }

        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
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
}

private struct PipInspectReport: Decodable {
    let installed: [PipInspectItem]
}

private struct PipInspectItem: Decodable {
    let metadata: PipInspectMetadata
    let metadataLocation: String?
    let installer: String?
    let requested: Bool?
    let directURL: DirectURL?

    enum CodingKeys: String, CodingKey {
        case metadata
        case metadataLocation = "metadata_location"
        case installer
        case requested
        case directURL = "direct_url"
    }
}

private struct PipInspectMetadata: Decodable {
    let name: String?
    let version: String?
}

private struct DirectURL: Decodable {
    let url: String?
    let dirInfo: DirInfo?

    enum CodingKeys: String, CodingKey {
        case url
        case dirInfo = "dir_info"
    }
}

private struct DirInfo: Decodable {
    let editable: Bool?
}

private struct PipListItem: Decodable {
    let name: String
    let version: String
    let editableProjectLocation: String?

    enum CodingKeys: String, CodingKey {
        case name
        case version
        case editableProjectLocation = "editable_project_location"
    }
}

private struct CondaListItem: Decodable {
    let name: String
    let version: String
    let size: Int?
    let url: String?
}
