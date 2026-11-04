import AppKit
import SwiftUI

@MainActor
private final class SpatialRelayApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: RelayViewModel?
    private var terminationReplyIsPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel else { return .terminateNow }
        guard !viewModel.isReadyToTerminate else { return .terminateNow }

        if !terminationReplyIsPending {
            terminationReplyIsPending = true
            viewModel.prepareForTermination {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

@main
struct SpatialRelayApp: App {
    @NSApplicationDelegateAdaptor(SpatialRelayApplicationDelegate.self) private var appDelegate
    @StateObject private var viewModel: RelayViewModel

    init() {
        let viewModel = RelayViewModel()
        _viewModel = StateObject(wrappedValue: viewModel)
        appDelegate.viewModel = viewModel
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(viewModel: viewModel)
                .frame(width: 380)
        } label: {
            Image(systemName: viewModel.menuBarSymbolName)
                .symbolRenderingMode(.monochrome)
                .accessibilityLabel(viewModel.menuBarStatusText)
        }
        .menuBarExtraStyle(.window)
    }
}
