//
//  PeriodTime.swift
//  Aogaku
//
//  Created by shu m on 2025/09/18.
//

import Foundation

struct PeriodTime {
    struct Slot { let start: String; let end: String }
    static let slots: [Slot] = [
        .init(start: "09:00", end: "10:30"), // 1
        .init(start: "11:00", end: "12:30"), // 2
        .init(start: "13:20", end: "14:50"), // 3
        .init(start: "15:05", end: "16:35"), // 4
        .init(start: "16:50", end: "18:20"), // 5
        .init(start: "18:30", end: "20:00"), // 6
        .init(start: "20:10", end: "21:40")  // 7
    ]
}
