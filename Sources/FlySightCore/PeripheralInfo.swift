//
//  PeripheralInfo.swift
//  
//
//  Created by Michael Cooper on 2024-05-25.
//

import Foundation
import CoreBluetooth

public extension FlySightCore {
    struct PeripheralInfo: Identifiable {
        public let peripheral: CBPeripheral
        public var rssi: Int
        public var name: String
        public var isConnected: Bool = false
        public var id: UUID {
            peripheral.identifier
        }
        
        public init(peripheral: CBPeripheral, rssi: Int, name: String, isConnected: Bool = false) {
            self.peripheral = peripheral
            self.rssi = rssi
            self.name = name
            self.isConnected = isConnected
        }
    }
}
