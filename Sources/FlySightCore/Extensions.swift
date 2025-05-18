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

extension Data {
    func hexEncodedString(options: HexEncodingOptions = []) -> String {
        let format = options.contains(.upperCase) ? "%02hhX" : "%02hhx"
        return self.map { String(format: format, $0) }.joined()
    }
}

struct HexEncodingOptions: OptionSet {
    let rawValue: Int
    static let upperCase = HexEncodingOptions(rawValue: 1 << 0)
}
