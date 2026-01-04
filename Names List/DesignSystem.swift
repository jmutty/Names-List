import SwiftUI

// MARK: - Design System
struct DesignSystem {
	// Window size constants
	static let narrowWindowWidth: CGFloat = 260
	static let narrowWindowHeight: CGFloat = 1019
	static let defaultWindowPosition = CGPoint(x: 1400, y: 60)
	
	// Responsive breakpoints
	static let narrowBreakpoint: CGFloat = 400
	static let compactBreakpoint: CGFloat = 500
	
	// Corner radius
	static let cornerRadius: CGFloat = 12
	static let compactCornerRadius: CGFloat = 8
	
	// Spacing system for different layouts
	static let spacing: CGFloat = 16
	static let compactSpacing: CGFloat = 8
	static let narrowSpacing: CGFloat = 6
	static let microSpacing: CGFloat = 4
	
	// Padding system
	static let padding: CGFloat = 12
	static let compactPadding: CGFloat = 8
	static let narrowPadding: CGFloat = 6
	static let microPadding: CGFloat = 4
	
	// Font sizes for narrow layout
	struct FontSizes {
		static let largeTitle: CGFloat = 22
		static let title: CGFloat = 18
		static let headline: CGFloat = 16
		static let body: CGFloat = 14
		static let callout: CGFloat = 13
		static let caption: CGFloat = 11
		static let caption2: CGFloat = 10
	}
	
	// Icon sizes for different layouts
	struct IconSizes {
		static let large: CGFloat = 20
		static let medium: CGFloat = 16
		static let small: CGFloat = 14
		static let mini: CGFloat = 12
		
		// Narrow layout specific sizes (larger for better touch targets)
		static let narrowLarge: CGFloat = 18
		static let narrowMedium: CGFloat = 15
		static let narrowSmall: CGFloat = 13
		static let narrowMini: CGFloat = 11
	}
	
	// Button sizes for narrow layout
	struct ButtonSizes {
		static let large: CGFloat = 40
		static let medium: CGFloat = 32
		static let small: CGFloat = 28
		static let mini: CGFloat = 24
	}

	struct Colors {
		static let primary = Color.accentColor
		static let cardBackground = Color(NSColor.controlBackgroundColor)
		static let sectionBackground = Color(NSColor.separatorColor).opacity(0.1)
		static let narrowBackground = Color(NSColor.windowBackgroundColor)
	}
	
	// Helper function to determine if we're in narrow mode
	static func isNarrowLayout(width: CGFloat) -> Bool {
		return width <= narrowBreakpoint
	}
	
	// Helper function to get appropriate spacing based on width
	static func adaptiveSpacing(for width: CGFloat) -> CGFloat {
		if width <= narrowBreakpoint {
			return narrowSpacing
		} else if width <= compactBreakpoint {
			return compactSpacing
		} else {
			return spacing
		}
	}
	
	// Helper function to get appropriate padding based on width
	static func adaptivePadding(for width: CGFloat) -> CGFloat {
		if width <= narrowBreakpoint {
			return narrowPadding
		} else if width <= compactBreakpoint {
			return compactPadding
		} else {
			return padding
		}
	}
}


