//
//  FrigateApp.swift
//  Frigate
//
//  Created by Sagar Patel on 2026-07-13.
//

import SwiftUI

@main
struct FrigateApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .task { await appModel.bootstrap() }
        }
    }
}
