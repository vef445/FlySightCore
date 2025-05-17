//
//  BluetoothManager.swift
//
//
//  Created by Michael Cooper on 2024-05-25.
//

import Foundation
import CoreBluetooth
import Combine

public extension FlySightCore {
    class BluetoothManager: NSObject, ObservableObject {
        private var centralManager: CBCentralManager?
        private var cancellables = Set<AnyCancellable>()
        private var notificationHandlers: [CBUUID: (CBPeripheral, CBCharacteristic, Error?) -> Void] = [:]

        @Published public var peripheralInfos: [PeripheralInfo] = []

        public let CRS_RX_UUID = CBUUID(string: "00000002-8e22-4541-9d4c-21edae82ed19")
        public let CRS_TX_UUID = CBUUID(string: "00000001-8e22-4541-9d4c-21edae82ed19")
        public let GNSS_PV_UUID = CBUUID(string: "00000000-8e22-4541-9d4c-21edae82ed19")
        public let START_CONTROL_UUID = CBUUID(string: "00000003-8e22-4541-9d4c-21edae82ed19")
        public let START_RESULT_UUID = CBUUID(string: "00000004-8e22-4541-9d4c-21edae82ed19")
        public let GNSS_CONTROL_UUID = CBUUID(string: "00000006-8e22-4541-9d4c-21edae82ed19")

        private var rxCharacteristic: CBCharacteristic?
        private var txCharacteristic: CBCharacteristic?
        private var pvCharacteristic: CBCharacteristic?
        private var controlCharacteristic: CBCharacteristic?
        private var resultCharacteristic: CBCharacteristic?
        private var gnssControlCharacteristic: CBCharacteristic?

        @Published public var directoryEntries: [DirectoryEntry] = []

        @Published public var connectedPeripheral: PeripheralInfo?

        @Published public var currentPath: [String] = []  // Start with the root directory

        @Published public var isAwaitingResponse = false

        public enum State {
            case idle
            case counting
        }

        @Published public var state: State = .idle
        @Published public var startResultDate: Date?

        private var timers: [UUID: Timer] = [:]

        @Published public var downloadProgress: Float = 0.0
        private var currentFileSize: UInt32 = 0

        private var isUploading = false
        @Published public var uploadProgress: Float = 0.0
        private var fileDataToUpload: Data?
        private var remotePathToUpload: String?
        private var nextPacketNum: Int = 0       // Next packet number to send (full Int)
        private var nextAckNum: Int = 0          // Next acknowledgment expected
        private var lastPacketNum: Int?          // Sequence number after the last packet
        private let windowLength: Int = 8         // Window size
        private let frameLength: Int = 242        // Size of each data frame
        private let TX_TIMEOUT: TimeInterval = 0.2 // Timeout for acknowledgments in seconds
        private var totalPackets: UInt32 = 0      // Total number of packets to send
        private var uploadTask: Task<Void, Never>? // Task for the main upload loop
        private var ackReceived = PassthroughSubject<Int, Never>() // Publisher for received ACKs
        private var uploadCancellable: AnyCancellable?
        private var continuationCancellables: Set<AnyCancellable> = []
        private var uploadCompletion: ((Result<Void, Error>) -> Void)?

        // Resumption flag and lock to prevent multiple resumptions
        private let ackContinuationLock = DispatchQueue(label: "com.flysight.bluetoothmanager.ackContinuationLock")
        private var isContinuationResumed = false

        private var pingTimer: Timer?

        @Published public var liveGNSSData: FlySightCore.LiveGNSSData?
        @Published public var currentGNSSMask: UInt8 = FlySightCore.GNSSLiveMaskBits.timeOfWeek | FlySightCore.GNSSLiveMaskBits.position | FlySightCore.GNSSLiveMaskBits.velocity // Default: 0xB0
        @Published public var gnssMaskUpdateStatus: FlySightCore.GNSSMaskUpdateStatus = .idle

        public override init() {
            super.init()
            self.centralManager = CBCentralManager(delegate: self, queue: .main)
        }

        public func sortPeripheralsByRSSI() {
            DispatchQueue.main.async {
                self.peripheralInfos.sort {
                    // First, sort by pairing mode: true comes before false
                    if $0.isPairingMode != $1.isPairingMode {
                        return $0.isPairingMode && !$1.isPairingMode
                    }
                    // If both have the same pairing mode status, sort by RSSI descending
                    return $0.rssi > $1.rssi
                }
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

        private func parseDirectoryEntry(from data: Data) -> DirectoryEntry? {
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

        public func loadDirectoryEntries() {
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

        public func sendStartCommand() {
            guard let controlCharacteristic = controlCharacteristic else {
                print("Control characteristic not found")
                return
            }

            // Sending 0x00 to the control characteristic
            let startCommand = Data([0x00])
            connectedPeripheral?.peripheral.writeValue(startCommand, for: controlCharacteristic, type: .withResponse)
            state = .counting
        }

        public func sendCancelCommand() {
            guard let controlCharacteristic = controlCharacteristic else {
                print("Control characteristic not found")
                return
            }

            // Sending 0x01 to the control characteristic
            let cancelCommand = Data([0x01])
            connectedPeripheral?.peripheral.writeValue(cancelCommand, for: controlCharacteristic, type: .withResponse)
            state = .idle
        }

        public func processStartResult(data: Data) {
            guard data.count == 9 else {
                print("Invalid start result data length")
                return
            }

            let year = data.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self) }
            let month = data.subdata(in: 2..<3).withUnsafeBytes { $0.load(as: UInt8.self) }
            let day = data.subdata(in: 3..<4).withUnsafeBytes { $0.load(as: UInt8.self) }
            let hour = data.subdata(in: 4..<5).withUnsafeBytes { $0.load(as: UInt8.self) }
            let minute = data.subdata(in: 5..<6).withUnsafeBytes { $0.load(as: UInt8.self) }
            let second = data.subdata(in: 6..<7).withUnsafeBytes { $0.load(as: UInt8.self) }
            let timestampMs = data.subdata(in: 7..<9).withUnsafeBytes { $0.load(as: UInt16.self) }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone(abbreviation: "UTC")!

            var components = DateComponents()
            components.year = Int(year)
            components.month = Int(month)
            components.day = Int(day)
            components.hour = Int(hour)
            components.minute = Int(minute)
            components.second = Int(second)
            components.nanosecond = Int(timestampMs) * 1_000_000

            guard let date = calendar.date(from: components) else {
                print("Failed to create date from start result data")
                return
            }

            DispatchQueue.main.async {
                if self.state == .counting {
                    self.startResultDate = date
                    self.state = .idle
                }
            }
        }

        public func downloadFile(named filePath: String, completion: @escaping (Result<Data, Error>) -> Void) {
            guard let peripheral = connectedPeripheral?.peripheral, let rx = rxCharacteristic, let tx = txCharacteristic else {
                completion(.failure(NSError(domain: "FlySightCore", code: -1, userInfo: [NSLocalizedDescriptionKey: "No connected peripheral or RX characteristic"])))
                return
            }

            var fileData = Data()
            var nextPacketNum: UInt8 = 0
            let transferComplete = PassthroughSubject<Void, Error>()

            // Extract the file name from the full path
            let fileName = (filePath as NSString).lastPathComponent

            // Set the current file size (assuming you know it here)
            if let fileEntry = directoryEntries.first(where: { $0.name == fileName }) {
                currentFileSize = fileEntry.size
            } else {
                currentFileSize = 0  // Fallback to 0 if file size is unknown
            }

            // Define the notification handler
            let notifyHandler: (CBPeripheral, CBCharacteristic, Error?) -> Void = { [weak self] (peripheral, characteristic, error) in
                guard error == nil, let data = characteristic.value else {
                    transferComplete.send(completion: .failure(error ?? NSError(domain: "FlySightCore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"])))
                    return
                }
                if data[0] == 0x10 {
                    let packetNum = data[1]
                    if packetNum == nextPacketNum {
                        if data.count > 2 {
                            fileData.append(data[2...])
                        } else {
                            transferComplete.send(completion: .finished)
                        }
                        nextPacketNum = nextPacketNum &+ 1
                        let ackPacket = Data([0x12, packetNum])
                        peripheral.writeValue(ackPacket, for: rx, type: .withoutResponse)

                        print("Received packet: \(packetNum), length \(data.count - 2)")

                        // Update the download progress
                        if let fileSize = self?.currentFileSize {
                            let progress = Float(fileData.count) / Float(fileSize)
                            DispatchQueue.main.async {
                                self?.downloadProgress = progress
                            }
                        }
                    } else {
                        print("Out of order packet: \(packetNum)")
                    }
                }
            }

            // Save the handler in a dictionary to be used in didUpdateValueFor
            notificationHandlers[tx.uuid] = notifyHandler

            print("  Getting file \(filePath)")

            // Create offset and stride bytes as per the Python script
            let offset: UInt32 = 0
            let stride: UInt32 = 0
            let offsetBytes = withUnsafeBytes(of: offset.littleEndian, Array.init)
            let strideBytes = withUnsafeBytes(of: stride.littleEndian, Array.init)
            let command = Data([0x02]) + offsetBytes + strideBytes + filePath.data(using: .utf8)!

            // Write the command to start the file transfer
            peripheral.writeValue(command, for: rx, type: .withoutResponse)

            // Subscribe to the completion of the transfer
            let cancellable = transferComplete.sink(receiveCompletion: { result in
                self.notificationHandlers[tx.uuid] = nil // Clear the handler after use
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .finished:
                    completion(.success(fileData))
                }
            }, receiveValue: { _ in })

            cancellable.store(in: &cancellables)
        }

        public func cancelDownload() {
            guard let rx = rxCharacteristic else {
                print("RX characteristic not found")
                return
            }

            // Sending 0xFF to the RX characteristic
            let cancelCommand = Data([0xFF])
            connectedPeripheral?.peripheral.writeValue(cancelCommand, for: rx, type: .withoutResponse)
            state = .idle
        }

        public func uploadFile(fileData: Data, remotePath: String, completion: @escaping (Result<Void, Error>) -> Void) {
            guard let peripheral = connectedPeripheral?.peripheral,
                  let rx = rxCharacteristic,
                  let tx = txCharacteristic else {
                completion(.failure(NSError(domain: "FlySightCore", code: -1, userInfo: [NSLocalizedDescriptionKey: "No connected peripheral or RX characteristic"])))
                return
            }

            // Initialize upload state
            isUploading = true
            fileDataToUpload = fileData
            remotePathToUpload = remotePath
            nextPacketNum = 0
            nextAckNum = 0
            lastPacketNum = nil
            uploadProgress = 0.0

            // Calculate total packets
            let totalPacketsInt = Int(ceil(Double(fileData.count) / Double(frameLength)))
            totalPackets = UInt32(totalPacketsInt)
            print("Total packets to send: \(totalPackets)")

            // Store the completion handler
            self.uploadCompletion = completion

            // Set up acknowledgment handler
            setupAckHandler()

            // Set up the notification handler
            setupNotificationHandler(for: tx)

            // Send upload command
            guard let remotePathData = remotePath.data(using: .utf8) else {
                completion(.failure(NSError(domain: "FlySightCore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode remote path."])))
                return
            }

            let command = Data([0x03]) + remotePathData // 0x03: Upload command
            print("Sending upload command: \(command as NSData)")
            peripheral.writeValue(command, for: rx, type: .withoutResponse)

            // Start the main transfer loop
            print("Upload command sent. Starting file transfer loop.")
            startFileTransferLoop(peripheral: peripheral, rxCharacteristic: rx, txCharacteristic: tx)
        }

        private func setupAckHandler() {
            // Subscribe to ackReceived publisher
            uploadCancellable = ackReceived
                .receive(on: DispatchQueue.main) // Ensure updates are on the main thread for UI changes
                .sink { [weak self] ackNum in
                    guard let self = self else { return }
                    print("Received ACK for packet \(ackNum)")

                    // Check if the ACK is for the expected packet
                    if ackNum == self.nextAckNum % 256 {
                        self.nextAckNum += 1
                        self.uploadProgress = Float(self.nextAckNum) / Float(self.totalPackets)
                        print("Updated nextAckNum to \(self.nextAckNum), uploadProgress: \(self.uploadProgress * 100)%")

                        // Check if all packets have been acknowledged
                        if let lastPacket = self.lastPacketNum, self.nextAckNum >= lastPacket {
                            print("All packets acknowledged. Upload complete.")
                            self.uploadCompletion?(.success(()))
                            self.isUploading = false
                            self.uploadTask?.cancel()
                            self.notificationHandlers[self.txCharacteristic?.uuid ?? CBUUID()] = nil
                            self.resetUploadState()
                        }
                    } else {
                        print("Received out-of-order ACK: \(ackNum). Expected: \(self.nextAckNum)")
                        // Optionally handle out-of-order ACKs here
                    }
                }
        }

        private func setupNotificationHandler(for characteristic: CBCharacteristic) {
            // Avoid re-assigning the handler if it's already set
            if notificationHandlers[characteristic.uuid] != nil {
                print("Handler already set for characteristic \(characteristic.uuid)")
                return
            }

            notificationHandlers[characteristic.uuid] = { [weak self] (peripheral, characteristic, error) in
                guard let self = self else { return }
                if let error = error {
                    print("Error receiving notification: \(error.localizedDescription)")
                    self.cancelUpload()
                    return
                }

                guard let data = characteristic.value else {
                    print("No data received in notification.")
                    return
                }

                print("Received notification data: \(data as NSData) from characteristic \(characteristic.uuid)")

                // Handle Data ACK (e.g., 0x12xx)
                if data.count == 2 && data[0] == 0x12 {
                    let ackNum = Int(data[1])
                    print("Received Data ACK for packet \(ackNum)")
                    self.ackReceived.send(ackNum)
                }
                // Handle Directory Entry (assuming fixed length, e.g., 24 bytes)
                else if data.count == 24 {
                    if let directoryEntry = self.parseDirectoryEntry(from: data) {
                        DispatchQueue.main.async {
                            self.directoryEntries.append(directoryEntry)
                            self.sortDirectoryEntries()
                            self.isAwaitingResponse = false
                        }
                    }
                }
                // Handle other notifications if necessary
                else {
                    print("Received unknown notification data: \(data as NSData)")
                }
            }

            print("Handler set for characteristic \(characteristic.uuid)")
        }

        private func startFileTransferLoop(peripheral: CBPeripheral, rxCharacteristic: CBCharacteristic, txCharacteristic: CBCharacteristic) {
            // Initialize the upload task
            uploadTask = Task {
                var uploadSucceeded = false
                while isUploading && !Task.isCancelled {
                    do {
                        // Attempt to send packets within the window
                        try await self.sendPacketsWithinWindow(peripheral: peripheral, rxCharacteristic: rxCharacteristic)
                    } catch {
                        if error is CancellationError {
                            print("Upload task cancelled.")
                            break // Exit the loop on cancellation
                        } else {
                            print("Caught error: \(error.localizedDescription)")
                            print("Resending window starting at packet \(nextAckNum)")
                            // Reset nextPacketNum to nextAckNum to resend the window
                            nextPacketNum = nextAckNum
                        }
                    }

                    // Wait for an acknowledgment or timeout
                    do {
                        try await withThrowingTaskGroup(of: Int.self) { group in
                            // Add a task to wait for an ACK
                            group.addTask {
                                print("TaskGroup: Awaiting ACK...")
                                let ackNum = try await self.awaitFirstMatchingAck()
                                print("TaskGroup: Received ACK \(ackNum)")
                                return ackNum
                            }

                            // Add a timeout task
                            group.addTask {
                                print("TaskGroup: Timeout task started.")
                                try await Task.sleep(nanoseconds: UInt64(self.TX_TIMEOUT * 1_000_000_000))
                                print("TaskGroup: Timeout occurred.")
                                throw NSError(domain: "FlySightCore", code: -1, userInfo: [NSLocalizedDescriptionKey: "ACK timeout"])
                            }

                            // Wait for either ACK or timeout
                            if let ackNum = try await group.next() {
                                print("TaskGroup: Received in group: \(ackNum)")
                                group.cancelAll()
                            }
                        }
                    } catch {
                        if error is CancellationError {
                            print("Upload task cancelled.")
                            break // Exit the loop on cancellation
                        }
                        print("Caught error: \(error.localizedDescription)")
                        print("Resending window starting at packet \(nextAckNum)")
                        // Reset nextPacketNum to nextAckNum to resend the window
                        nextPacketNum = nextAckNum
                    }
                }

                // After exiting the loop, determine the outcome
                if uploadSucceeded {
                    print("Upload completed successfully.")
                    self.uploadCompletion?(.success(()))
                } else {
                    print("Upload was cancelled or failed.")
                    // uploadCompletion should have been called in cancelUpload or error handling
                }

                // Clean up
                self.uploadTask?.cancel()
                self.resetUploadState()
            }
        }

        private func awaitFirstMatchingAck() async throws -> Int {
            try await withCheckedThrowingContinuation { continuation in
                // Subscribe to the ackReceived publisher
                let cancellable = self.ackReceived
                    .filter { $0 >= self.nextAckNum }
                    .first()
                    .sink(receiveCompletion: { [weak self] completion in
                        guard let self = self else { return }
                        self.ackContinuationLock.sync {
                            if !self.isContinuationResumed {
                                self.isContinuationResumed = true
                                switch completion {
                                case .finished:
                                    // No action needed
                                    break
                                case .failure(let error):
                                    continuation.resume(throwing: error)
                                }
                            }
                        }
                    }, receiveValue: { [weak self] ackNum in
                        guard let self = self else { return }
                        self.ackContinuationLock.sync {
                            if !self.isContinuationResumed {
                                self.isContinuationResumed = true
                                continuation.resume(returning: ackNum)
                            }
                        }
                    })

                // Retain the cancellable to prevent it from being deallocated
                self.continuationCancellables.insert(cancellable)

                // Handle task cancellation
                Task {
                    do {
                        try await Task.sleep(nanoseconds: UInt64.max)
                        // This will never be called normally
                    } catch {
                        // Task was canceled
                        self.ackContinuationLock.sync {
                            if !self.isContinuationResumed {
                                self.isContinuationResumed = true
                                cancellable.cancel()
                                continuation.resume(throwing: CancellationError())
                            }
                        }
                    }
                }
            }
        }

        private func sendPacketsWithinWindow(peripheral: CBPeripheral, rxCharacteristic: CBCharacteristic) async throws {
            while nextPacketNum < nextAckNum + windowLength && (lastPacketNum == nil || nextPacketNum < lastPacketNum!) {
                // Check if the upload is still active
                if !isUploading || fileDataToUpload == nil {
                    print("No more packets to send or upload not initialized.")
                    throw CancellationError()
                }

                // Send the packet
                sendPacket(peripheral: peripheral, rxCharacteristic: rxCharacteristic)

                // Introduce a small non-blocking delay
                do {
                    try await Task.sleep(nanoseconds: 50_000_000) // 50 milliseconds
                } catch {
                    if error is CancellationError {
                        print("Sleep interrupted: The operation couldn’t be completed. (Swift.CancellationError error 1.)")
                    } else {
                        print("Sleep interrupted: \(error.localizedDescription)")
                    }
                    // Re-throw the error to propagate cancellation
                    throw error
                }
            }
        }

        private func sendPacket(peripheral: CBPeripheral, rxCharacteristic: CBCharacteristic) {
            guard let fileData = fileDataToUpload else {
                print("No file data to send.")
                return
            }

            let startIndex = nextPacketNum * frameLength
            let endIndex = min(startIndex + frameLength, fileData.count)

            if startIndex < fileData.count {
                // Send Data Packet
                let dataSlice = fileData[startIndex..<endIndex]

                // Construct the packet: [0x10][Packet Number][Data...]
                var packetData = Data()
                packetData.append(0x10) // 0x10 signifies the start of a data packet
                packetData.append(UInt8(nextPacketNum % 256)) // Packet number modulo 256
                packetData.append(dataSlice) // Actual data

                // **Logging the First 10 Bytes**
                let first10Bytes = packetData.prefix(10)
                let hexString = first10Bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
                print("Sending packet \(nextPacketNum): first 10 bytes: \(hexString)")

                // Write the data packet with .withoutResponse	
                peripheral.writeValue(packetData, for: rxCharacteristic, type: .withoutResponse)
                print("Packet \(nextPacketNum) sent.")
            }
            else {
                // Send Final Empty Packet
                let packetData = Data([0x10, UInt8(nextPacketNum % 256)]) // [0x10][Packet Number]
                peripheral.writeValue(packetData, for: rxCharacteristic, type: .withoutResponse)
                print("Sending final empty packet \(nextPacketNum): \(packetData as NSData)")

                // Now, set lastPacketNum after sending the empty packet
                lastPacketNum = nextPacketNum + 1
                print("Final empty packet sent. Setting lastPacketNum to \(lastPacketNum!)")
            }

            // Increment the packet number
            nextPacketNum += 1
        }

        private func resetUploadState() {
            DispatchQueue.main.async {
                self.fileDataToUpload = nil
                self.remotePathToUpload = nil
                self.nextPacketNum = 0
                self.nextAckNum = 0
                self.lastPacketNum = nil
                self.uploadProgress = 0.0
                self.uploadTask = nil
                self.uploadCancellable?.cancel()
                self.uploadCancellable = nil
                self.uploadCompletion = nil // Reset the completion handler
            }
        }

        public func cancelUpload() {
            guard isUploading else { return }
            isUploading = false
            uploadTask?.cancel()
            uploadTask = nil
            uploadCancellable?.cancel()
            uploadCancellable = nil
            print("Upload cancelled.")

            // Send a cancel command to the device with .withoutResponse
            if let peripheral = connectedPeripheral?.peripheral, let rx = rxCharacteristic {
                let cancelCommand = Data([0xFF]) // Replace 0xFF with the correct cancel command byte if different
                print("Sending cancel upload command: \(cancelCommand as NSData)")
                peripheral.writeValue(cancelCommand, for: rx, type: .withoutResponse)
            }

            // Notify the completion handler about the cancellation BEFORE resetting the state
            self.uploadCompletion?(.failure(NSError(domain: "FlySightCore", code: -2, userInfo: [NSLocalizedDescriptionKey: "Upload cancelled."])))

            // Remove notification handler
            if let txUUID = txCharacteristic?.uuid {
                notificationHandlers[txUUID] = nil
            }

            // Reset upload state
            resetUploadState()
        }

        private func startPingTimer() {
            stopPingTimer() // Ensure any existing timer is stopped
            DispatchQueue.main.async {
                self.pingTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] timer in
                    self?.sendPing()
                }
                print("Ping timer started")
            }
        }

        private func stopPingTimer() {
            DispatchQueue.main.async {
                self.pingTimer?.invalidate()
                self.pingTimer = nil
            }
        }

        private func sendPing() {
            guard let rx = rxCharacteristic else {
                print("RX characteristic not found")
                return
            }
            let pingCommand = Data([0xFE])
            connectedPeripheral?.peripheral.writeValue(pingCommand, for: rx, type: .withoutResponse)
            print("Ping sent")
        }
    }
}

extension FlySightCore.BluetoothManager: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        DispatchQueue.main.async {
            let isBonded = self.bondedDeviceIDs.contains(peripheral.identifier)
            var shouldAdd = isBonded
            var isPairingMode = false

            if let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, manufacturerData.count >= 3 {
                let manufacturerId = (UInt16(manufacturerData[1]) << 8) | UInt16(manufacturerData[0])
                if manufacturerId == 0x09DB {
                    shouldAdd = true
                    isPairingMode = (manufacturerData[2] & 0x01) != 0
                }
            }

            if shouldAdd {
                if let index = self.peripheralInfos.firstIndex(where: { $0.peripheral.identifier == peripheral.identifier }) {
                    // Update existing PeripheralInfo
                    self.peripheralInfos[index].rssi = RSSI.intValue
                    self.peripheralInfos[index].isPairingMode = isPairingMode
                    if !isBonded {  // Only reset timer for non-bonded devices
                        self.resetTimer(for: self.peripheralInfos[index])
                    }
                } else {
                    // Create and add new PeripheralInfo
                    let newPeripheralInfo = FlySightCore.PeripheralInfo(
                        peripheral: peripheral,
                        rssi: RSSI.intValue,
                        name: peripheral.name ?? "Unnamed Device",
                        isConnected: false,
                        isPairingMode: isPairingMode
                    )
                    self.peripheralInfos.append(newPeripheralInfo)
                    if !isBonded {
                        self.startDisappearanceTimer(for: newPeripheralInfo)
                    }
                }
                // Sort peripherals after adding/updating
                self.sortPeripheralsByRSSI()
            }
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected to \(peripheral.name ?? "Unknown Device") (peripheral ID = \(peripheral.identifier))")

        // Set this object as the delegate for the peripheral to receive peripheral delegate callbacks.
        peripheral.delegate = self

        // Optionally start discovering services or characteristics here
        peripheral.discoverServices(nil)  // Passing nil will discover all services

        // Update isPairingMode flag and isConnected status
        if let index = peripheralInfos.firstIndex(where: { $0.peripheral.identifier == peripheral.identifier }) {
            peripheralInfos[index].isPairingMode = false  // Clear pairing mode flag
            peripheralInfos[index].isConnected = true      // Update connection status

            // Optionally, you might want to perform additional actions here, such as notifying other parts of your app
        }

        // Re-sort the peripherals list to reflect the updated pairing mode status
        sortPeripheralsByRSSI()
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("Disconnected from \(peripheral.name ?? "Unknown Device") (peripheral ID = \(peripheral.identifier))")

        // Reset the characteristic references
        rxCharacteristic = nil
        txCharacteristic = nil
        pvCharacteristic = nil
        controlCharacteristic = nil
        resultCharacteristic = nil
        gnssControlCharacteristic = nil

        // Stop the ping timer
        stopPingTimer()

        // Initialize current path
        currentPath = []

        // Reset the directory listings
        directoryEntries = []

        // Reset other states as needed
        if isUploading {
            cancelUpload()
        }
    }
}

extension FlySightCore.BluetoothManager: CBPeripheralDelegate {
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
        } else if characteristic.uuid == START_RESULT_UUID {
            processStartResult(data: data)
        } else if characteristic.uuid == GNSS_PV_UUID {
            parseLiveGNSSData(from: data)
        } else if characteristic.uuid == GNSS_CONTROL_UUID {
            processGNSSControlResponse(from: data)
        }

        // Handle notifications for file download
        if let handler = notificationHandlers[characteristic.uuid] {
            handler(peripheral, characteristic, error)
        } else {
            // Handle other characteristics or log
            print("No handler for characteristic \(characteristic.uuid)")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Write error for characteristic \(characteristic.uuid): \(error.localizedDescription)")
            if isUploading {
                cancelUpload()
            }
            return
        }

        print("Write successful for characteristic \(characteristic.uuid)")

        // Since writes are without response, rely on notifications for flow control
        // No further action needed here unless implementing additional logic
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Notification state error for \(characteristic.uuid): \(error.localizedDescription)")
        } else {
            print("Notifications enabled for \(characteristic.uuid)")
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
                    print("TX Characteristic found: \(characteristic.uuid)")

                    // Enable notifications
                    peripheral.setNotifyValue(true, for: characteristic)
                } else if characteristic.uuid == CRS_RX_UUID {
                    rxCharacteristic = characteristic
                    print("RX Characteristic found: \(characteristic.uuid)")

                    // Read to force pairing
                    peripheral.readValue(for: characteristic)
                } else if characteristic.uuid == GNSS_PV_UUID {
                    pvCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic) // Enable notifications for PV
                    print("GNSS PV Characteristic found: \(characteristic.uuid)")
                } else if characteristic.uuid == START_CONTROL_UUID {
                    controlCharacteristic = characteristic
                } else if characteristic.uuid == START_RESULT_UUID {
                    resultCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                } else if characteristic.uuid == GNSS_CONTROL_UUID { // Add this block
                    gnssControlCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic) // Enable notifications for GNSS Control
                    print("GNSS Control Characteristic found: \(characteristic.uuid)")
                    // Optionally, fetch the current mask once connected and characteristic is found
                    // fetchGNSSMask() // Consider calling this after all essential characteristics are found
                }
            }
            if txCharacteristic != nil && rxCharacteristic != nil && pvCharacteristic != nil && gnssControlCharacteristic != nil && pingTimer == nil {
                loadDirectoryEntries()
                startPingTimer()
                fetchGNSSMask() // Good place to fetch initial mask
            }
        }
    }
}

extension FlySightCore.BluetoothManager {
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

extension FlySightCore.BluetoothManager {
    public func fetchGNSSMask() {
        guard let peripheral = connectedPeripheral?.peripheral, let controlChar = gnssControlCharacteristic else {
            print("Cannot fetch GNSS mask: No connected peripheral or GNSS Control characteristic.")
            gnssMaskUpdateStatus = .failure("GNSS Control characteristic not available.")
            return
        }

        let command = Data([FlySightCore.GNSSControlOpcodes.getMask])
        print("Fetching GNSS Mask...")
        gnssMaskUpdateStatus = .pending
        peripheral.writeValue(command, for: controlChar, type: .withResponse) // Or .withoutResponse if firmware doesn't write back for reads this way
    }

    public func updateGNSSMask(newMask: UInt8) {
        guard let peripheral = connectedPeripheral?.peripheral, let controlChar = gnssControlCharacteristic else {
            print("Cannot update GNSS mask: No connected peripheral or GNSS Control characteristic.")
            gnssMaskUpdateStatus = .failure("GNSS Control characteristic not available.")
            return
        }

        let command = Data([FlySightCore.GNSSControlOpcodes.setMask, newMask])
        print("Updating GNSS Mask to: \(String(format: "0x%02X", newMask))")
        gnssMaskUpdateStatus = .pending
        peripheral.writeValue(command, for: controlChar, type: .withResponse) // Or .withoutResponse if firmware confirms via notification
    }

    private func parseLiveGNSSData(from data: Data) {
        guard data.count > 0 else {
            print("Received empty GNSS PV data.")
            return
        }

        var offset = 0
        let receivedMask = data[offset]; offset += 1
        // print("Received GNSS Live Data with mask: \(String(format: "0x%02X", receivedMask))")

        var tow: UInt32?
        // var week: UInt16? // Not in current firmware packet
        var lon: Int32?
        var lat: Int32?
        var hMSL: Int32?
        var velN: Int32?
        var velE: Int32?
        var velD: Int32?
        var hAcc: UInt32?
        var vAcc: UInt32?
        var sAcc: UInt32?
        var numSV: UInt8?

        if (receivedMask & FlySightCore.GNSSLiveMaskBits.timeOfWeek != 0) {
            guard data.count >= offset + 4 else { return }
            tow = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self) }
            offset += 4
        }

        // Week number is part of the mask definition but not included in the current firmware's GNSS_PV payload.
        // if (receivedMask & FlySightCore.GNSSLiveMaskBits.weekNumber != 0) {
        //     guard data.count >= offset + 2 else { return }
        //     week = data.subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: UInt16.self) }
        //     offset += 2
        // }

        if (receivedMask & FlySightCore.GNSSLiveMaskBits.position != 0) {
            guard data.count >= offset + 12 else { return }
            lon = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: Int32.self) }
            offset += 4
            lat = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: Int32.self) }
            offset += 4
            hMSL = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: Int32.self) }
            offset += 4
        }

        if (receivedMask & FlySightCore.GNSSLiveMaskBits.velocity != 0) {
            guard data.count >= offset + 12 else { return }
            velN = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: Int32.self) }
            offset += 4
            velE = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: Int32.self) }
            offset += 4
            velD = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: Int32.self) }
            offset += 4
        }

        if (receivedMask & FlySightCore.GNSSLiveMaskBits.accuracy != 0) {
            guard data.count >= offset + 12 else { return }
            // Note: Firmware `GNSS_BLE_Build` for accuracy seems to copy velN, velE, velD again.
            // This should be src->hAcc, src->vAcc, src->sAcc. Assuming firmware gets fixed or use as is.
            // For now, parsing as if they are hAcc, vAcc, sAcc.
            hAcc = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self) }
            offset += 4
            vAcc = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self) }
            offset += 4
            sAcc = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self) }
            offset += 4
        }

        if (receivedMask & FlySightCore.GNSSLiveMaskBits.numSV != 0) {
            guard data.count >= offset + 1 else { return }
            // Note: Firmware `GNSS_BLE_Build` for numSV seems to copy velN.
            // This should be src->numSV. Assuming firmware gets fixed or use as is.
            numSV = data[offset] // Assuming it's a UInt8
            offset += 1
        }

        DispatchQueue.main.async {
            self.liveGNSSData = FlySightCore.LiveGNSSData(mask: receivedMask,
                                                          timeOfWeek: tow,
                                                          longitude: lon, latitude: lat, heightMSL: hMSL,
                                                          velocityNorth: velN, velocityEast: velE, velocityDown: velD,
                                                          horizontalAccuracy: hAcc, verticalAccuracy: vAcc, speedAccuracy: sAcc,
                                                          numSV: numSV)
        }
    }

    private func processGNSSControlResponse(from data: Data) {
        guard data.count >= 1 else {
            print("Received empty GNSS Control response.")
            DispatchQueue.main.async {
                self.gnssMaskUpdateStatus = .failure("Empty response from device.")
            }
            return
        }

        let opcode = data[0]

        if opcode == FlySightCore.GNSSControlOpcodes.getMask {
            guard data.count >= 2 else {
                print("Invalid GET_MASK response length.")
                DispatchQueue.main.async {
                    self.gnssMaskUpdateStatus = .failure("Invalid GET_MASK response.")
                }
                return
            }
            let mask = data[1]
            DispatchQueue.main.async {
                self.currentGNSSMask = mask
                self.gnssMaskUpdateStatus = .success
                print("Successfully fetched GNSS Mask: \(String(format: "0x%02X", mask))")
            }
        } else if opcode == FlySightCore.GNSSControlOpcodes.setMask {
            guard data.count >= 2 else {
                print("Invalid SET_MASK response length.")
                DispatchQueue.main.async {
                    self.gnssMaskUpdateStatus = .failure("Invalid SET_MASK response.")
                }
                return
            }
            let status = data[1]
            DispatchQueue.main.async {
                if status == FlySightCore.GNSSControlStatus.ok {
                    // The currentGNSSMask would have been optimistically set or can be re-fetched.
                    // For simplicity, we assume the write was for the value in currentGNSSMask.
                    // Or, better, the value that was *sent* to be set.
                    // For now, we'll just mark as success. The UI should reflect the requested change.
                    self.gnssMaskUpdateStatus = .success
                    print("Successfully set GNSS Mask.")
                    // Optionally re-fetch to confirm: self.fetchGNSSMask()
                } else if status == FlySightCore.GNSSControlStatus.badLength {
                    self.gnssMaskUpdateStatus = .failure("Device reported bad length for SET_MASK.")
                    print("Failed to set GNSS Mask: Bad Length")
                } else if status == FlySightCore.GNSSControlStatus.badOpcode {
                    self.gnssMaskUpdateStatus = .failure("Device reported bad opcode for SET_MASK.")
                    print("Failed to set GNSS Mask: Bad Opcode")
                } else {
                    self.gnssMaskUpdateStatus = .failure("Unknown error from device (status: \(status)).")
                    print("Failed to set GNSS Mask: Unknown error \(status)")
                }
            }
        } else {
            print("Received unknown opcode in GNSS Control response: \(opcode)")
            DispatchQueue.main.async {
                self.gnssMaskUpdateStatus = .failure("Unknown response from device.")
            }
        }
    }
}
