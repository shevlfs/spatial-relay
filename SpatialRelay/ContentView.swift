import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: RelayViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            route

            if let message = viewModel.message {
                messageView(message)
            }

            if viewModel.isRelaying {
                meter
                Label {
                    Text("Choose **Fixed** or **Head Tracked** in the macOS Sound or AirPods menu.")
                } icon: {
                    Image(systemName: "headphones")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            controls
        }
        .padding(22)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { viewModel.refresh(preservingError: true) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform.path")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Spatial Relay")
                    .font(.title3.weight(.semibold))
                Text("Spatial Audio for Spotify")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Menu {
                Button("Quit Spatial Relay", systemImage: "power") {
                    viewModel.quitApplication()
                }
                .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More options")
            .help("More options")
        }
    }

    private var route: some View {
        VStack(spacing: 0) {
            routeRow(
                icon: "music.note",
                title: "Spotify",
                detail: viewModel.spotifyDetail,
                state: viewModel.spotifyState
            )

            Divider().padding(.leading, 40)

            routeRow(
                icon: viewModel.outputSymbolName,
                title: "Output",
                detail: viewModel.outputDetail,
                state: viewModel.outputState
            )
        }
        .padding(.horizontal, 14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func routeRow(icon: String, title: String, detail: String, state: RelayViewModel.CheckState) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Image(systemName: state.symbolName)
                .foregroundStyle(state.color)
                .font(.system(size: 13, weight: .medium))
                .accessibilityLabel(state.accessibilityDescription)
        }
        .padding(.vertical, 13)
        .help(detail)
        .accessibilityElement(children: .combine)
    }

    private func messageView(_ message: RelayViewModel.Message) -> some View {
        Label {
            Text(message.text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: message.kind.symbolName)
                .foregroundStyle(message.kind.color)
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private var meter: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text("Relaying")
                    .font(.callout.weight(.medium))
                Spacer()
                Text(viewModel.latencyLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Audio queued in the app. This excludes Bluetooth and device playback latency.")
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(.tint)
                        .frame(width: proxy.size.width * viewModel.meterLevel)
                        .animation(.linear(duration: 0.12), value: viewModel.meterLevel)
                }
            }
            .frame(height: 4)
            .accessibilityLabel("Spotify audio level")
            .accessibilityValue("\(Int(viewModel.meterLevel * 100)) percent")

            if viewModel.droppedFrameCount > 0 {
                Text("\(viewModel.droppedFrameCount) frames dropped")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Button {
                viewModel.toggleRelay()
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isBusy {
                        ProgressView()
                            .controlSize(.small)
                        Text(viewModel.operationLabel)
                    } else {
                        Image(systemName: viewModel.isRelaying ? "stop.fill" : "play.fill")
                        Text(viewModel.isRelaying ? "Stop relay" : "Start relay")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 22)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canToggleRelay)
            .keyboardShortcut(.return, modifiers: [])

            if !viewModel.isRelaying {
                HStack {
                    Button("Open Spotify") { viewModel.openSpotify() }
                    Spacer()
                    Button {
                        viewModel.refresh()
                    } label: {
                        Label(viewModel.isRefreshing ? "Checking…" : "Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.isRefreshing)
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .disabled(viewModel.isBusy)

                Text("On first use, allow System Audio Recording when macOS asks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private extension RelayViewModel.CheckState {
    var symbolName: String {
        switch self {
        case .ready: "checkmark.circle"
        case .warning: "exclamationmark.circle"
        case .unavailable: "minus.circle"
        }
    }

    var color: Color {
        switch self {
        case .ready: .secondary
        case .warning: .orange
        case .unavailable: .secondary
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .ready: "Ready"
        case .warning: "Needs attention"
        case .unavailable: "Unavailable"
        }
    }
}

private extension RelayViewModel.Message.Kind {
    var symbolName: String {
        switch self {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "exclamationmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
