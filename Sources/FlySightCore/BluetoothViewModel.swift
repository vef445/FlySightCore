//
//  BluetoothViewModel.swift
//  
//
//  Created by Michael Cooper on 2024-05-25.
//

import Foundation
import CoreBluetooth
import Combine

public class BluetoothViewModel: NSObject, ObservableObject {
    private var centralManager: CBCentralManager?
    
    @Published public var peripheralInfos: [PeripheralInfo] = []
    
    public let CRS_RX_UUID = CBUUID(string: "00000002-8e22-4541-9d4c-21edae82ed19")
    public let CRS_TX_UUID = CBUUID(string: "00000001-8e22-4541-9d4c-21edae82ed19")
    
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    
    @Published public var directoryEntries: [DirectoryEntry] = []
    
    @Published public var connectedPeripheral: PeripheralInfo?

    @Published public var currentPath: [String] = []  // Start with the root directory

    @Published public var isAwaitingResponse = false

    private var timers: [UUID: Timer] = [:]

    public override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: .main)
    }
    
    public func sortPeripheralsByRSSI() {
        DispatchQueue.main.async {
            self.peripheralInfos.sort { $0.rssi > $1.rssi }
        }
    }

    public func connect(to peripheral: CBPeripheral) {
        centralManager?.connect(peripheral, options: nil)
        if let index = peripheralInfos.firstIndex(where: { $0.peripheral.identifier == peripheral.identifier }) {
            peripheralInfos[index].isConnected = true
            timers[peripheral.identifier]?.invalidate() // Stop the timer when connected
            addBondedDevice(peripheral)  // Mark as bonded
        }
    }

    public func disconnect(from peripheral: CBPeripheral) {
        centralManager?.cancelPeripheralConnection(peripheral)
        if let index = peripheralInfos.firstIndex(where: { $0.peripheral.identifier == peripheral.identifier }) {
            // Check if the peripheral is bonded
            if !bondedDeviceIDs.contains(peripheral.identifier) {
                // Remove the peripheral if it's not bonded
                peripheralInfos.remove(at: index)
                timers[peripheral.identifier]?.invalidate()
                timers.removeValue(forKey: peripheral.identifier)
            } else {
                // Update the connection status without removing from the list
                peripheralInfos[index].isConnected = false
                // Optionally restart the timer if you want to eventually remove it if it does not advertise again
                startDisappearanceTimer(for: peripheralInfos[index])
            }
        }
    }

    public func parseDirectoryEntry(from data: Data) -> DirectoryEntry? {
        guard data.count == 24 else { return nil } // Ensure data length is as expected

        let size: UInt32 = data.subdata(in: 2..<6).withUnsafeBytes { $0.load(as: UInt32.self) }
        let fdate: UInt16 = data.subdata(in: 6..<8).withUnsafeBytes { $0.load(as: UInt16.self) }
        let ftime: UInt16 = data.subdata(in: 8..<10).withUnsafeBytes { $0.load(as: UInt16.self) }
        let fattrib: UInt8 = data.subdata(in: 10..<11).withUnsafeBytes { $0.load(as: UInt8.self) }

        let nameData = data.subdata(in: 11..<24) // Assuming the rest is the name
        let nameDataNullTerminated = nameData.split(separator: 0, maxSplits: 1, omittingEmptySubsequences: false).first ?? Data() // Split at the first null byte
        guard let name = String(data: nameDataNullTerminated, encoding: .utf8), !name.isEmpty else { return nil } // Check for empty name

        // Decode date and time
        let year = Int((fdate >> 9) & 0x7F) + 1980
        let month = Int((fdate >> 5) & 0x0F)
        let day = Int(fdate & 0x1F)
        let hour = Int((ftime >> 11) & 0x1F)
        let minute = Int((ftime >> 5) & 0x3F)
        let second = Int((ftime & 0x1F) * 2) // Multiply by 2 to get the actual seconds

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)) else { return nil }

        // Decode attributes
        let attributesOrder = ["r", "h", "s", "a", "d"]
        let attribText = attributesOrder.enumerated().map { index, letter in
            (fattrib & (1 << index)) != 0 ? letter : "-"
        }.joined()

        return DirectoryEntry(size: size, date: date, attributes: attribText, name: name)
    }

    public func changeDirectory(to newDirectory: String) {
        guard !isAwaitingResponse else { return }

        // Append new directory to the path
        currentPath.append(newDirectory)
        loadDirectoryEntries()
    }

    public func goUpOneDirectoryLevel() {
        guard !isAwaitingResponse else { return }

        // Remove the last directory in the path
        if currentPath.count > 0 {
            currentPath.removeLast()
            loadDirectoryEntries()
        }
    }

    private func loadDirectoryEntries() {
        // Reset the directory listings
        directoryEntries = []

        // Set waiting flag
        isAwaitingResponse = true

        if let peripheral = connectedPeripheral?.peripheral, let rx = rxCharacteristic {
            let directory = "/" + (currentPath).joined(separator: "/")
            print("  Getting directory \(directory)")
            let directoryCommand = Data([0x05]) + directory.data(using: .utf8)!
            peripheral.writeValue(directoryCommand, for: rx, type: .withoutResponse)
        }
    }

    // Helper functions
    private func startDisappearanceTimer(for peripheralInfo: PeripheralInfo) {
        if !bondedDeviceIDs.contains(peripheralInfo.id) {
            timers[peripheralInfo.id]?.invalidate()
            timers[peripheralInfo.id] = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                if !peripheralInfo.isConnected {
                    self?.removePeripheral(peripheralInfo)
                }
            }
        }
    }

    private func resetTimer(for peripheralInfo: PeripheralInfo) {
        if !bondedDeviceIDs.contains(peripheralInfo.id) {
            startDisappearanceTimer(for: peripheralInfo)
        }
    }

    private func removePeripheral(_ peripheralInfo: PeripheralInfo) {
        DispatchQueue.main.async {
            self.peripheralInfos.removeAll { $0.id == peripheralInfo.id }
            self.timers[peripheralInfo.id]?.invalidate()
            self.timers.removeValue(forKey: peripheralInfo.id)
        }
    }
}

extension BluetoothViewModel: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            self.centralManager?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        DispatchQueue.main.async {
            let isBonded = self.bondedDeviceIDs.contains(peripheral.identifier)
            var shouldAdd = isBonded

            if let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, manufacturerData.count >= 3 {
                let manufacturerId = (UInt16(manufacturerData[1]) << 8) | UInt16(manufacturerData[0])
                if manufacturerId == 0x09DB {
                    shouldAdd = true
                }
            }

            if shouldAdd {
                if let index = self.peripheralInfos.firstIndex(where: { $0.peripheral.identifier == peripheral.identifier }) {
                    self.peripheralInfos[index].rssi = RSSI.intValue
                    if !isBonded {  // Only reset timer for non-bonded devices
                        self.resetTimer(for: self.peripheralInfos[index])
                    }
                } else {
                    let newPeripheralInfo = PeripheralInfo(peripheral: peripheral, rssi: RSSI.intValue, name: peripheral.name ?? "Unnamed Device", isConnected: false)
                    self.peripheralInfos.append(newPeripheralInfo)
                    if !isBonded {
                        self.startDisappearanceTimer(for: newPeripheralInfo)
                    }
                }
            }
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected to \(peripheral.name ?? "Unknown Device") (peripheral ID = \(peripheral.identifier))")

        // Set this object as the delegate for the peripheral to receive peripheral delegate callbacks.
        peripheral.delegate = self

        // Optionally start discovering services or characteristics here
        peripheral.discoverServices(nil)  // Passing nil will discover all services
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("Disconnected from \(peripheral.name ?? "Unknown Device") (peripheral ID = \(peripheral.identifier))")

        // Reset the characteristic references
        rxCharacteristic = nil
        txCharacteristic = nil

        // Initialize current path
        currentPath = []

        // Reset the directory listings
        directoryEntries = []

        // Optionally: Handle any UI updates or perform cleanup after disconnection
        // This might involve updating published properties or notifying the user
    }
}

extension BluetoothViewModel: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else {
            isAwaitingResponse = false
            print("Error reading characteristic: \(error?.localizedDescription ?? "Unknown error")")
            return
        }

        if characteristic.uuid == CRS_TX_UUID {
            DispatchQueue.main.async {
                if let directoryEntry = self.parseDirectoryEntry(from: data) {
                    self.directoryEntries.append(directoryEntry)
                    self.sortDirectoryEntries()
                }
                self.isAwaitingResponse = false
            }
        }
    }

    public func sortDirectoryEntries() {
        directoryEntries.sort {
            if $0.isFolder != $1.isFolder {
                return $0.isFolder && !$1.isFolder
            }
            return $0.name.lowercased() < $1.name.lowercased()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("Error discovering services: \(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            print("Error discovering characteristics: \(error!.localizedDescription)")
            return
        }

        if let characteristics = service.characteristics {
            for characteristic in characteristics {
                if characteristic.uuid == CRS_TX_UUID {
                    txCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                } else if characteristic.uuid == CRS_RX_UUID {
                    rxCharacteristic = characteristic
                    peripheral.readValue(for: characteristic)
                }
            }
            if txCharacteristic != nil && rxCharacteristic != nil {
                loadDirectoryEntries()
            }
        }
    }
}

extension BluetoothViewModel {
    var bondedDeviceIDsKey: String { "bondedDeviceIDs" }

    var bondedDeviceIDs: Set<UUID> {
        get {
            Set((UserDefaults.standard.array(forKey: bondedDeviceIDsKey) as? [String])?.compactMap(UUID.init) ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue.map { $0.uuidString }), forKey: bondedDeviceIDsKey)
        }
    }

    public func addBondedDevice(_ peripheral: CBPeripheral) {
        var currentBonded = bondedDeviceIDs
        currentBonded.insert(peripheral.identifier)
        bondedDeviceIDs = currentBonded
    }

    public func removeBondedDevice(_ peripheral: CBPeripheral) {
        var currentBonded = bondedDeviceIDs
        currentBonded.remove(peripheral.identifier)
        bondedDeviceIDs = currentBonded
    }
}
