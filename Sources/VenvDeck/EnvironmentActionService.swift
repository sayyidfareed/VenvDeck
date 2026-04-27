import AppKit
import Foundation
import VenvDeckCore

struct EnvironmentActionService {
    func revealInFinder(_ environment: EnvironmentRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([environment.path])
    }

    func moveToTrash(_ environment: EnvironmentRecord) async throws {
        guard environment.canDelete else {
            throw EnvViewerError.unsupportedAction("This record is not treated as a disposable environment.")
        }

        let target = environment.path

        do {
            let recycledURLs = try await recycle([target])
            if recycledURLs[target] != nil || !FileManager.default.fileExists(atPath: target.path) {
                return
            }
        } catch {
            if !FileManager.default.fileExists(atPath: target.path) {
                return
            }
        }

        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: target, resultingItemURL: &resultingURL)
    }

    func openTerminal(for environment: EnvironmentRecord) throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VenvDeck", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let commandURL = tempDir.appendingPathComponent("open-\(UUID().uuidString).command")
        let script = activationScript(for: environment)
        try script.write(to: commandURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandURL.path)

        NSWorkspace.shared.open(commandURL)
    }

    private func activationScript(for environment: EnvironmentRecord) -> String {
        let envPath = environment.path.path
        let binPath = environment.path.appendingPathComponent("bin").path
        let activatePath = environment.path.appendingPathComponent("bin/activate").path
        let title = environment.name
        let missingInterpreterNotice = environment.interpreterPath == nil
            ? #"echo "No environment Python executable was found. This shell is opened at the environment path for inspection.""#
            : ""

        return """
        #!/bin/zsh
        set -e
        export VENVDECK_ENV_PATH=\(shellQuote(envPath))
        export VENVDECK_ENV_NAME=\(shellQuote(title))
        export VENVDECK_BIN_PATH=\(shellQuote(binPath))
        export VENVDECK_ACTIVATE_PATH=\(shellQuote(activatePath))
        export VENVDECK_NOTICE=\(shellQuote(missingInterpreterNotice))
        export VENVDECK_USER_ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
        export VENVDECK_ZDOTDIR="$(mktemp -d "${TMPDIR:-/tmp}/venvdeck-zsh.XXXXXX")"

        cat > "$VENVDECK_ZDOTDIR/.zshrc" <<'VENVDECK_ZSHRC'
        if [[ -f "$VENVDECK_USER_ZSHRC" ]]; then
          source "$VENVDECK_USER_ZSHRC"
        fi

        cd "$VENVDECK_ENV_PATH"

        if [[ -f "$VENVDECK_ACTIVATE_PATH" ]]; then
          source "$VENVDECK_ACTIVATE_PATH"
        else
          export VIRTUAL_ENV="$VENVDECK_ENV_PATH"
          export PATH="$VENVDECK_BIN_PATH:$PATH"
        fi

        clear
        echo "Activated '$VENVDECK_ENV_NAME'"
        echo "$VENVDECK_ENV_PATH"
        eval "$VENVDECK_NOTICE"
        VENVDECK_PYTHON="$(command -v python 2>/dev/null || true)"
        if [[ -n "$VENVDECK_PYTHON" ]]; then
          echo "python: $VENVDECK_PYTHON"
        fi
        echo "cwd: $PWD"
        VENVDECK_ZSHRC

        exec env ZDOTDIR="$VENVDECK_ZDOTDIR" "${SHELL:-/bin/zsh}" -i
        """
    }

    @MainActor
    private func recycle(_ urls: [URL]) async throws -> [URL: URL] {
        try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { recycledURLs, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: recycledURLs)
                }
            }
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
