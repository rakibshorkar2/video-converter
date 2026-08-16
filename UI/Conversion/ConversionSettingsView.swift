import SwiftUI

struct ConversionSettingsView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @Bindable var job: ConversionJob

    @State private var configuration: ConversionConfiguration
    @State private var destination: OutputDestination
    @State private var preset: ConversionPreset
    @State private var sourceMetadata: MediaMetadata?
    @State private var showingFolderPicker = false
    @State private var analyzeFailed = false

    init(job: ConversionJob) {
        self.job = job
        _configuration = State(initialValue: job.configuration)
        _destination = State(initialValue: job.destination)
        _preset = State(initialValue: Self.initialPreset(for: job.configuration))
    }

    var body: some View {
        NavigationStack {
            Form {
                headerSection
                presetSection
                outputSection
                qualitySection
                audioSection
                destinationSection
                advancedSection
                if let message = compatibilityMessage {
                    Section {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if showHDRWarning {
                    Section {
                        Text(L10n.hdrWarning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let metadata = sourceMetadata {
                    Section {
                        InfoRow(title: L10n.estimatedSizeRow, value: estimateText(for: metadata))
                    }
                }
            }
            .navigationTitle(L10n.settingsSheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.closeButton) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(job.canConfigure ? L10n.startConversion : L10n.updateJob) {
                        saveAndStart()
                    }
                    .disabled(compatibilityMessage != nil || analyzeFailed)
                }
            }
            .task { await loadMetadata() }
            .sheet(isPresented: $showingFolderPicker) {
                FolderPicker { url in
                    saveFolder(url)
                    showingFolderPicker = false
                } onCancel: {
                    showingFolderPicker = false
                }
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            HStack(spacing: 12) {
                ThumbnailView(url: job.sourceURL)
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.sourceName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let metadata = sourceMetadata {
                        Text("\(metadata.durationString) · \(metadata.resolutionString) · \(metadata.fileSizeString)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var presetSection: some View {
        Section(L10n.presetRow) {
            Picker(L10n.presetRow, selection: presetBinding) {
                ForEach(ConversionPreset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.menu)
            if configuration.streamCopy {
                Text(L10n.losslessExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var outputSection: some View {
        Section(L10n.outputSection) {
            PickerRow(
                title: L10n.formatRow,
                selection: $configuration.outputContainer,
                options: FormatCapabilities.availableOutputContainers().map { ($0.displayName, $0) }
            )
            PickerRow(
                title: L10n.videoCodecRow,
                selection: $configuration.videoCodec,
                options: availableVideoCodecs.map { ($0.displayName, $0) },
                disabled: configuration.streamCopy
            )
            PickerRow(
                title: L10n.audioCodecRow,
                selection: $configuration.audioCodec,
                options: availableAudioCodecs.map { ($0.displayName, $0) },
                disabled: configuration.streamCopy
            )
        }
    }

    private var qualitySection: some View {
        Section(L10n.qualitySection) {
            if !configuration.streamCopy {
                HStack {
                    Text(L10n.qualitySlider)
                    Spacer()
                    Text("\(Int((configuration.qualityFactor * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                    Slider(value: $configuration.qualityFactor, in: 0.1...1.0, step: 0.05)
                        .frame(width: 160)
                }
                HStack {
                    Text(L10n.bitrateOverride)
                    Spacer()
                    Menu {
                        Button(L10n.bitrateAuto) { configuration.videoBitrateOverrideMbps = nil }
                        ForEach([2.0, 4.0, 6.0, 8.0, 12.0, 16.0, 24.0, 40.0], id: \.self) { value in
                            Button(String(format: "%g Mbps", value)) { configuration.videoBitrateOverrideMbps = value }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(configuration.videoBitrateOverrideMbps.map { String(format: "%g Mbps", $0) } ?? L10n.bitrateAuto)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } else {
                Text(L10n.streamCopyDisabledNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            PickerRow(
                title: L10n.resolutionRow,
                selection: $configuration.resolution,
                options: ResolutionOption.allCases.filter { $0 != .custom }.map { ($0.displayName, $0) },
                disabled: configuration.streamCopy
            )
            PickerRow(
                title: L10n.frameRateRow,
                selection: $configuration.frameRate,
                options: FrameRateOption.allCases.map { ($0.displayName, $0) },
                disabled: configuration.streamCopy
            )
        }
    }

    private var audioSection: some View {
        Section(L10n.audioSection) {
            if configuration.audioCodec != .copy && configuration.audioCodec != .none && !configuration.streamCopy {
                HStack {
                    Text(L10n.audioBitrateRow)
                    Spacer()
                    Menu {
                        ForEach([64_000, 96_000, 128_000, 160_000, 192_000, 256_000, 320_000], id: \.self) { value in
                            Button(String(format: L10n.bitrateKbpsFormat, value / 1000)) { configuration.audioBitrate = value }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(String(format: L10n.bitrateKbpsFormat, configuration.audioBitrate / 1000))
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                HStack {
                    Text(L10n.audioSampleRateRow)
                    Spacer()
                    Menu {
                        Button(String(format: L10n.sampleRateFormat, 44_100)) { configuration.audioSampleRate = 44_100 }
                        Button(String(format: L10n.sampleRateFormat, 48_000)) { configuration.audioSampleRate = 48_000 }
                    } label: {
                        HStack(spacing: 4) {
                            Text(String(format: L10n.sampleRateFormat, configuration.audioSampleRate))
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                HStack {
                    Text(L10n.audioChannelsRow)
                    Spacer()
                    Menu {
                        Button("Mono") { configuration.audioChannels = 1 }
                        Button("Stereo") { configuration.audioChannels = 2 }
                    } label: {
                        HStack(spacing: 4) {
                            Text(configuration.audioChannels == 1 ? "Mono" : "Stereo")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            PickerRow(
                title: L10n.audioTracksRow,
                selection: $configuration.audioTrackSelection,
                options: AudioTrackSelection.allCases.map { ($0.displayName, $0) },
                disabled: configuration.streamCopy
            )
        }
    }

    private var destinationSection: some View {
        Section(L10n.destinationSection) {
            Picker(L10n.defaultDestinationRow, selection: $destination) {
                Text(L10n.destinationPhotos).tag(OutputDestination.photos)
                Text(L10n.destinationFiles).tag(OutputDestination.filesDocuments)
                if container.settings.customFolderBookmark != nil || destination == .filesCustom {
                    Text(L10n.destinationCustomFolder).tag(OutputDestination.filesCustom)
                }
            }
            .pickerStyle(.segmented)

            if destination == .filesCustom {
                Button {
                    showingFolderPicker = true
                } label: {
                    HStack {
                        Text(container.settings.customFolderName.map { "\(L10n.changeFolder) · \($0)" } ?? L10n.chooseFolder)
                        Spacer()
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var advancedSection: some View {
        Section(L10n.advancedSection) {
            Toggle(L10n.hardwareAccelerationRow, isOn: $configuration.hardwareAcceleration)
            Toggle(L10n.preserveMetadataRow, isOn: $configuration.preserveMetadata)
            Toggle(L10n.preserveHDRRow, isOn: $configuration.preserveHDR)
            PickerRow(
                title: L10n.enginePreferenceRow,
                selection: $configuration.enginePreference,
                options: enginePreferenceOptions
            )
            TextField(L10n.filenamePlaceholder, text: customFilenameBinding)
                .autocorrectionDisabled()
        }
    }

    // MARK: - Helpers

    private var presetBinding: Binding<ConversionPreset> {
        Binding(
            get: { preset },
            set: { newValue in
                preset = newValue
                if newValue != .custom {
                    applyPreset(newValue)
                }
            }
        )
    }

    private var customFilenameBinding: Binding<String> {
        Binding(
            get: { configuration.customFilename ?? "" },
            set: { configuration.customFilename = $0.isEmpty ? nil : $0 }
        )
    }

    private var availableVideoCodecs: [VideoCodecOption] {
        VideoCodecOption.allCases.filter { FormatCapabilities.videoCodecAvailable($0) }
    }

    private var availableAudioCodecs: [AudioCodecOption] {
        AudioCodecOption.allCases.filter { FormatCapabilities.audioCodecAvailable($0) }
    }

    private var enginePreferenceOptions: [(String, EnginePreference)] {
        var options: [(String, EnginePreference)] = [(L10n.engineAuto, .auto), (L10n.engineVideoToolbox, .videoToolbox)]
        if FormatCapabilities.isFFmpegEnabled {
            options.append((L10n.engineFFmpeg, .ffmpeg))
        }
        return options
    }

    private var compatibilityMessage: String? {
        guard let metadata = sourceMetadata else { return nil }
        if configuration.streamCopy {
            guard FormatCapabilities.canStreamCopy(source: metadata, to: configuration.outputContainer) else {
                return String(format: L10n.errorStreamCopyIncompatible, configuration.outputContainer.displayName)
            }
            return nil
        }
        if !FormatCapabilities.containerSupportsVideoCodec(configuration.outputContainer, codec: configuration.videoCodec) {
            return String(format: L10n.errorUnsupportedCombination, "\(configuration.outputContainer.displayName) + \(configuration.videoCodec.displayName)")
        }
        if !FormatCapabilities.containerSupportsAudioCodec(configuration.outputContainer, codec: configuration.audioCodec) {
            return String(format: L10n.errorUnsupportedCombination, "\(configuration.outputContainer.displayName) + \(configuration.audioCodec.displayName)")
        }
        if !FormatCapabilities.videoCodecEncodable(configuration.videoCodec) {
            return L10n.requiresFFmpegNote
        }
        if !FormatCapabilities.audioCodecEncodable(configuration.audioCodec) {
            return L10n.requiresFFmpegNote
        }
        return nil
    }

    private var showHDRWarning: Bool {
        configuration.preserveHDR &&
        sourceMetadata?.videoTrack?.isHDR == true &&
        configuration.videoCodec != .hevc &&
        !configuration.streamCopy
    }

    private func estimateText(for metadata: MediaMetadata) -> String {
        ByteFormatter.string(from: SizeEstimator.estimatedOutputBytes(config: configuration, source: metadata))
    }

    private func applyPreset(_ preset: ConversionPreset) {
        let sourceCodec: VideoCodecOption = sourceMetadata?.videoTrack?.isHEVC == true ? .hevc : .h264
        var config = ConversionConfiguration.preset(preset, sourceCodec: sourceCodec)
        config.outputContainer = configuration.outputContainer
        config.preserveMetadata = configuration.preserveMetadata
        config.preserveHDR = configuration.preserveHDR
        config.hardwareAcceleration = configuration.hardwareAcceleration
        config.enginePreference = configuration.enginePreference
        configuration = config
    }

    private static func initialPreset(for config: ConversionConfiguration) -> ConversionPreset {
        if config.streamCopy { return .lossless }
        if config.qualityFactor >= 0.95 { return .maximum }
        if config.qualityFactor >= 0.75 { return .high }
        if config.qualityFactor >= 0.5 { return .balanced }
        if config.resolution != .original { return .smaller }
        return .custom
    }

    private func saveFolder(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if let data = try? FileDestinationStore.saveBookmark(for: url) {
            container.settings.customFolderBookmark = data
            container.settings.customFolderName = url.lastPathComponent
        }
    }

    private func saveAndStart() {
        job.configuration = configuration
        job.destination = destination
        container.queue.start(job)
        dismiss()
    }

    private func loadMetadata() async {
        if let metadata = job.metadata {
            sourceMetadata = metadata
            return
        }
        guard let url = job.sourceURL else {
            analyzeFailed = true
            return
        }
        do {
            sourceMetadata = try await MediaAnalyzer.analyze(url: url)
        } catch {
            #if FFMPEG_ENABLED
            if let result = await FFmpegEngine.analyze(url: url) {
                sourceMetadata = result.metadata
                job.metadata = result.metadata
                return
            }
            #endif
            analyzeFailed = true
        }
    }
}