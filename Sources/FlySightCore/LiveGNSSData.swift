//
//  LiveGNSSData.swift
//
//
//  Created by Michael Cooper on 2025-05-16.
//

import Foundation

public extension FlySightCore {
    struct LiveGNSSData {
        public let mask: UInt8

        public var timeOfWeek: UInt32?
        // public var weekNumber: UInt16? // Placeholder, not in current firmware packet structure
        public var longitude: Int32?
        public var latitude: Int32?
        public var heightMSL: Int32?
        public var velocityNorth: Int32?
        public var velocityEast: Int32?
        public var velocityDown: Int32?
        public var horizontalAccuracy: UInt32?
        public var verticalAccuracy: UInt32?
        public var speedAccuracy: UInt32?
        public var numSV: UInt8?

        public init(mask: UInt8,
                    timeOfWeek: UInt32? = nil,
                    // weekNumber: UInt16? = nil,
                    longitude: Int32? = nil,
                    latitude: Int32? = nil,
                    heightMSL: Int32? = nil,
                    velocityNorth: Int32? = nil,
                    velocityEast: Int32? = nil,
                    velocityDown: Int32? = nil,
                    horizontalAccuracy: UInt32? = nil,
                    verticalAccuracy: UInt32? = nil,
                    speedAccuracy: UInt32? = nil,
                    numSV: UInt8? = nil) {
            self.mask = mask
            self.timeOfWeek = timeOfWeek
            // self.weekNumber = weekNumber
            self.longitude = longitude
            self.latitude = latitude
            self.heightMSL = heightMSL
            self.velocityNorth = velocityNorth
            self.velocityEast = velocityEast
            self.velocityDown = velocityDown
            self.horizontalAccuracy = horizontalAccuracy
            self.verticalAccuracy = verticalAccuracy
            self.speedAccuracy = speedAccuracy
            self.numSV = numSV
        }

        // Formatted properties for UI (consider moving to ViewModel or App-level extension if preferred)
        public var formattedLatitude: String {
            guard let lat = latitude else { return "N/A" }
            return String(format: "%.7f", Double(lat) / 10_000_000.0)
        }

        public var formattedLongitude: String {
            guard let lon = longitude else { return "N/A" }
            return String(format: "%.7f", Double(lon) / 10_000_000.0)
        }

        public var formattedHeightMSL: String {
            guard let hMSL = heightMSL else { return "N/A" }
            return String(format: "%.3f m", Double(hMSL) / 1000.0)
        }

        public var formattedVelocityNorth: String {
            guard let velN = velocityNorth else { return "N/A" }
            return String(format: "%.3f m/s", Double(velN) / 1000.0)
        }

        public var formattedVelocityEast: String {
            guard let velE = velocityEast else { return "N/A" }
            return String(format: "%.3f m/s", Double(velE) / 1000.0)
        }

        public var formattedVelocityDown: String {
            guard let velD = velocityDown else { return "N/A" }
            return String(format: "%.3f m/s", Double(velD) / 1000.0)
        }

        public var formattedHorizontalAccuracy: String {
            guard let hAcc = horizontalAccuracy else { return "N/A" }
            return String(format: "%.3f m", Double(hAcc) / 1000.0)
        }

        public var formattedVerticalAccuracy: String {
            guard let vAcc = verticalAccuracy else { return "N/A" }
            return String(format: "%.3f m", Double(vAcc) / 1000.0)
        }

        public var formattedSpeedAccuracy: String {
            guard let sAcc = speedAccuracy else { return "N/A" }
            return String(format: "%.3f m/s", Double(sAcc) / 1000.0)
        }
    }
}
