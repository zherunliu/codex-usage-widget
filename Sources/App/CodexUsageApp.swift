import Foundation
import SwiftUI

@main
struct CodexUsageApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
                .environment(\.locale, Locale(identifier: "en_US"))
        } label: {
            Label(model.remainingText, systemImage: "gauge.medium")
        }
        .menuBarExtraStyle(.window)
    }
}
