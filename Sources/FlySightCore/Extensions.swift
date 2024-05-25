//
//  Extensions.swift
//
//
//  Created by Michael Cooper on 2024-05-25.
//

import Foundation

extension BinaryInteger {
    public func fileSize() -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB] // Adjust based on your needs
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(self))
    }
}
