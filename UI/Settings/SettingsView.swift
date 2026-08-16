import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                defaultsSection
                processingSection
                deviceSection
                diagnosticsSection
                aboutSection
            }
            .navigationTitle(L10n.settingsTitle)
        }
    }

    private var appearanceSection: some View {
        Section {
            Picker(L10n.appearanceRow, selection: Binding(
                get: { container.settings.appearance },
                set: { container.settings.appearance = $0 }
            )) {
                ForEach(AppearanceOption.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var defaultsSection: some View {
        Section(L10n.defaultsSection) {
            PickerRow(
                title: L10n.defaultFormatRow,
                selection: Binding(
                    get: { container.settings.defaultOutputContainer },
                    set: { container.settings.defaultOutputContainer = $0 }
                ),
                options: FormatCapabilities.availableOutputContainers().map { ($0.displayName, $0) }
            )
            PickerRow(
                title: L10n.defaultQualityRow,
                selection: Binding(
                    get: { container.settings.defaultPreset },
                    set: { container.settings.defaultPreset = $0 }
                ),
                options: ConversionPreset.allCases.filter { $0 != .custom }.map { ($0.displayName, $0) }
            )
            PickerRow(
                title: L10n.defaultDestinationRow,
                selection: Binding(
                    get: { container.settings.defaultDestination },
                    set: { container.settings.defaultDestination = $0 }
                ),
                options: destinationOptions
            )
        }
    }

    private var destinationOptions: [(String, OutputDestination)] {
        var options: [(String, OutputDestination)] = [
            (L10n.destinationPhotos, .photos),
            (L10n.destinationFiles, .filesDocuments)
        ]
        if container.settings.customFolderBookmark != nil {
            options.append((L10n.destinationCustomFolder, .filesCustom))
        }
        return options
    }

    private var processingSection: some View {
        Section(L10n.processingSection) {
            Stepper(value: Binding(
                get: { container.settings.concurrentJobs },
                set: { container.settings.concurrentJobs = $0 }
            ), in: 1...2) {
                HStack {
                    Text(L10n.concurrentJobsRow)
                    Spacer()
                    Text("\(container.settings.concurrentJobs)")
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(L10n.keepHistoryRow, isOn: Binding(
                get: { container.settings.keepHistory },
                set: { container.settings.keepHistory = $0 }
            ))
            Toggle(L10n.keepImportsRow, isOn: Binding(
                get: { container.settings.keepImports },
                set: { container.settings.keepImports = $0 }
            ))
        }
    }

    private var deviceSection: some View {
        Section(L10n.hardwareSection) {
            Toggle(L10n.hardwareAccelerationSetting, isOn: Binding(
                get: { container.settings.hardwareAcceleration },
                set: { container.settings.hardwareAcceleration = $0 }
            ))
            InfoRow(title: L10n.deviceRow, value: container.capabilities.deviceModel.isEmpty ? L10n.metadataNone : container.capabilities.deviceModel)
            InfoRow(title: L10n.iosRow, value: container.capabilities.systemVersion)
            InfoRow(title: L10n.thermalStateRow, value: thermalName)
            InfoRow(title: L10n.hwSupportRow, value: hardwareCodecsText)
            InfoRow(title: L10n.hdrCapableRow, value: container.capabilities.supportsHDR ? L10n.presetHigh : L10n.metadataNone)
            InfoRow(title: L10n.ffmpegRow, value: FormatCapabilities.isFFmpegEnabled ? L10n.ffmpegIncluded : L10n.ffmpegNotIncluded)
        }
    }

    private var thermalName: String {
        switch container.thermal.thermalState {
        case .nominal: return L10n.thermalNominal
        case .fair: return L10n.thermalFair
        case .serious: return L10n.thermalSerious
        case .critical: return L10n.thermalCritical
        @unknown default: return L10n.thermalNominal
        }
    }

    private var hardwareCodecsText: String {
        let codecs = container.capabilities.supportedVideoCodecs.map { $0.displayName }
        return codecs.isEmpty ? L10n.metadataNone : codecs.joined(separator: ", ")
    }

    private var diagnosticsSection: some View {
        Section(L10n.diagnosticsSection) {
            Toggle(L10n.diagnosticsEnabledRow, isOn: Binding(
                get: { container.settings.diagnosticsEnabled },
                set: { container.settings.diagnosticsEnabled = $0 }
            ))
            if container.diagnostics.entries.isEmpty {
                Text(L10n.diagnosticsEmpty)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Button(L10n.clearLogButton, role: .destructive) {
                        container.diagnostics.clear()
                    }
                    Spacer()
                    Button(L10n.copyLogButton) {
                        UIPasteboard.general.string = container.diagnostics.exportText()
                    }
                }
                ForEach(container.diagnostics.entries.prefix(30)) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.message)
                            .font(.caption)
                        if let detail = entry.detail {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(entry.timestamp, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var aboutSection: some View {
        Section(L10n.aboutSection) {
            InfoRow(title: L10n.versionRow, value: versionText)
        }
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}