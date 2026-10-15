import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var selectedSection: SettingsSection? = .general
    @State private var selectedDictionaryEntryID: AppConfig.CustomDictionaryEntry.ID?
    @State private var selectedMemoryEntryID: AppConfig.CorrectionMemoryEntry.ID?
    @State private var selectedHistoryEntryID: AppConfig.TranscriptHistoryEntry.ID?
    @State private var isPresentingOnboarding = false
    @State private var isPresentingError = false
    @State private var presentedErrorMessage = ""
    @State private var isPresentingVoicePicker = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    SorenoLogoMark()
                        .frame(width: 20, height: 20)
                    Text("Soreno")
                        .font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)

                List(SettingsSection.allCases, selection: $selectedSection) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            detailView(for: selectedSection ?? .general)
                .frame(minWidth: 680, minHeight: 520)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    openSystemSettings(anchor: "Privacy_Accessibility")
                } label: {
                    Label("Accessibility", systemImage: "figure.wave")
                }

                Button {
                    openSystemSettings(anchor: "Privacy_Microphone")
                } label: {
                    Label("Microphone", systemImage: "mic")
                }
            }
        }
        .onChange(of: selectedSection) { _, section in
            if section != .hotkey {
                appState.stopRecordingHotkey()
            }
        }
        .onAppear {
            if appState.shouldShowFirstLaunchOnboarding {
                isPresentingOnboarding = true
            }
        }
        .sheet(isPresented: $isPresentingOnboarding, onDismiss: {
            appState.completeFirstLaunchOnboarding()
        }) {
            FirstLaunchOnboardingView(isPresented: $isPresentingOnboarding)
                .environmentObject(appState)
        }
        .sheet(isPresented: $isPresentingVoicePicker, onDismiss: {
            appState.stopReadAloud()
        }) {
            ReadAloudVoicePickerSheet(
                selectedVoiceIdentifier: $appState.config.readAloudVoiceIdentifier,
                availableVoices: availableReadAloudVoices
            )
            .environmentObject(appState)
        }
        .alert("Settings Error", isPresented: $isPresentingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(presentedErrorMessage)
        }
    }

    @ViewBuilder
    private func detailView(for section: SettingsSection) -> some View {
        VStack(spacing: 0) {
            if appState.isInitializingUI {
                initializationBanner
            }

            switch section {
            case .general:
                generalSettingsView
            case .language:
                languageSettingsView
            case .hotkey:
                hotkeySettingsView
            case .history:
                historySettingsView
            case .profile:
                profileSettingsView
            case .dictionary:
                dictionarySettingsView
            case .memory:
                correctionMemorySettingsView
            }
        }
    }

    private var initializationBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text("Soreno is initializing")
                    .font(.headline)
                Text("Speech-to-text is still loading. Menu actions stay disabled until startup completes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.thinMaterial)
    }

    private var generalSettingsView: some View {
        Form {
            Section("Features") {
                Toggle("Open desktop app on launch", isOn: $appState.config.openDesktopAppOnLaunch)
            }

            Section("Read Aloud") {
                Button {
                    isPresentingVoicePicker = true
                } label: {
                    HStack {
                        Text("Voice")
                        Spacer()
                        Text(currentReadAloudVoiceLabel)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Speed")
                        Spacer()
                        Text(readAloudSpeedLabel)
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: $appState.config.readAloudRate,
                        in: AppConfig.readAloudRateRange,
                        step: 0.05
                    )
                }

                Text(readAloudVoiceHelpText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if ProductFlags.showsSmartPostProcessingControls || ProductFlags.showsLanguageUI {
                Section("Feature Quality") {
                    if ProductFlags.showsSmartPostProcessingControls {
                        Picker("Post-processing quality", selection: $appState.config.postProcessingModel) {
                            ForEach(AppConfig.PostProcessingModel.allCases) { model in
                                Text("\(model.displayName) (\(model.footprint))").tag(model)
                            }
                        }
                        .disabled(!appState.config.isSmartPostProcessingEnabled)
                    }

                    if ProductFlags.showsLanguageUI {
                        Picker("Multi-language speech-to-text quality", selection: $appState.config.whisperModel) {
                            ForEach(AppConfig.WhisperModel.allCases) { model in
                                Text("\(model.displayName) (\(model.footprint))").tag(model)
                            }
                        }
                        .disabled(!appState.config.isMultiLanguageSTTEnabled)
                    }
                }
            }

            if !visibleModelDescriptors.isEmpty {
                Section("Feature Install State") {
                    ForEach(visibleModelDescriptors, id: \.key) { descriptor in
                        modelStateRow(for: descriptor)
                    }
                }
            }

            if !visibleModelDescriptors.isEmpty {
                Section {
                    Text("Optional components download automatically when enabled. Soreno manages installation in the background.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    private var languageSettingsView: some View {
        Form {
            Section("Transcription") {
                Picker("Active language", selection: $appState.config.activeLanguage) {
                    ForEach(AppConfig.AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }

                HStack {
                    Text("Active speech-to-text mode")
                    Spacer()
                    Text(appState.config.activeLanguage.engineDescription)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Notes") {
                Text(languageNotes)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Language")
    }

    private var hotkeySettingsView: some View {
        Form {
            Section("Recording Mode") {
                Picker("Mode", selection: $appState.config.mode) {
                    ForEach(AppConfig.RecordingMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(modeDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Hotkey") {
                Button {
                    if appState.isRecordingHotkey {
                        appState.stopRecordingHotkey()
                    } else {
                        appState.startRecordingHotkey()
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appState.isRecordingHotkey ? "Press any key..." : appState.config.hotkey.displayName)
                            Text(appState.isRecordingHotkey ? "Recording input" : "Current shortcut")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: appState.isRecordingHotkey ? "keyboard.badge.ellipsis" : "keyboard")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)

                Text("Soreno captures the key directly through Input Monitoring for reliable push-to-talk behavior.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Hotkey")
    }

    private var profileSettingsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System Prompt / User Profile")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Describe your background, domain, and preferred writing style so post-processing can make better corrections.")
                .foregroundStyle(.secondary)

            TextEditor(text: $appState.config.userProfilePrompt)
                .font(.body)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

            HStack {
                Spacer()
                Button("Reset to Default") {
                    appState.config.userProfilePrompt = AppConfig.defaultUserProfilePrompt
                }
            }
        }
        .padding(20)
        .navigationTitle("Profile")
    }

    private var dictionarySettingsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Dictionary")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Add words and names that should always be corrected consistently.")
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    addDictionaryEntry()
                } label: {
                    Label("Add", systemImage: "plus")
                }

                Button(role: .destructive) {
                    removeSelectedDictionaryEntry()
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .disabled(selectedDictionaryEntryID == nil)

                Button {
                    importDictionaryJSON()
                } label: {
                    Label("Import JSON", systemImage: "square.and.arrow.down")
                }

                Button {
                    exportDictionaryJSON()
                } label: {
                    Label("Export JSON", systemImage: "square.and.arrow.up")
                }
                .disabled(appState.config.customDictionaryEntries.isEmpty)

                Spacer()

                Text("\(appState.config.customDictionaryEntries.count) entries")
                    .foregroundStyle(.secondary)
            }

            Table(appState.config.customDictionaryEntries, selection: $selectedDictionaryEntryID) {
                TableColumn("Spoken") { entry in
                    Text(entry.spoken)
                        .lineLimit(1)
                }
                TableColumn("Correction") { entry in
                    Text(entry.correction)
                        .lineLimit(1)
                }
                TableColumn("Notes") { entry in
                    Text(entry.notes)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 220)

            GroupBox("Selected Entry") {
                if selectedDictionaryEntryID == nil {
                    ContentUnavailableView("No Entry Selected", systemImage: "text.book.closed", description: Text("Select a row to edit it."))
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Spoken", text: dictionaryBinding(\.spoken))
                        TextField("Correction", text: dictionaryBinding(\.correction))
                        TextField("Notes", text: dictionaryBinding(\.notes))
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(20)
        .navigationTitle("Custom Dictionary")
    }

    private var correctionMemorySettingsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Correction Memory")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Manage learned corrections gathered over time.")
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    addCorrectionMemoryEntry()
                } label: {
                    Label("Add", systemImage: "plus")
                }

                Button(role: .destructive) {
                    removeSelectedCorrectionMemoryEntry()
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .disabled(selectedMemoryEntryID == nil)

                Button {
                    importCorrectionMemoryJSON()
                } label: {
                    Label("Import JSON", systemImage: "square.and.arrow.down")
                }

                Button {
                    exportCorrectionMemoryJSON()
                } label: {
                    Label("Export JSON", systemImage: "square.and.arrow.up")
                }
                .disabled(appState.config.correctionMemoryEntries.isEmpty)

                Button(role: .destructive) {
                    appState.config.correctionMemoryEntries.removeAll()
                    selectedMemoryEntryID = nil
                } label: {
                    Label("Clear All", systemImage: "xmark.bin")
                }
                .disabled(appState.config.correctionMemoryEntries.isEmpty)

                Spacer()

                Text("\(appState.config.correctionMemoryEntries.count) entries")
                    .foregroundStyle(.secondary)
            }

            Table(appState.config.correctionMemoryEntries, selection: $selectedMemoryEntryID) {
                TableColumn("Misrecognized") { entry in
                    Text(entry.misrecognized)
                        .lineLimit(1)
                }
                TableColumn("Corrected") { entry in
                    Text(entry.corrected)
                        .lineLimit(1)
                }
                TableColumn("Context") { entry in
                    Text(entry.context)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                TableColumn("Uses") { entry in
                    Text("\(entry.usageCount)")
                }
            }
            .frame(minHeight: 220)

            GroupBox("Selected Entry") {
                if selectedMemoryEntryID == nil {
                    ContentUnavailableView("No Entry Selected", systemImage: "brain", description: Text("Select a row to edit it."))
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Misrecognized", text: memoryBinding(\.misrecognized))
                        TextField("Corrected", text: memoryBinding(\.corrected))
                        TextField("Context", text: memoryBinding(\.context))

                        Stepper("Usage count: \(memoryUsageCountBinding.wrappedValue)", value: memoryUsageCountBinding, in: 1...10_000)

                        DatePicker("Last updated", selection: memoryLastUpdatedBinding, displayedComponents: [.date])
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(20)
        .navigationTitle("Correction Memory")
    }

    private var historySettingsView: some View {
        let entries = appState.paragraphHistory

        return VStack(alignment: .leading, spacing: 12) {
            Text("Transcript History")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Soreno keeps up to 20 recent transcript paragraphs. Select any row to view the full text.")
                .foregroundStyle(.secondary)

            HStack {
                Text("\(entries.count) saved")
                    .foregroundStyle(.secondary)

                Spacer()

                Button(role: .destructive) {
                    appState.clearParagraphHistory()
                    selectedHistoryEntryID = nil
                } label: {
                    Label("Clear History", systemImage: "trash")
                }
                .disabled(entries.isEmpty)
            }

            HStack(alignment: .top, spacing: 12) {
                List(selection: $selectedHistoryEntryID) {
                    ForEach(entries) { entry in
                        Text(entry.finalText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .tag(entry.id)
                    }
                }
                .frame(minWidth: 280, minHeight: 260)

                GroupBox("Full Paragraph") {
                    ScrollView {
                        if let selectedEntry = selectedHistoryEntry(entries: entries) {
                            historyDetailView(for: selectedEntry)
                        } else {
                            Text("Select a history row to open the full paragraph.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .navigationTitle("History")
        .onChange(of: entries.count) { _, _ in
            if let selectedHistoryEntryID,
               !entries.contains(where: { $0.id == selectedHistoryEntryID }) {
                self.selectedHistoryEntryID = nil
            }
        }
    }

    @ViewBuilder
    private func historyDetailView(for entry: AppConfig.TranscriptHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if ProductFlags.behavesLikeDebugBuild && entry.postProcessingEnabled {
                GroupBox("Original Transcription") {
                    Text((entry.originalText?.isEmpty == false ? entry.originalText : entry.finalText) ?? entry.finalText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }

                GroupBox("After Post-Processing") {
                    Text(entry.finalText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }
            } else {
                GroupBox("Final Text") {
                    Text(entry.finalText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private func selectedHistoryEntry(entries: [AppConfig.TranscriptHistoryEntry]) -> AppConfig.TranscriptHistoryEntry? {
        guard let selectedHistoryEntryID else {
            return nil
        }

        return entries.first { $0.id == selectedHistoryEntryID }
    }

    private var modeDescription: String {
        switch appState.config.mode {
        case .pushToTalk:
            return "Hold the hotkey to record, release to stop."
        case .toggleMute:
            return "Press once to start and press again to stop."
        }
    }

    private var languageNotes: String {
        if appState.config.activeLanguage == .english {
            return "English uses the dedicated English speech-to-text model."
        }

        return "When multi-language speech-to-text is enabled, non-English languages use the shared multi-language model and pause the English-only model while active."
    }

    private var availableReadAloudVoices: [AVSpeechSynthesisVoice] {
        TextToSpeechService.appleVoices(for: appState.config.effectiveSpeechLanguage)
    }

    private var currentReadAloudVoiceLabel: String {
        readAloudVoiceName(for: appState.config.readAloudVoiceIdentifier)
    }

    private var readAloudSpeedLabel: String {
        String(format: "%.2fx", appState.config.readAloudRate)
    }

    private var readAloudVoiceHelpText: String {
        "Aaron is the default. Recommended voices appear first, and novelty voices are separated out."
    }

    private func readAloudVoiceLabel(for voice: AVSpeechSynthesisVoice) -> String {
        if voice.language.isEmpty {
            return voice.name
        }

        return "\(voice.name) (\(voice.language))"
    }

    private func readAloudVoiceName(for identifier: String) -> String {
        if identifier == AppConfig.enhancedReadAloudVoiceIdentifier {
            return "Aaron"
        }

        if identifier == AppConfig.systemDefaultReadAloudVoiceIdentifier {
            return "Aaron"
        }

        guard let voice = availableReadAloudVoices.first(where: { $0.identifier == identifier }) ??
                AVSpeechSynthesisVoice(identifier: identifier) else {
            return "Aaron"
        }

        return readAloudVoiceLabel(for: voice)
    }

    private func addDictionaryEntry() {
        let entry = AppConfig.CustomDictionaryEntry(spoken: "", correction: "")
        appState.config.customDictionaryEntries.append(entry)
        selectedDictionaryEntryID = entry.id
    }

    private func removeSelectedDictionaryEntry() {
        guard let id = selectedDictionaryEntryID else {
            return
        }

        appState.config.customDictionaryEntries.removeAll { $0.id == id }
        selectedDictionaryEntryID = nil
    }

    private func addCorrectionMemoryEntry() {
        let entry = AppConfig.CorrectionMemoryEntry(misrecognized: "", corrected: "")
        appState.config.correctionMemoryEntries.append(entry)
        selectedMemoryEntryID = entry.id
    }

    private func removeSelectedCorrectionMemoryEntry() {
        guard let id = selectedMemoryEntryID else {
            return
        }

        appState.config.correctionMemoryEntries.removeAll { $0.id == id }
        selectedMemoryEntryID = nil
    }

    private func dictionaryBinding(_ keyPath: WritableKeyPath<AppConfig.CustomDictionaryEntry, String>) -> Binding<String> {
        Binding {
            guard let index = selectedDictionaryIndex else {
                return ""
            }

            return appState.config.customDictionaryEntries[index][keyPath: keyPath]
        } set: { newValue in
            guard let index = selectedDictionaryIndex else {
                return
            }

            appState.config.customDictionaryEntries[index][keyPath: keyPath] = newValue
        }
    }

    private func memoryBinding(_ keyPath: WritableKeyPath<AppConfig.CorrectionMemoryEntry, String>) -> Binding<String> {
        Binding {
            guard let index = selectedMemoryIndex else {
                return ""
            }

            return appState.config.correctionMemoryEntries[index][keyPath: keyPath]
        } set: { newValue in
            guard let index = selectedMemoryIndex else {
                return
            }

            appState.config.correctionMemoryEntries[index][keyPath: keyPath] = newValue
            appState.config.correctionMemoryEntries[index].lastUpdated = .now
        }
    }

    private var memoryUsageCountBinding: Binding<Int> {
        Binding {
            guard let index = selectedMemoryIndex else {
                return 1
            }

            return appState.config.correctionMemoryEntries[index].usageCount
        } set: { newValue in
            guard let index = selectedMemoryIndex else {
                return
            }

            appState.config.correctionMemoryEntries[index].usageCount = max(1, newValue)
            appState.config.correctionMemoryEntries[index].lastUpdated = .now
        }
    }

    private var memoryLastUpdatedBinding: Binding<Date> {
        Binding {
            guard let index = selectedMemoryIndex else {
                return .now
            }

            return appState.config.correctionMemoryEntries[index].lastUpdated
        } set: { newValue in
            guard let index = selectedMemoryIndex else {
                return
            }

            appState.config.correctionMemoryEntries[index].lastUpdated = newValue
        }
    }

    private var selectedDictionaryIndex: Int? {
        guard let selectedDictionaryEntryID else {
            return nil
        }

        return appState.config.customDictionaryEntries.firstIndex { $0.id == selectedDictionaryEntryID }
    }

    private var selectedMemoryIndex: Int? {
        guard let selectedMemoryEntryID else {
            return nil
        }

        return appState.config.correctionMemoryEntries.firstIndex { $0.id == selectedMemoryEntryID }
    }

    private var visibleModelDescriptors: [SorenoModelDescriptor] {
        appState.modelFeatureManager.modelDescriptors.filter { !$0.isRequired }
    }

    @ViewBuilder
    private func modelStateRow(for descriptor: SorenoModelDescriptor) -> some View {
        let state = appState.modelFeatureManager.state(for: descriptor.key)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.title)
                    Text(modelStatusText(state, descriptor: descriptor))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if case let .installing(progress, _) = state.phase {
                    ProgressView(value: progress)
                        .frame(width: 120)
                }
            }
        }
    }

    private func isModelInstallBusy(_ phase: ModelProvisionPhase) -> Bool {
        if case .installing = phase {
            return true
        }
        return false
    }

    private func modelStatusText(_ state: ModelProvisionState, descriptor: SorenoModelDescriptor) -> String {
        if state.isInstalled {
            if case .installing(_, let detail) = state.phase {
                return "Installed · \(detail)"
            }
            return "Installed · \(ByteCountFormatter.string(fromByteCount: state.installedBytes, countStyle: .file))"
        }

        switch state.phase {
        case .idle:
            return "Not installed · \(descriptor.downloadSizeLabel)"
        case .installing(_, let detail):
            return detail
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    private func importDictionaryJSON() {
        do {
            let url = try openJSONFileForImport()
            let data = try Data(contentsOf: url)
            let imported = try JSONDecoder.soreno.decode([AppConfig.CustomDictionaryEntry].self, from: data)
            appState.config.customDictionaryEntries = imported
            selectedDictionaryEntryID = imported.first?.id
        } catch {
            presentSettingsError("Dictionary import failed: \(error.localizedDescription)")
        }
    }

    private func exportDictionaryJSON() {
        do {
            let data = try JSONEncoder.prettyPrinted.encode(appState.config.customDictionaryEntries)
            let url = try saveJSONFile(defaultName: "soreno-custom-dictionary.json")
            try data.write(to: url, options: .atomic)
        } catch {
            presentSettingsError("Dictionary export failed: \(error.localizedDescription)")
        }
    }

    private func importCorrectionMemoryJSON() {
        do {
            let url = try openJSONFileForImport()
            let data = try Data(contentsOf: url)
            let imported = try JSONDecoder.soreno.decode([AppConfig.CorrectionMemoryEntry].self, from: data)
            appState.config.correctionMemoryEntries = imported
            selectedMemoryEntryID = imported.first?.id
        } catch {
            presentSettingsError("Correction memory import failed: \(error.localizedDescription)")
        }
    }

    private func exportCorrectionMemoryJSON() {
        do {
            let data = try JSONEncoder.prettyPrinted.encode(appState.config.correctionMemoryEntries)
            let url = try saveJSONFile(defaultName: "soreno-correction-memory.json")
            try data.write(to: url, options: .atomic)
        } catch {
            presentSettingsError("Correction memory export failed: \(error.localizedDescription)")
        }
    }

    private func openJSONFileForImport() throws -> URL {
        bringAppToFrontForSystemDialog()

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            throw CocoaError(.userCancelled)
        }
        return url
    }

    private func saveJSONFile(defaultName: String) throws -> URL {
        bringAppToFrontForSystemDialog()

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = defaultName

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            throw CocoaError(.userCancelled)
        }
        return url
    }

    private func presentSettingsError(_ message: String) {
        presentedErrorMessage = message
        isPresentingError = true
    }

    private func openSystemSettings(anchor: String) {
        bringAppToFrontForSystemDialog()

        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func bringAppToFrontForSystemDialog() {
        NSApp.activate(ignoringOtherApps: true)
        if let keyWindow = NSApp.keyWindow {
            keyWindow.makeKeyAndOrderFront(nil)
        } else if let anyWindow = NSApp.windows.first(where: { $0.isVisible }) {
            anyWindow.makeKeyAndOrderFront(nil)
        }
    }
}

private enum SettingsSection: String, Identifiable {
    case general
    case language
    case hotkey
    case history
    case profile
    case dictionary
    case memory

    var id: String { rawValue }

    static var allCases: [SettingsSection] {
        var sections: [SettingsSection] = [.general, .hotkey, .history]

        if ProductFlags.showsLanguageUI {
            sections.insert(.language, at: 1)
        }

        if ProductFlags.showsAdvancedPostProcessingEditors {
            sections.append(contentsOf: [.profile, .dictionary, .memory])
        }

        return sections
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .language: return "Language"
        case .hotkey: return "Hotkey"
        case .history: return "History"
        case .profile: return "Profile"
        case .dictionary: return "Custom Dictionary"
        case .memory: return "Correction Memory"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "switch.2"
        case .language: return "globe"
        case .hotkey: return "keyboard"
        case .history: return "text.badge.clock"
        case .profile: return "person.crop.rectangle"
        case .dictionary: return "text.book.closed"
        case .memory: return "brain"
        }
    }
}

private struct ReadAloudVoicePickerSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @Binding var selectedVoiceIdentifier: String

    let availableVoices: [AVSpeechSynthesisVoice]

    @State private var draftVoiceIdentifier: String

    init(
        selectedVoiceIdentifier: Binding<String>,
        availableVoices: [AVSpeechSynthesisVoice]
    ) {
        self._selectedVoiceIdentifier = selectedVoiceIdentifier
        self.availableVoices = availableVoices
        self._draftVoiceIdentifier = State(initialValue: selectedVoiceIdentifier.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    Section {
                        Text("Select a voice to hear a preview, then confirm it when you are happy with the result.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Section("Soreno Default") {
                        if let aaronVoice {
                            voiceRow(
                                identifier: aaronVoice.identifier,
                                title: aaronVoice.name,
                                subtitle: "Default voice"
                            )
                        }
                    }

                    if !recommendedVoices.isEmpty {
                        Section("Recommended") {
                            ForEach(recommendedVoices, id: \.identifier) { voice in
                                voiceRow(
                                    identifier: voice.identifier,
                                    title: voice.name,
                                    subtitle: voiceMetadataLabel(for: voice)
                                )
                            }
                        }
                    }

                    if !standardVoices.isEmpty {
                        Section("More Voices") {
                            ForEach(standardVoices, id: \.identifier) { voice in
                                voiceRow(
                                    identifier: voice.identifier,
                                    title: voice.name,
                                    subtitle: voiceMetadataLabel(for: voice)
                                )
                            }
                        }
                    }

                    if !personalVoices.isEmpty {
                        Section("Personal") {
                            ForEach(personalVoices, id: \.identifier) { voice in
                                voiceRow(
                                    identifier: voice.identifier,
                                    title: voice.name,
                                    subtitle: voiceMetadataLabel(for: voice)
                                )
                            }
                        }
                    }

                    if !noveltyVoices.isEmpty {
                        Section("Novelty") {
                            ForEach(noveltyVoices, id: \.identifier) { voice in
                                voiceRow(
                                    identifier: voice.identifier,
                                    title: voice.name,
                                    subtitle: voiceMetadataLabel(for: voice)
                                )
                            }
                        }
                    }
                }

                Divider()
                voicePickerFooter
            }
            .navigationTitle("Choose Voice")
            .frame(minWidth: 560, minHeight: 520)
            .onAppear {
                previewSelectedVoice()
            }
            .onChange(of: draftVoiceIdentifier) { _, _ in
                previewSelectedVoice()
            }
            .onDisappear {
                appState.stopReadAloud()
            }
        }
    }

    private var voicePickerFooter: some View {
        HStack(spacing: 10) {
            Button("Cancel") {
                appState.stopReadAloud()
                dismiss()
            }

            Spacer()

            Button("Replay") {
                previewSelectedVoice()
            }

            Button("Confirm") {
                applySelection()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder
    private func voiceRow(identifier: String, title: String, subtitle: String) -> some View {
        Button {
            draftVoiceIdentifier = identifier
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if draftVoiceIdentifier == identifier {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func previewSelectedVoice() {
        appState.previewReadAloudVoice(draftVoiceIdentifier)
    }

    private func applySelection() {
        selectedVoiceIdentifier = draftVoiceIdentifier
        appState.stopReadAloud()
        dismiss()
    }

    private var aaronVoice: AVSpeechSynthesisVoice? {
        availableVoices.first(where: { $0.identifier == AppConfig.aaronReadAloudVoiceIdentifier }) ??
        AVSpeechSynthesisVoice(identifier: AppConfig.aaronReadAloudVoiceIdentifier)
    }

    private var recommendedVoices: [AVSpeechSynthesisVoice] {
        availableVoices.filter { voice in
            voice.identifier != AppConfig.aaronReadAloudVoiceIdentifier &&
            !isNoveltyVoice(voice) &&
            !isPersonalVoice(voice) &&
            isHighQualityVoice(voice)
        }
    }

    private var standardVoices: [AVSpeechSynthesisVoice] {
        availableVoices.filter { voice in
            voice.identifier != AppConfig.aaronReadAloudVoiceIdentifier &&
            !isNoveltyVoice(voice) &&
            !isPersonalVoice(voice) &&
            !isHighQualityVoice(voice)
        }
    }

    private var personalVoices: [AVSpeechSynthesisVoice] {
        availableVoices.filter(isPersonalVoice)
    }

    private var noveltyVoices: [AVSpeechSynthesisVoice] {
        availableVoices.filter(isNoveltyVoice)
    }

    private func isHighQualityVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        voice.quality == .enhanced || voice.quality == .premium || voice.identifier == AVSpeechSynthesisVoiceIdentifierAlex
    }

    private func isNoveltyVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        voice.voiceTraits.contains(.isNoveltyVoice)
    }

    private func isPersonalVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        voice.voiceTraits.contains(.isPersonalVoice)
    }

    private func voiceMetadataLabel(for voice: AVSpeechSynthesisVoice) -> String {
        let qualityLabel: String
        switch voice.quality {
        case .premium:
            qualityLabel = "Premium"
        case .enhanced:
            qualityLabel = "Enhanced"
        default:
            qualityLabel = "Standard"
        }

        return "\(voice.language) • \(qualityLabel)"
    }
}

private struct FirstLaunchOnboardingView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                SorenoLogoMark()
                    .frame(width: 46, height: 42)

                Text("Welcome to Soreno")
                    .font(.largeTitle)
                    .fontWeight(.semibold)
            }

            Text("English dictation is ready. Read-aloud opens with Aaron by default, with grouped voices for browsing.")
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Continue") {
                    appState.completeFirstLaunchOnboarding()
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var soreno: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
