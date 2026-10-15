import SwiftUI

/// The main menu bar dropdown view.
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        mainContent
        .frame(width: 340)
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(appState.statusText)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if let error = appState.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
            }

            if appState.isModelLoading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 12)
            }

            if ProductFlags.behavesLikeDebugBuild,
               let readAloudEngine = appState.lastReadAloudEngineDescription {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Read-aloud engine")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 8)
                    Text(readAloudEngine)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
            }

            if !appState.recentTranscriptions.isEmpty {
                Divider().padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 2)

                    ForEach(appState.recentTranscriptions, id: \.self) { text in
                        Button {
                            appState.copyToClipboard(text)
                        } label: {
                            HStack {
                                Text(text)
                                    .font(.callout)
                                    .lineLimit(2)
                                    .truncationMode(.tail)
                                Spacer()
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                }

                if appState.copiedToClipboard {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("Copied to clipboard")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .transition(.opacity)
                }
            }

            Divider().padding(.vertical, 2)

            Group {
                Button {
                    appState.readSelectedTextAloud()
                } label: {
                    HStack {
                        Label("Read Selected Text", systemImage: "speaker.wave.2")
                        Spacer()
                        Text("⌥⌘R")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                Button {
                    appState.readClipboardAloud()
                } label: {
                    HStack {
                        Label("Read Clipboard", systemImage: "doc.text")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                Button {
                    appState.toggleReadAloudPause()
                } label: {
                    HStack {
                        Label(appState.isReadAloudPaused ? "Resume Reading" : "Pause Reading", systemImage: appState.isReadAloudPaused ? "play.fill" : "pause.fill")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .disabled(!appState.isReadAloudActive)

                Button {
                    appState.stopReadAloud()
                } label: {
                    HStack {
                        Label("Stop Reading", systemImage: "speaker.slash")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .disabled(appState.isInitializingUI)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Read-aloud speed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(readAloudSpeedLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Slider(
                    value: $appState.config.readAloudRate,
                    in: AppConfig.readAloudRateRange,
                    step: 0.05
                )
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 6)

            Divider().padding(.vertical, 2)

            Button {
                openSettingsWindow()
            } label: {
                HStack {
                    Label("Open Settings...", systemImage: "gearshape")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider().padding(.vertical, 2)

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack {
                    Label("Quit Soreno", systemImage: "power")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .padding(.bottom, 4)
        }
    }

    private func openSettingsWindow() {
        appState.stopRecordingHotkey()
        DesktopAppWindowManager.shared.show(appState: appState)
    }

    private var statusColor: Color {
        if appState.isRecording {
            return .red
        } else if appState.isModelLoaded {
            return .green
        } else if appState.isModelLoading {
            return .orange
        } else {
            return .gray
        }
    }

    private var readAloudSpeedLabel: String {
        String(format: "%.2fx", appState.config.readAloudRate)
    }
}
