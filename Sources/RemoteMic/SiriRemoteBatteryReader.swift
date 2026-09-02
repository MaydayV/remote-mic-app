@preconcurrency import CoreBluetooth
import Foundation

/// Reads the standard BLE Battery Service exposed by Siri Remote.
///
/// CoreBluetooth is used as the reliable path because IOHID battery properties are not
/// guaranteed to exist on Bluetooth HID proxy interfaces. All callbacks stay on the main queue.
@MainActor
final class SiriRemoteBatteryReader: NSObject,
    @preconcurrency CBCentralManagerDelegate,
    @preconcurrency CBPeripheralDelegate
{
    private let batteryServiceUUID = CBUUID(string: "180F")
    private let batteryLevelUUID = CBUUID(string: "2A19")
    private let timeoutInterval: TimeInterval = 12

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    /// Only disconnect links created by this reader. A peripheral returned by
    /// `retrieveConnectedPeripherals` may be the system HID transport itself.
    private var ownsPeripheralConnection = false
    private var preferredRemoteName: String?
    private var completion: ((Int?) -> Void)?
    private var timeoutTimer: Timer?

    func read(remoteName: String? = nil, completion: @escaping (Int?) -> Void) {
        cancel(deliverResult: true)
        preferredRemoteName = remoteName
        self.completion = completion
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeoutInterval, repeats: false) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finish(nil)
            }
        }
        if central == nil {
            central = CBCentralManager(
                delegate: self,
                queue: nil,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
        } else {
            startLookupIfPossible()
        }
    }

    func cancel() {
        cancel(deliverResult: false)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        startLookupIfPossible()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard completion != nil else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let peripheralName = peripheral.name.flatMap { $0.isEmpty ? nil : $0 }
        let name = peripheralName ?? advertisedName ?? preferredRemoteName ?? ""
        guard Self.isLikelyRemoteName(name) else { return }
        central.stopScan()
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        peripheral.delegate = self
        peripheral.discoverServices([batteryServiceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        AppLogger.shared.write(
            "SIRI REMOTE battery BLE connect failed error=\(error?.localizedDescription ?? "unknown")"
        )
        finish(nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier,
              error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == batteryServiceUUID })
        else {
            finish(nil)
            return
        }
        peripheral.discoverCharacteristics([batteryLevelUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier,
              error == nil,
              let characteristic = service.characteristics?.first(where: {
                  $0.uuid == batteryLevelUUID
              })
        else {
            finish(nil)
            return
        }
        guard characteristic.properties.contains(.read) else {
            finish(nil)
            return
        }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier,
              characteristic.uuid == batteryLevelUUID,
              error == nil,
              let value = characteristic.value?.first
        else {
            finish(nil)
            return
        }
        let percent = Int(value)
        finish((0...100).contains(percent) ? percent : nil)
    }

    private func startLookupIfPossible() {
        guard completion != nil, let central else { return }
        switch central.state {
        case .poweredOn:
            let connected = central.retrieveConnectedPeripherals(
                withServices: [batteryServiceUUID]
            )
            if let remote = connected.first(where: {
                Self.isLikelyRemoteName($0.name ?? "")
            }) {
                connect(remote)
            } else if !central.isScanning {
                // HID-over-BLE 设备经常不在广播包里声明 180F，先扫描全部外围设备，
                // 再用 Siri Remote 名称筛选并发现标准电池服务。
                central.scanForPeripherals(
                    withServices: nil,
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                )
            }
        case .unknown, .resetting:
            break
        default:
            finish(nil)
        }
    }

    private func connect(_ peripheral: CBPeripheral) {
        guard let central, completion != nil else { return }
        self.peripheral = peripheral
        peripheral.delegate = self
        if peripheral.state == .connected {
            ownsPeripheralConnection = false
            peripheral.discoverServices([batteryServiceUUID])
        } else {
            ownsPeripheralConnection = true
            central.connect(peripheral, options: nil)
        }
    }

    private func finish(_ result: Int?) {
        let completion = completion
        cancel(deliverResult: false)
        completion?(result)
    }

    private func cancel(deliverResult: Bool) {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        central?.stopScan()
        if let peripheral {
            peripheral.delegate = nil
            if ownsPeripheralConnection, peripheral.state != .disconnected {
                central?.cancelPeripheralConnection(peripheral)
            }
        }
        peripheral = nil
        ownsPeripheralConnection = false
        preferredRemoteName = nil
        let pendingCompletion = completion
        completion = nil
        if deliverResult {
            pendingCompletion?(nil)
        }
    }

    nonisolated static func isLikelyRemoteName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("remote")
            || lowered.contains("siri")
            || lowered.contains("apple tv")
    }
}
