//
//  Names_ListApp.swift
//  Names List
//
//  Created by 207 Photo on 8/3/25.
//

import SwiftUI

@main
struct Names_ListApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 323, height: 1019)
        .defaultPosition(.init(x: 1400, y: 60))
    }
}
