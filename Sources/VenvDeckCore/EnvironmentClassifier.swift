import Foundation

public enum EnvironmentClassifier {
    public static func classify(url: URL, source: String = "filesystem") -> EnvironmentCandidate? {
        let fileManager = FileManager.default
        let path = url.standardizedFileURL.path
        let interpreter = interpreterPath(in: url)

        if fileManager.fileExists(atPath: url.appendingPathComponent("conda-meta").path) {
            return EnvironmentCandidate(
                url: url,
                kind: .conda,
                manager: "conda",
                source: source,
                interpreterPath: interpreter,
                health: interpreter == nil ? .missingInterpreter : .healthy
            )
        }

        let pyvenvConfig = url.appendingPathComponent("pyvenv.cfg")
        if fileManager.fileExists(atPath: pyvenvConfig.path) {
            let values = readPyvenvConfig(at: pyvenvConfig)
            let kind = kindForPyvenv(path: path, parent: url.deletingLastPathComponent(), values: values)
            return EnvironmentCandidate(
                url: url,
                kind: kind,
                manager: kind.displayName,
                source: source,
                interpreterPath: interpreter,
                health: interpreter == nil ? .missingInterpreter : .healthy
            )
        }

        if isPyenvPythonInstall(url: url, interpreter: interpreter) {
            return EnvironmentCandidate(
                url: url,
                kind: .pyenvPython,
                manager: "pyenv",
                source: source,
                interpreterPath: interpreter,
                health: interpreter == nil ? .missingInterpreter : .healthy
            )
        }

        return nil
    }

    public static func interpreterPath(in url: URL) -> URL? {
        var candidates = [
            url.appendingPathComponent("bin/python3"),
            url.appendingPathComponent("bin/python"),
            url.appendingPathComponent("Scripts/python.exe")
        ]

        let binURL = url.appendingPathComponent("bin", isDirectory: true)
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: binURL,
            includingPropertiesForKeys: [.isExecutableKey, .isSymbolicLinkKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            let versioned = contents
                .filter { $0.lastPathComponent.range(of: #"^python\d+(\.\d+)?$"#, options: .regularExpression) != nil }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            candidates.append(contentsOf: versioned)
        }

        for candidate in candidates where isUsableInterpreter(candidate) {
            return candidate
        }

        return nil
    }

    public static func readPyvenvConfig(at url: URL) -> [String: String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }

        var values: [String: String] = [:]
        for line in content.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                values[parts[0].lowercased()] = parts[1]
            }
        }
        return values
    }

    private static func kindForPyvenv(path: String, parent: URL, values: [String: String]) -> EnvironmentKind {
        if path.contains("/.local/pipx/venvs/") {
            return .pipx
        }

        if path.contains("/Library/Caches/pypoetry/virtualenvs/") {
            return .poetry
        }

        if path.contains("/.local/share/uv/") || FileManager.default.fileExists(atPath: parent.appendingPathComponent("uv.lock").path) {
            return .uv
        }

        if path.contains("/.virtualenvs/") || values.keys.contains("virtualenv") || values["creator"]?.lowercased().contains("virtualenv") == true {
            return .virtualenv
        }

        return .venv
    }

    private static func isPyenvPythonInstall(url: URL, interpreter: URL?) -> Bool {
        guard interpreter != nil else {
            return false
        }

        let path = url.standardizedFileURL.path
        guard path.contains("/.pyenv/versions/") else {
            return false
        }

        let suffix = path.components(separatedBy: "/.pyenv/versions/").last ?? ""
        if suffix.isEmpty || suffix.contains("/envs/") {
            return false
        }

        return url.lastPathComponent.range(of: #"^\d+\.\d+(\.\d+)?.*"#, options: .regularExpression) != nil
    }

    private static func isUsableInterpreter(_ url: URL) -> Bool {
        let path = url.path
        if FileManager.default.isExecutableFile(atPath: path) {
            return true
        }

        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            return true
        }

        return FileManager.default.fileExists(atPath: path)
    }
}
