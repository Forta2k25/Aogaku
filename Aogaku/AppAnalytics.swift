import Foundation
import FirebaseAnalytics

enum AppAnalytics {
    enum Tab: String {
        case timetable
        case syllabus
        case moodle
        case circles
        case friends
        case settings
        case other
    }

    static func logAppLaunch() {
        log("app_launch")
    }

    static func logTabView(_ tab: Tab, index: Int) {
        log("tab_view", parameters: [
            "tab_name": tab.rawValue,
            "tab_index": index
        ])
    }

    static func logCareerListView() {
        log("career_list_view")
    }

    static func logCareerDetailView(jobID: String, companyID: String? = nil) {
        var parameters: [String: Any] = ["job_id": jobID]
        if let companyID {
            parameters["company_id"] = companyID
        }
        log("career_detail_view", parameters: parameters)
    }

    static func logCareerSave(jobID: String, companyID: String? = nil) {
        var parameters: [String: Any] = ["job_id": jobID]
        if let companyID {
            parameters["company_id"] = companyID
        }
        log("career_save", parameters: parameters)
    }

    static func logCareerApplyClick(jobID: String, companyID: String? = nil) {
        var parameters: [String: Any] = ["job_id": jobID]
        if let companyID {
            parameters["company_id"] = companyID
        }
        log("career_apply_click", parameters: parameters)
    }

    static func logCircleListView() {
        log("circle_list_view")
    }

    static func logCircleDetailView(circleID: String) {
        log("circle_detail_view", parameters: ["circle_id": circleID])
    }

    static func logScreenView(_ screenName: String, screenClass: String? = nil) {
        var parameters: [String: Any] = [
            AnalyticsParameterScreenName: screenName
        ]
        if let screenClass {
            parameters[AnalyticsParameterScreenClass] = screenClass
        }
        Analytics.logEvent(AnalyticsEventScreenView, parameters: parameters)
    }

    static func log(_ name: String, parameters: [String: Any]? = nil) {
        Analytics.logEvent(name, parameters: parameters)
        #if DEBUG
        if let parameters {
            print("[Analytics]", name, parameters)
        } else {
            print("[Analytics]", name)
        }
        #endif
    }
}
