import Foundation
import UIKit
import Observation

@MainActor
@Observable
final class ThermalMonitor {
    var thermalState: ProcessInfo.ThermalState = .nominal
    var isLowPowerMode = false
    var batteryLevel: Float = 1.0
    var batteryState: UIDevice.BatteryState = .unknown

    private var observers: [NSObjectProtocol] = []

    init() {
        thermalState = ProcessInfo.processInfo.thermalState
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        refreshBattery()
        UIDevice.current.isBatteryMonitoringEnabled = true

        observers.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.thermalState = ProcessInfo.processInfo.thermalState }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshBattery() }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshBattery() }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    private func refreshBattery() {
        batteryLevel = UIDevice.current.batteryLevel
        batteryState = UIDevice.current.batteryState
    }

    var isConstrained: Bool {
        thermalState == .serious || thermalState == .critical || isLowPowerMode
    }

    var isCritical: Bool {
        thermalState == .critical
    }
}