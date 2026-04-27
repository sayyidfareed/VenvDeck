import SwiftUI

@main
struct VenvDeckApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 1120, minHeight: 720)
                .task {
                    await viewModel.scan()
                }
        }
        .windowStyle(.titleBar)
    }
}
