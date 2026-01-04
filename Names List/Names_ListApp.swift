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
                .background(WindowAccessor())
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 260, height: 1000)
        .defaultPosition(.topTrailing)
    }
}
