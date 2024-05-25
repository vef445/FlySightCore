//
//  DirectoryEntry.swift
//  
//
//  Created by Michael Cooper on 2024-05-25.
//

import Foundation

public struct DirectoryEntry: Identifiable {
    public let id = UUID()
    public let size: UInt32
    public let date: Date
    public let attributes: String
    public let name: String

    public var isFolder: Bool {
        attributes.contains("d")
    }

    public var isHidden: Bool {
        attributes.contains("h")
    }

    // Helper to format the date
    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
