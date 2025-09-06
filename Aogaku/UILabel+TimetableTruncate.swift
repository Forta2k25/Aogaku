//
//  UILabel+TimetableTruncate.swift
//  Aogaku
//
//  Created by shu m on 2025/09/02.
//

import UIKit

extension UILabel {
    /// 時間割コマ用：高さを増やさず末尾「…」で切る
    func timetableTruncate(maxLines: Int) {
        numberOfLines = maxLines
        lineBreakMode = .byTruncatingTail
        allowsDefaultTighteningForTruncation = true
        adjustsFontSizeToFitWidth = false
        minimumScaleFactor = 1.0

        // ラベルが縦にコマを押し広げないよう優先度を下げる
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }
}
