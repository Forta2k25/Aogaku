//
//  DeepLinkRouter.swift
//  Aogaku
//
//  Created by shu m on 2025/09/18.
//
import UIKit

enum DeepLinkRouter {
    static func handle(_ url: URL, window: UIWindow?) -> Bool {
        // スキーム確認
        guard url.scheme == "aogaku" else { return false }

        // パス/ホストが timetable のときに反応
        let path = (url.host ?? "") + url.path // "timetable", "/timetable" などに対応
        guard path.contains("timetable") else { return false }

        // ?day=today / ?day=0..5 を解釈（0=月, ... 5=土 などアプリ側ルールに合わせて）
        var dayIndex: Int?
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let v = comps.queryItems?.first(where: { $0.name == "day" })?.value {
            if v == "today" {
                let w = Calendar.current.component(.weekday, from: Date()) // 1=Sun..7=Sat
                dayIndex = (w + 5) % 7   // 0=Mon..6=Sun に変換（必要に応じて調整）
                if dayIndex == 6 { dayIndex = nil } // 例：日曜は未使用なら nil
            } else {
                dayIndex = Int(v)
            }
        }

        DispatchQueue.main.async {
            openTimetable(in: window, dayIndex: dayIndex)
        }
        return true
    }

    private static func openTimetable(in window: UIWindow?, dayIndex: Int?) {
        guard let root = window?.rootViewController else { return }

        // タブ構成なら「時間割」タブに切替
        if let tab = root as? UITabBarController {
            // 適切な index に直してね（時間割が 0 番なら 0）
            tab.selectedIndex = 0
            // 探して呼び出し
            if let tt = findTimetable(from: tab.selectedViewController) {
                ttJump(tt, to: dayIndex)
            }
            return
        }

        // 直接 UINavigationController の場合など
        if let tt = findTimetable(from: root) { ttJump(tt, to: dayIndex) }
    }

    private static func findTimetable(from vc: UIViewController?) -> timetable? {
        if let tt = vc as? timetable { return tt }
        if let nav = vc as? UINavigationController { return nav.viewControllers.compactMap({ $0 as? timetable }).first }
        if let tab = vc as? UITabBarController {
            return tab.viewControllers?.compactMap { findTimetable(from: $0) }.first
        }
        return vc?.children.compactMap { findTimetable(from: $0) }.first
    }

    private static func ttJump(_ tt: timetable, to dayIndex: Int?) {
        // 今は「時間割を開く」だけで十分なら何もしないでOK。
        // 将来、曜日にスクロール等をしたい場合に備えて hook を用意
        // 例）tt.scrollTo(day: dayIndex) を用意して呼ぶ
    }
}
