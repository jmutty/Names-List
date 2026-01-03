#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Right-Click Detector (macOS)
struct RightClickCatcher: NSViewRepresentable {
	let onRightClick: () -> Void

	func makeCoordinator() -> Coordinator { Coordinator(onRightClick: onRightClick) }

	func makeNSView(context: Context) -> NSView {
		let view = NSView()
		let recognizer = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRightClick(_:)))
		recognizer.buttonMask = 0x2 // Right mouse button
		view.addGestureRecognizer(recognizer)
		return view
	}

	func updateNSView(_ nsView: NSView, context: Context) {}

	final class Coordinator: NSObject {
		let onRightClick: () -> Void
		init(onRightClick: @escaping () -> Void) { self.onRightClick = onRightClick }
		@objc func handleRightClick(_ sender: NSClickGestureRecognizer) { onRightClick() }
	}
}
#endif


