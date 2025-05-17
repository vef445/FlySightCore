//
//  GNSSLiveMask.swift
//
//
//  Created by Michael Cooper on 2025-05-16.
//

import Foundation

public extension FlySightCore {

    // Constants for GNSS Live Data Mask Bits, matching firmware `gnss_ble.h`
    struct GNSSLiveMaskBits {
        public static let timeOfWeek: UInt8         = 0x80 // GNSS_BLE_BIT_TOW
        public static let weekNumber: UInt8         = 0x40 // GNSS_BLE_BIT_WEEK (Note: Not currently sent by firmware in PV characteristic)
        public static let position: UInt8           = 0x20 // GNSS_BLE_BIT_POSITION
        public static let velocity: UInt8           = 0x10 // GNSS_BLE_BIT_VELOCITY
        public static let accuracy: UInt8           = 0x08 // GNSS_BLE_BIT_ACCURACY
        public static let numSV: UInt8              = 0x04 // GNSS_BLE_BIT_NUM_SV
    }

    // Constants for GNSS Control Opcodes and Status, matching firmware `gnss_ble.h`
    struct GNSSControlOpcodes {
        public static let setMask: UInt8            = 0x01 // GNSS_BLE_OP_SET_MASK
        public static let getMask: UInt8            = 0x02 // GNSS_BLE_OP_GET_MASK
    }

    struct GNSSControlStatus {
        public static let ok: UInt8                 = 0x00 // GNSS_BLE_STATUS_OK
        public static let badLength: UInt8          = 0x01 // GNSS_BLE_STATUS_BAD_LENGTH
        public static let badOpcode: UInt8          = 0x02 // GNSS_BLE_STATUS_BAD_OPCODE
    }

    enum GNSSMaskUpdateStatus: Equatable {
        case idle
        case pending
        case success
        case failure(String)
    }
}
