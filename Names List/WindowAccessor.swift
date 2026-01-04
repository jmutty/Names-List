//
//  WindowAccessor.swift
//  Names List
//
//  Created by 207 Photo on 8/3/25.
//

import SwiftUI
import AppKit

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                self.configureWindow(window)
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // No updates needed locally
    }
    
    private func configureWindow(_ window: NSWindow) {
        guard let screen = window.screen else { return }
        
        let visibleFrame = screen.visibleFrame
        let targetWidth: CGFloat = 260
        let targetHeight = visibleFrame.height
        
        // Calculate position (right side of screen)
        let xPos = visibleFrame.maxX - targetWidth
        let yPos = visibleFrame.minY
        
        // Set frame
        window.setFrame(
            NSRect(x: xPos, y: yPos, width: targetWidth, height: targetHeight),
            display: true
        )
        
        // Ensure it can't be resized wider than we want if strict enforcement is desired,
        // but for now just setting the initial size. 
        // We can also set min/max size constraints here if needed.
        window.minSize = NSSize(width: 200, height: 400) // Reasonable minimums
    }
}
