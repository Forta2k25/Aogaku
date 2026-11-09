//
//  AffiliateLink.swift
//  Aogaku
//
//  アフィリエイト（A8.net）の広告リンク。
//  Firestore の careerListings に次のフィールドで入る（scripts/add_career_listing.js の --a8 で登録）:
//    affiliateNetwork: "a8"
//    affiliateUrl: "https://px.a8.net/svt/ejp?a8mat=..."      … 押したときに開くリンク
//    affiliateImpressionUrl: "https://www10.a8.net/0.gif?a8mat=..." … 表示したときに読む計測用画像
//

import UIKit

struct AffiliateLink: Hashable {
    enum Network: String {
        case a8
    }

    let network: Network
    let clickURL: URL
    let impressionURL: URL?

    /// 想定外のホストは受け付けない（Firestore の値をそのまま開かないため）
    init?(network rawNetwork: String?, clickUrl: String?, impressionUrl: String?) {
        guard let raw = rawNetwork, let network = Network(rawValue: raw),
              let click = clickUrl.flatMap(URL.init(string:)),
              click.scheme == "https", Self.isAllowedClickHost(click.host, network: network)
        else { return nil }

        self.network = network
        self.clickURL = click

        if let imp = impressionUrl.flatMap(URL.init(string:)),
           imp.scheme == "https", Self.isAllowedImpressionHost(imp.host, network: network) {
            self.impressionURL = imp
        } else {
            self.impressionURL = nil
        }
    }

    private static func isAllowedClickHost(_ host: String?, network: Network) -> Bool {
        switch network {
        case .a8: return host == "px.a8.net"
        }
    }

    private static func isAllowedImpressionHost(_ host: String?, network: Network) -> Bool {
        guard let host else { return false }
        switch network {
        // 例: www10.a8.net, www14.a8.net（広告ごとに番号が違う）
        case .a8: return host.range(of: #"^www\d*\.a8\.net$"#, options: .regularExpression) != nil
        }
    }
}

/// 表示計測とクリック
enum AffiliateTracker {
    /// アプリを起動している間、同じ掲載の表示は1回だけ数える
    private static var countedImpressions = Set<String>()
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    static func recordImpression(listingID: String, link: AffiliateLink) {
        guard let url = link.impressionURL else { return }
        guard countedImpressions.insert(listingID).inserted else { return }
        session.dataTask(with: url) { _, _, _ in }.resume()
    }

    /// 広告リンクは Safari で開く（アプリ内ブラウザだと、あとで Safari から申し込んだときに成果が付かないため）
    static func open(listingID: String, link: AffiliateLink) {
        AppAnalytics.logCareerApplyClick(jobID: listingID, affiliateNetwork: link.network.rawValue)
        UIApplication.shared.open(link.clickURL)
    }
}
