//
//  FitTrackr_1App.swift
//  FitTrackr.1
//
//  Created by 李知宸 on 11/08/2025.
//

import SwiftUI
import UIKit

// 竖屏锁兜底:app 层 supportedInterfaceOrientationsFor 恒返回 .portrait(iPhone/iPad 都锁)。
// 这是「横屏进不去/不会回不来」的根本保障(Info.plist 只是声明,这层是运行时权威)。
class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }
}

@main
struct FitTrackr_1App: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            AppShellView()
        }
    }
}
