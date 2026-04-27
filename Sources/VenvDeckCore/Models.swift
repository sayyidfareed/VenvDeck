import Foundation

public enum EnvironmentKind: String, CaseIterable, Codable, Hashable, Identifiable {
    case venv
    case virtualenv
    case conda
    case pyenvPython
    case poetry
    case uv
    case pipx
    case broken
    case unknown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .venv: "venv"
        case .virtualenv: "virtualenv"
        case .conda: "conda"
        case .pyenvPython: "pyenv Python"
        case .poetry: "Poetry"
        case .uv: "uv"
        case .pipx: "pipx"
        case .broken: "Broken"
        case .unknown: "Unknown"
        }
    }
}

public enum EnvironmentHealth: String, Codable, Hashable {
    case healthy
    case missingInterpreter
    case metadataOnly
    case unreadable
    case unknown

    public var displayName: String {
        switch self {
        case .healthy: "Healthy"
        case .missingInterpreter: "Missing interpreter"
        case .metadataOnly: "Metadata only"
        case .unreadable: "Unreadable"
        case .unknown: "Unknown"
        }
    }
}

public struct ScanRoot: Identifiable, Codable, Hashable {
    public var id: String { url.standardizedFileURL.path }
    public let url: URL
    public let label: String
    public let source: String
    public var enabled: Bool

    public init(url: URL, label: String, source: String, enabled: Bool = true) {
        self.url = url
        self.label = label
        self.source = source
        self.enabled = enabled
    }
}

public struct EnvironmentCandidate: Hashable {
    public let url: URL
    public let kind: EnvironmentKind
    public let manager: String
    public let source: String
    public let interpreterPath: URL?
    public let health: EnvironmentHealth

    public init(
        url: URL,
        kind: EnvironmentKind,
        manager: String,
        source: String,
        interpreterPath: URL?,
        health: EnvironmentHealth
    ) {
        self.url = url
        self.kind = kind
        self.manager = manager
        self.source = source
        self.interpreterPath = interpreterPath
        self.health = health
    }
}

public struct EnvironmentRecord: Identifiable, Codable, Hashable {
    public var id: String { path.standardizedFileURL.path }
    public let name: String
    public let path: URL
    public let kind: EnvironmentKind
    public let manager: String
    public let source: String
    public let interpreterPath: URL?
    public let pythonVersion: String
    public let sizeBytes: Int64
    public let packageCount: Int
    public let health: EnvironmentHealth
    public let lastModified: Date?

    public init(
        name: String,
        path: URL,
        kind: EnvironmentKind,
        manager: String,
        source: String,
        interpreterPath: URL?,
        pythonVersion: String,
        sizeBytes: Int64,
        packageCount: Int,
        health: EnvironmentHealth,
        lastModified: Date?
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.manager = manager
        self.source = source
        self.interpreterPath = interpreterPath
        self.pythonVersion = pythonVersion
        self.sizeBytes = sizeBytes
        self.packageCount = packageCount
        self.health = health
        self.lastModified = lastModified
    }

    public var canDelete: Bool {
        switch kind {
        case .pyenvPython, .unknown:
            false
        default:
            true
        }
    }

    public var canUsePip: Bool {
        interpreterPath != nil && health == .healthy
    }

    public var canOpenTerminal: Bool {
        FileManager.default.fileExists(atPath: path.path)
    }
}

public struct PackageRecord: Identifiable, Codable, Hashable {
    public var id: String { "\(name.lowercased())-\(version)-\(metadataLocation?.path ?? "")" }
    public let name: String
    public let version: String
    public let installer: String
    public let requested: Bool?
    public let metadataLocation: URL?
    public let sizeBytes: Int64?
    public let editable: Bool
    public let directURL: String?

    public init(
        name: String,
        version: String,
        installer: String,
        requested: Bool?,
        metadataLocation: URL?,
        sizeBytes: Int64?,
        editable: Bool,
        directURL: String?
    ) {
        self.name = name
        self.version = version
        self.installer = installer
        self.requested = requested
        self.metadataLocation = metadataLocation
        self.sizeBytes = sizeBytes
        self.editable = editable
        self.directURL = directURL
    }
}

public struct ScanProgress: Equatable {
    public let message: String
    public let discoveredCount: Int

    public init(message: String, discoveredCount: Int) {
        self.message = message
        self.discoveredCount = discoveredCount
    }
}

public enum EnvViewerError: LocalizedError {
    case missingInterpreter
    case processFailed(String)
    case timedOut(String)
    case unsupportedAction(String)

    public var errorDescription: String? {
        switch self {
        case .missingInterpreter:
            "No Python interpreter was found for this environment."
        case .unsupportedAction(let message):
            message
        case .processFailed(let message):
            message
        case .timedOut(let command):
            "\(command) timed out."
        }
    }
}
