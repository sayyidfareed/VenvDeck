import VenvDeckCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var showingDeleteConfirmation = false
    @State private var showingPackageConfirmation = false
    @State private var showingTerminalConsole = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 320, ideal: 360)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup {
                if viewModel.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await viewModel.scan() }
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isScanning)
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .confirmationDialog(
            "Move environment to Trash?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await viewModel.deleteSelectedEnvironment() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Uninstall selected package?",
            isPresented: $showingPackageConfirmation,
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                Task { await viewModel.uninstallSelectedPackage() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingTerminalConsole) {
            EmbeddedTerminalView()
                .environmentObject(viewModel)
                .frame(minWidth: 820, minHeight: 520)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                TextField("Search environments", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Picker("Kind", selection: $viewModel.selectedKind) {
                        Text("All").tag(EnvironmentKind?.none)
                        ForEach(EnvironmentKind.allCases) { kind in
                            Text(kind.displayName).tag(EnvironmentKind?.some(kind))
                        }
                    }
                    .labelsHidden()

                    Picker("Sort", selection: $viewModel.sortMode) {
                        ForEach(AppViewModel.SortMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                }
            }
            .padding(12)

            List(selection: $viewModel.selectedEnvironmentID) {
                ForEach(viewModel.filteredEnvironments) { environment in
                    EnvironmentRow(environment: environment)
                        .tag(environment.id)
                }
            }
            .listStyle(.sidebar)
            .onChange(of: viewModel.selectedEnvironmentID) { _ in
                Task { await viewModel.loadSelectedPackages() }
            }

            StatusBar(
                text: viewModel.isScanning ? viewModel.scanProgress.message : viewModel.statusMessage,
                count: viewModel.environments.count
            )
        }
    }

    private var detail: some View {
        Group {
            if let environment = viewModel.selectedEnvironment {
                EnvironmentDetailView(
                    environment: environment,
                    packages: viewModel.packages,
                    packageInventoryMessage: viewModel.packageInventoryMessage,
                    selectedPackageID: $viewModel.selectedPackageID,
                    totalSize: viewModel.totalSize,
                    isLoadingPackages: viewModel.isLoadingPackages,
                    reveal: viewModel.revealSelectedEnvironment,
                    openTerminal: {
                        viewModel.prepareEmbeddedTerminal()
                        showingTerminalConsole = true
                    },
                    delete: { showingDeleteConfirmation = true },
                    uninstall: { showingPackageConfirmation = true },
                    canUninstall: { package in
                        viewModel.canUninstall(package, from: environment)
                    }
                )
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("No Python environments found")
                        .font(.title3)
                    Button("Scan") {
                        Task { await viewModel.scan() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct EnvironmentRow: View {
    let environment: EnvironmentRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: iconName)
                    .foregroundStyle(color)
                Text(environment.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(EnvFormatting.bytes(environment.sizeBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                KindBadge(kind: environment.kind)
                Text(environment.pythonVersion)
                    .lineLimit(1)
                Text("\(environment.packageCount) packages")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            Text(environment.path.path)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 5)
    }

    private var iconName: String {
        switch environment.kind {
        case .conda: "shippingbox"
        case .pyenvPython: "terminal"
        case .poetry: "book"
        case .uv: "bolt"
        case .pipx: "app.badge"
        case .broken: "exclamationmark.triangle"
        default: "chevron.left.forwardslash.chevron.right"
        }
    }

    private var color: Color {
        switch environment.health {
        case .healthy: .accentColor
        case .metadataOnly: .orange
        case .missingInterpreter, .unreadable: .red
        case .unknown: .secondary
        }
    }
}

private struct EnvironmentDetailView: View {
    let environment: EnvironmentRecord
    let packages: [PackageRecord]
    let packageInventoryMessage: String
    @Binding var selectedPackageID: PackageRecord.ID?
    let totalSize: Int64
    let isLoadingPackages: Bool
    let reveal: () -> Void
    let openTerminal: () -> Void
    let delete: () -> Void
    let uninstall: () -> Void
    let canUninstall: (PackageRecord?) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(environment.name)
                            .font(.largeTitle.weight(.semibold))
                            .lineLimit(1)
                        KindBadge(kind: environment.kind)
                    }
                    Text(environment.path.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()

                HStack {
                    Button(action: reveal) {
                        Label("Reveal", systemImage: "folder")
                    }
                    Button(action: openTerminal) {
                        Label("Terminal", systemImage: "terminal")
                    }
                    .disabled(!environment.canOpenTerminal)
                    Button(role: .destructive, action: delete) {
                        Label("Trash", systemImage: "trash")
                    }
                    .disabled(!environment.canDelete)
                }
            }

            SummaryGrid(environment: environment, totalSize: totalSize)

            StorageBar(environments: [environment], totalSize: max(totalSize, environment.sizeBytes))
                .frame(height: 14)

            HStack {
                Text("Packages")
                    .font(.title2.weight(.semibold))
                Spacer()
                if isLoadingPackages {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(role: .destructive, action: uninstall) {
                    Label("Uninstall", systemImage: "minus.circle")
                }
                .disabled(!canUninstall(selectedPackage))
            }

            PackageTable(
                packages: packages,
                emptyMessage: packageInventoryMessage,
                selectedPackageID: $selectedPackageID
            )
        }
        .padding(20)
    }

    private var selectedPackage: PackageRecord? {
        guard let selectedPackageID else { return nil }
        return packages.first { $0.id == selectedPackageID }
    }
}

private struct SummaryGrid: View {
    let environment: EnvironmentRecord
    let totalSize: Int64

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                MetricCard(title: "Python", value: environment.pythonVersion, systemImage: "number")
                MetricCard(title: "Size", value: EnvFormatting.bytes(environment.sizeBytes), systemImage: "externaldrive")
                MetricCard(title: "Packages", value: "\(environment.packageCount)", systemImage: "shippingbox")
            }
            GridRow {
                MetricCard(title: "Health", value: environment.health.displayName, systemImage: "heart.text.square")
                MetricCard(title: "Manager", value: environment.manager, systemImage: "switch.2")
                MetricCard(title: "Modified", value: EnvFormatting.date(environment.lastModified), systemImage: "clock")
            }
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(title)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct PackageTable: View {
    let packages: [PackageRecord]
    let emptyMessage: String
    @Binding var selectedPackageID: PackageRecord.ID?
    @State private var sortOrder = [KeyPathComparator(\PackageRecord.name, order: .forward)]

    var body: some View {
        Group {
            if packages.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(emptyMessage.isEmpty ? "No packages loaded" : emptyMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Table(sortedPackages, selection: $selectedPackageID, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { package in
                        Text(package.name)
                            .fontWeight(package.requested == true ? .semibold : .regular)
                    }
                    TableColumn("Version", value: \.version)
                    TableColumn("Installer", value: \.installer)
                    TableColumn("Size", value: \.sizeSortValue) { package in
                        Text(package.sizeBytes.map(EnvFormatting.bytes) ?? "Unknown")
                            .foregroundStyle(package.sizeBytes == nil ? .secondary : .primary)
                    }
                    TableColumn("Source", value: \.sourceLabel) { package in
                        Text(package.sourceLabel)
                            .foregroundStyle(package.sourceLabel == "Dependency" ? .secondary : .primary)
                    }
                }
            }
        }
        .frame(minHeight: 260)
    }

    private var sortedPackages: [PackageRecord] {
        packages.sorted(using: sortOrder)
    }
}

private extension PackageRecord {
    var sizeSortValue: Int64 {
        sizeBytes ?? -1
    }

    var sourceLabel: String {
        if editable {
            return "Editable"
        }

        if directURL != nil {
            return "Direct"
        }

        if requested == true {
            return "Requested"
        }

        return "Dependency"
    }
}

private struct StorageBar: View {
    let environments: [EnvironmentRecord]
    let totalSize: Int64

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(environments.prefix(8)) { environment in
                    Rectangle()
                        .fill(color(for: environment.kind))
                        .frame(width: width(for: environment, available: geometry.size.width))
                }
                Spacer(minLength: 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private func width(for environment: EnvironmentRecord, available: CGFloat) -> CGFloat {
        guard totalSize > 0 else { return 0 }
        return max(8, available * CGFloat(Double(environment.sizeBytes) / Double(totalSize)))
    }

    private func color(for kind: EnvironmentKind) -> Color {
        switch kind {
        case .conda: .green
        case .pyenvPython: .blue
        case .poetry: .pink
        case .uv: .orange
        case .pipx: .purple
        case .broken: .red
        default: .teal
        }
    }
}

private struct KindBadge: View {
    let kind: EnvironmentKind

    var body: some View {
        Text(kind.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}

private struct StatusBar: View {
    let text: String
    let count: Int

    var body: some View {
        HStack {
            Text(text)
                .lineLimit(1)
            Spacer()
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct EmbeddedTerminalView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var command = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Terminal", systemImage: "terminal")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.openSelectedInTerminal()
                } label: {
                    Label("Open External", systemImage: "arrow.up.forward.app")
                }
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            .background(.bar)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(viewModel.terminalOutput)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(14)
                        .id("terminal-output")
                }
                .background(Color.black)
                .onChange(of: viewModel.terminalOutput) { _ in
                    proxy.scrollTo("terminal-output", anchor: .bottom)
                }
            }

            HStack(spacing: 8) {
                Text("%")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)

                TextField("Run command", text: $command)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .disabled(viewModel.isRunningTerminalCommand)
                    .onSubmit(runCommand)

                if viewModel.isRunningTerminalCommand {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Run", action: runCommand)
                    .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isRunningTerminalCommand)
            }
            .padding(12)
            .background(.bar)
        }
    }

    private func runCommand() {
        let submitted = command
        command = ""
        Task {
            await viewModel.runEmbeddedTerminalCommand(submitted)
        }
    }
}
