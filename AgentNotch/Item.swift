//
//  Item.swift
//  AgentNotch
//
//  Created by Luca Becker on 02.09.26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
