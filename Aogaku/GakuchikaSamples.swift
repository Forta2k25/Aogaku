//
//  GakuchikaSamples.swift
//  Aogaku
//
//  DEBUG ビルドで起動引数 `-gakuchikaSamples` を付けたときだけ、ガクチカタブに出す確認用の掲載。
//  Firestore には書き込まない。
//

#if DEBUG
import Foundation

extension CareerListing {
    init(sampleID id: String, company: String, category: CareerCategory, title: String,
         location: String, compensation: String, schedule: String,
         deadlineInDays: Int?, publishedDaysAgo: Int, sponsored: Bool = false) {
        self.id = id
        self.companyName = company
        self.logoUrl = nil
        self.photoUrl = nil
        self.category = category
        self.title = title
        self.description = "確認用のサンプル掲載です。"
        self.eligibility = "全学年"
        self.location = location
        self.compensation = compensation
        self.schedule = schedule
        self.capacity = nil
        self.applicationDeadline = deadlineInDays.map { Date().addingTimeInterval(Double($0) * 86400) }
        self.applicationUrl = "https://example.com"
        self.publishedAt = Date().addingTimeInterval(-Double(publishedDaysAgo) * 86400)
        self.expiresAt = nil
        self.isTrial = false
        self.sourceName = nil
        self.isSponsored = sponsored
    }
}

enum GakuchikaSamples {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-gakuchikaSamples")
    }

    static let items: [CareerListing] = [
        CareerListing(sampleID: "seed-aoba-consulting", company: "サンプル企業A", category: .longTermIntern,
                      title: "学生のうちから事業づくりに関わる、セールス企画インターン",
                      location: "東京都渋谷区（リモート可）", compensation: "時給1,200円〜", schedule: "週2日〜",
                      deadlineInDays: 3, publishedDaysAgo: 10),
        CareerListing(sampleID: "seed-greenleaf-sns", company: "サンプル企業B", category: .shortTermIntern,
                      title: "1日でわかる、メーカーの商品企画の仕事",
                      location: "オンライン", compensation: "交通費支給", schedule: "1day",
                      deadlineInDays: 20, publishedDaysAgo: 2, sponsored: true),
        CareerListing(sampleID: "seed-nextgate-engineer", company: "サンプル企業C", category: .longTermIntern,
                      title: "エンジニア職｜自社アプリの開発をチームで",
                      location: "東京都港区", compensation: "時給1,500円〜", schedule: "週3日〜",
                      deadlineInDays: nil, publishedDaysAgo: 1),
        CareerListing(sampleID: "sample-study-1", company: "サンプル留学エージェント", category: .studyAbroad,
                      title: "春休み2週間の語学研修プログラム",
                      location: "カナダ・バンクーバー", compensation: "", schedule: "2週間",
                      deadlineInDays: 30, publishedDaysAgo: 5),
        CareerListing(sampleID: "sample-part-1", company: "サンプル塾", category: .partTime,
                      title: "個別指導の講師｜青山キャンパスから徒歩5分",
                      location: "東京都渋谷区", compensation: "時給1,800円〜", schedule: "週1日〜",
                      deadlineInDays: nil, publishedDaysAgo: 3),
    ]
}
#endif
