import SwiftUI

// MARK: - Modern Card Component + Hover
struct ModernCard<Content: View>: View {
	let content: Content
	@State private var viewWidth: CGFloat = 0
	
	init(@ViewBuilder content: () -> Content) {
		self.content = content()
	}
	
	private var isNarrowLayout: Bool {
		DesignSystem.isNarrowLayout(width: viewWidth)
	}

	var body: some View {
		content
			.background(.regularMaterial)
			.clipShape(RoundedRectangle(
				cornerRadius: isNarrowLayout ? DesignSystem.compactCornerRadius : DesignSystem.cornerRadius, 
				style: .continuous
			))
			.overlay(
				RoundedRectangle(
					cornerRadius: isNarrowLayout ? DesignSystem.compactCornerRadius : DesignSystem.cornerRadius, 
					style: .continuous
				)
				.strokeBorder(.white.opacity(0.08), lineWidth: 1)
			)
			.shadow(
				color: .black.opacity(0.05), 
				radius: isNarrowLayout ? 3 : 6, 
				y: isNarrowLayout ? 1.5 : 3
			)
			.modifier(HoverElevate(isNarrow: isNarrowLayout))
			.background(
				GeometryReader { geometry in
					Color.clear
						.onAppear { viewWidth = geometry.size.width }
						.onChange(of: geometry.size.width) { _, newWidth in
							viewWidth = newWidth
						}
				}
			)
	}
}

struct HoverElevate: ViewModifier {
	let isNarrow: Bool
	@State private var isHovered = false
	
	init(isNarrow: Bool = false) {
		self.isNarrow = isNarrow
	}
	
	func body(content: Content) -> some View {
		content
			.shadow(
				color: .black.opacity(isHovered ? (isNarrow ? 0.08 : 0.12) : 0.05),
				radius: isHovered ? (isNarrow ? 6 : 12) : (isNarrow ? 3 : 6),
				y: isHovered ? (isNarrow ? 3 : 6) : (isNarrow ? 1.5 : 3)
			)
			.scaleEffect(isHovered ? (isNarrow ? 1.002 : 1.005) : 1)
			.animation(.spring(response: 0.28, dampingFraction: 0.9), value: isHovered)
			.onHover { isHovered = $0 }
	}
}

// MARK: - WrappingHStack Layout
struct WrappingHStack: Layout {
	var horizontalSpacing: CGFloat = 8
	var verticalSpacing: CGFloat = 8

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let maxWidth = proposal.width ?? .infinity
		var currentX: CGFloat = 0
		var currentY: CGFloat = 0
		var lineHeight: CGFloat = 0
		var totalWidth: CGFloat = 0

		for subview in subviews {
			let size = subview.sizeThatFits(.unspecified)
			if currentX > 0 && currentX + size.width > maxWidth {
				currentY += lineHeight + verticalSpacing
				totalWidth = max(totalWidth, currentX - horizontalSpacing)
				currentX = 0
				lineHeight = 0
			}
			currentX += size.width + horizontalSpacing
			lineHeight = max(lineHeight, size.height)
		}

		totalWidth = max(totalWidth, currentX > 0 ? currentX - horizontalSpacing : 0)
		let totalHeight = currentY + (lineHeight > 0 ? lineHeight : 0)
		return CGSize(width: totalWidth, height: totalHeight)
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		let maxWidth = bounds.width
		var currentX: CGFloat = bounds.minX
		var currentY: CGFloat = bounds.minY
		var lineHeight: CGFloat = 0

		for subview in subviews {
			let size = subview.sizeThatFits(.unspecified)
			if currentX > bounds.minX && currentX + size.width > bounds.maxX {
				currentY += lineHeight + verticalSpacing
				currentX = bounds.minX
				lineHeight = 0
			}
			subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
			currentX += size.width + horizontalSpacing
			lineHeight = max(lineHeight, size.height)
		}
	}
}

// MARK: - Responsive Button Style
struct ResponsiveButtonStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.scaleEffect(configuration.isPressed ? 0.97 : 1)
			.animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
	}
}

// MARK: - Helper Views
struct TitleOnlyLabelStyle: LabelStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.title
	}
}


