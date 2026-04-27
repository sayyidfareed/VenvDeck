import AppKit
import Foundation
import VenvDeckCore
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    enum SortMode: String, CaseIterable, Identifiable {
        case size
        case name
        case python
        case packages

        var id: String { rawValue }

        var title: String {
            switch self {
            case .size: "Size"
            case .name: "Name"
            case .python: "Python"
            case .packages: "Packages"
            }
        }
    }

    @Published var environments: [EnvironmentRecord] = []
    @Published var selectedEnvironmentID: EnvironmentRecord.ID?
    @Published var packages: [PackageRecord] = []
    @Published var selectedPackageID: PackageRecord.ID?
    @Published var searchText = ""
    @Published var selectedKind: EnvironmentKind?
    @Published var sortMode: SortMode = .size
    @Published var isScanning = false
    @Published var isLoadingPackages = false
    @Published var scanProgress = ScanProgress(message: "Ready", discoveredCount: 0)
    @Published var statusMessage = "Ready"
    @Published var packageInventoryMessage = "No environment selected"
    @Published var terminalOutput = ""
    @Published var isRunningTerminalCommand = false
    @Published var errorMessage: String?

    private let scanner = EnvironmentScanner()
    private let inspector = EnvironmentInspector()
    private let actions = EnvironmentActionService()

    var filteredEnvironments: [EnvironmentRecord] {
        var result = environments

        if let selectedKind {
            result = result.filter { $0.kind == selectedKind }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.path.path.localizedCaseInsensitiveContains(query)
                    || $0.pythonVersion.localizedCaseInsensitiveContains(query)
                    || $0.kind.displayName.localizedCaseInsensitiveContains(query)
            }
        }

        switch sortMode {
        case .size:
            result.sort { $0.sizeBytes == $1.sizeBytes ? $0.name < $1.name : $0.sizeBytes > $1.sizeBytes }
        case .name:
            result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .python:
            result.sort { $0.pythonVersion.localizedStandardCompare($1.pythonVersion) == .orderedAscending }
        case .packages:
            result.sort { $0.packageCount == $1.packageCount ? $0.name < $1.name : $0.packageCount > $1.packageCount }
        }

        return result
    }

    var selectedEnvironment: EnvironmentRecord? {
        guard let selectedEnvironmentID else { return nil }
        return environments.first { $0.id == selectedEnvironmentID }
    }

    var selectedPackage: PackageRecord? {
        guard let selectedPackageID else { return nil }
        return packages.first { $0.id == selectedPackageID }
    }

    var totalSize: Int64 {
        environments.reduce(0) { $0 + $1.sizeBytes }
    }

    func scan() async {
        isScanning = true
        packages = []
        selectedPackageID = nil
        packageInventoryMessage = "Scanning environments..."
        errorMessage = nil

        let records = await scanner.scan { [weak self] progress in
            Task { @MainActor in
                self?.scanProgress = progress
                self?.statusMessage = progress.message
            }
        }

        environments = records
        selectedEnvironmentID = records.first?.id
        isScanning = false
        statusMessage = "Found \(records.count) Python environment records"
        await loadSelectedPackages()
    }

    func loadSelectedPackages() async {
        guard let environment = selectedEnvironment else {
            packages = []
            packageInventoryMessage = "No environment selected"
            return
        }

        isLoadingPackages = true
        selectedPackageID = nil
        packageInventoryMessage = "Loading packages..."
        errorMessage = nil

        do {
            let inspector = self.inspector
            let loaded = try await Task.detached(priority: .userInitiated) {
                try inspector.loadPackages(for: environment)
            }.value
            packages = loaded
            packageInventoryMessage = loaded.isEmpty ? "No packages installed" : ""
            statusMessage = "Loaded \(loaded.count) packages from \(environment.name)"
        } catch {
            packages = []
            packageInventoryMessage = packageInventoryUnavailableMessage(for: environment, error: error)
            statusMessage = "Package inventory unavailable for \(environment.name)"
        }

        isLoadingPackages = false
    }

    func revealSelectedEnvironment() {
        guard let selectedEnvironment else { return }
        actions.revealInFinder(selectedEnvironment)
    }

    func openSelectedInTerminal() {
        guard let selectedEnvironment else { return }
        do {
            try actions.openTerminal(for: selectedEnvironment)
            statusMessage = selectedEnvironment.interpreterPath == nil
                ? "Opened inspection terminal for \(selectedEnvironment.name)"
                : "Opened activated terminal for \(selectedEnvironment.name)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func prepareEmbeddedTerminal() {
        guard let selectedEnvironment else {
            terminalOutput = ""
            return
        }

        terminalOutput = """
        VenvDeck shell: \(selectedEnvironment.name)
        \(selectedEnvironment.path.path)
        Commands run with this environment activated.

        """
    }

    func runEmbeddedTerminalCommand(_ command: String) async {
        guard let selectedEnvironment else { return }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunningTerminalCommand else {
            return
        }

        isRunningTerminalCommand = true
        terminalOutput += prompt(for: selectedEnvironment) + trimmed + "\n"

        do {
            let shellCommand = embeddedShellCommand(trimmed, environment: selectedEnvironment)
            let result = try await Task.detached(priority: .userInitiated) {
                try ProcessRunner.runShell(
                    shellCommand,
                    timeout: 120,
                    currentDirectoryURL: selectedEnvironment.path
                )
            }.value

            if !result.stdout.isEmpty {
                terminalOutput += result.stdout
                if !result.stdout.hasSuffix("\n") {
                    terminalOutput += "\n"
                }
            }

            if !result.stderr.isEmpty {
                terminalOutput += result.stderr
                if !result.stderr.hasSuffix("\n") {
                    terminalOutput += "\n"
                }
            }

            if result.exitCode != 0 {
                terminalOutput += "[exit \(result.exitCode)]\n"
            }
        } catch {
            terminalOutput += "\(error.localizedDescription)\n"
        }

        isRunningTerminalCommand = false
    }

    func deleteSelectedEnvironment() async {
        guard let selectedEnvironment else { return }
        do {
            try await actions.moveToTrash(selectedEnvironment)
            environments.removeAll { $0.id == selectedEnvironment.id }
            selectedEnvironmentID = environments.first?.id
            packages = []
            packageInventoryMessage = "No packages loaded"
            statusMessage = "Moved \(selectedEnvironment.name) to Trash"
            await loadSelectedPackages()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func uninstallSelectedPackage() async {
        guard let selectedEnvironment, let selectedPackage else { return }
        guard canUninstall(selectedPackage, from: selectedEnvironment) else {
            errorMessage = "This package cannot be safely uninstalled from its available metadata."
            return
        }

        do {
            let inspector = self.inspector
            try await Task.detached(priority: .userInitiated) {
                try inspector.uninstallPackage(selectedPackage, from: selectedEnvironment)
            }.value
            statusMessage = "Uninstalled \(selectedPackage.name)"
            await loadSelectedPackages()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func packageInventoryUnavailableMessage(for environment: EnvironmentRecord, error: Error) -> String {
        if environment.interpreterPath == nil {
            return "No interpreter found. Package inventory is unavailable."
        }

        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return "Package inventory unavailable."
        }

        return "Package inventory unavailable: \(message)"
    }

    func canUninstall(_ package: PackageRecord?, from environment: EnvironmentRecord?) -> Bool {
        guard let package, let environment else {
            return false
        }

        if environment.interpreterPath != nil, package.installer.lowercased() == "pip" {
            return true
        }

        guard let metadataLocation = package.metadataLocation else {
            return false
        }

        return metadataLocation.path.hasPrefix(environment.path.path + "/")
    }

    private func embeddedShellCommand(_ userCommand: String, environment: EnvironmentRecord) -> String {
        let envPath = shellQuote(environment.path.path)
        let activatePath = environment.path.appendingPathComponent("bin/activate")
        let activation: String

        if FileManager.default.fileExists(atPath: activatePath.path) {
            activation = "source \(shellQuote(activatePath.path))"
        } else {
            let binPath = shellQuote(environment.path.appendingPathComponent("bin").path)
            activation = "export VIRTUAL_ENV=\(envPath); export PATH=\(binPath):\"$PATH\""
        }

        return "cd \(envPath) && \(activation) >/dev/null 2>&1 && \(userCommand)"
    }

    private func prompt(for environment: EnvironmentRecord) -> String {
        "(\(environment.name)) % "
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
