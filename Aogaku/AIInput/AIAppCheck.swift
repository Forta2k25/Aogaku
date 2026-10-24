import FirebaseCore
import FirebaseAppCheck
import Foundation
import DeviceCheck

final class AIAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        if #available(iOS 14.0, *), DCAppAttestService.shared.isSupported { return AppAttestProvider(app: app) }
        return DeviceCheckProvider(app: app)
    }
}
enum AIAppCheck {
    static func prepare() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["AOGAKU_APP_CHECK_DEBUG"] == "1" {
            AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory()); return
        }
        #endif
        AppCheck.setAppCheckProviderFactory(AIAppCheckProviderFactory())
    }
}
