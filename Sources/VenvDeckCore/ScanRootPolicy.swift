import Foundation

public enum ScanRootPolicy {
    public static func defaultRoots(fileManager: FileManager = .default) -> [ScanRoot] {
        let home = fileManager.homeDirectoryForCurrentUser
        let roots: [(String, String, URL)] = [
            ("Home", "home", home),
            ("pyenv versions", "pyenv", home.appendingPathComponent(".pyenv/versions")),
            ("virtualenvs", "virtualenv", home.appendingPathComponent(".virtualenvs")),
            ("venvs", "venv", home.appendingPathComponent(".venvs")),
            ("venvs", "venv", home.appendingPathComponent("venvs")),
            ("envs", "venv", home.appendingPathComponent("envs")),
            ("conda envs", "conda", home.appendingPathComponent(".conda/envs")),
            ("miniconda envs", "conda", home.appendingPathComponent("miniconda3/envs")),
            ("anaconda envs", "conda", home.appendingPathComponent("anaconda3/envs")),
            ("miniforge envs", "conda", home.appendingPathComponent("miniforge3/envs")),
            ("mambaforge envs", "conda", home.appendingPathComponent("mambaforge/envs")),
            ("Poetry envs", "poetry", home.appendingPathComponent("Library/Caches/pypoetry/virtualenvs")),
            ("pipx envs", "pipx", home.appendingPathComponent(".local/pipx/venvs")),
            ("uv tools", "uv", home.appendingPathComponent(".local/share/uv/tools")),
            ("uv python installs", "uv", home.appendingPathComponent(".local/share/uv/python"))
        ]

        return roots.map { label, source, url in
            ScanRoot(url: url, label: label, source: source, enabled: fileManager.fileExists(atPath: url.path))
        }
    }

    public static func shouldSkipDuringHomeScan(_ url: URL, home: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasSuffix(".app") {
            return true
        }

        let skippedNames: Set<String> = [
            ".Trash",
            ".cache",
            ".git",
            ".hg",
            ".svn",
            ".npm",
            ".pnpm-store",
            ".cargo",
            ".rustup",
            ".Trash",
            "Applications",
            "Library",
            "Movies",
            "Music",
            "Pictures",
            "node_modules",
            "DerivedData",
            "build",
            "dist",
            ".build",
            "__pycache__"
        ]

        if skippedNames.contains(name) {
            return true
        }

        let relative = url.path.replacingOccurrences(of: home.path + "/", with: "")
        if relative.hasPrefix("Library/") {
            return true
        }

        return false
    }
}
