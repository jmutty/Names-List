import SwiftUI
import AppKit

// MARK: - Component Views
struct FolderSelectionView: View {
	@Binding var showingPicker: Bool
	@Environment(\.horizontalSizeClass) var horizontalSizeClass

	var body: some View {
		VStack(spacing: 24) {
			Spacer()

			Image(systemName: "folder.badge.plus")
				.font(.system(size: horizontalSizeClass == .compact ? 48 : 64))
				.foregroundStyle(
					.linearGradient(
						colors: [.accentColor, .accentColor.opacity(0.7)],
						startPoint: .topLeading,
						endPoint: .bottomTrailing
					)
				)

			VStack(spacing: 8) {
				Text("Select Job Folder")
					.font(.title2)
					.fontWeight(.semibold)

				Text("Choose your job folder to begin")
					.font(.callout)
					.foregroundColor(.secondary)
			}

			Button(action: { showingPicker = true }) {
				Text("Choose Folder")
					.frame(maxWidth: 200)
					.padding(.vertical, 12)
			}
			.buttonStyle(.borderedProminent)
			.controlSize(.large)

			Spacer()
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.padding()
	}
}

struct FolderHeaderView: View {
	let folderName: String
	let onChangeTapped: () -> Void
	let onSettingsTapped: () -> Void
	@EnvironmentObject var appState: AppStateManager
	@Environment(\.horizontalSizeClass) var horizontalSizeClass
	@State private var viewWidth: CGFloat = 0
	
	private var isNarrowLayout: Bool {
		DesignSystem.isNarrowLayout(width: viewWidth)
	}

	var body: some View {
		VStack(spacing: isNarrowLayout ? DesignSystem.microSpacing : 8) {
			ModernCard {
					HStack(spacing: isNarrowLayout ? DesignSystem.microSpacing : (horizontalSizeClass == .compact ? 6 : 10)) {
						Image(systemName: "folder.fill")
							.foregroundStyle(.tint)
							.font(.system(size: isNarrowLayout ? DesignSystem.IconSizes.narrowMedium : DesignSystem.IconSizes.medium))

					Text(folderName)
						.font(.system(size: isNarrowLayout ? DesignSystem.FontSizes.caption : DesignSystem.FontSizes.callout).weight(.semibold))
						.lineLimit(1)
						.truncationMode(.middle)

					Spacer()
					
					// Photographer Mode Indicator - responsive
					PhotographerModeIndicator(isCompact: isNarrowLayout || horizontalSizeClass == .compact)
						.environmentObject(appState)

					Button(action: onSettingsTapped) {
						Image(systemName: "gearshape.fill")
							.font(.system(size: isNarrowLayout ? DesignSystem.IconSizes.narrowSmall : DesignSystem.IconSizes.small).weight(.semibold))
							.padding(isNarrowLayout ? DesignSystem.microPadding : (horizontalSizeClass == .compact ? 4 : 6))
							.background(Color.secondary.opacity(0.12))
							.clipShape(Circle())
					}
					.buttonStyle(.plain)
					.help("Settings")

					Button(action: onChangeTapped) {
						Image(systemName: "arrow.left.arrow.right")
							.font(.system(size: isNarrowLayout ? DesignSystem.IconSizes.narrowSmall : DesignSystem.IconSizes.small).weight(.semibold))
							.padding(isNarrowLayout ? DesignSystem.microPadding : 4)
							.background(Color.accentColor.opacity(0.12))
							.clipShape(Circle())
					}
					.buttonStyle(.plain)
					.help("Change Folder")
				}
				.padding(DesignSystem.adaptivePadding(for: viewWidth))
			}
		}
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

// MARK: - Photographer Mode Indicator
struct PhotographerModeIndicator: View {
	@EnvironmentObject var appState: AppStateManager
	let isCompact: Bool
	
	init(isCompact: Bool = false) {
		self.isCompact = isCompact
	}
	
	var body: some View {
		let teamCount = appState.parseTeamIDs(appState.teamPhotographerIDsStorage).count
		let isTeamMode = !appState.skipPhotographerSetup
		let displayID = appState.photographerID.isEmpty ? "No ID" : appState.photographerID
		
		HStack(spacing: isCompact ? 2 : 4) {
			Image(systemName: isTeamMode ? "person.2.fill" : "person.fill")
				.font(.system(size: isCompact ? DesignSystem.IconSizes.narrowMini : DesignSystem.IconSizes.small))
				.foregroundColor(isTeamMode ? .accentColor : .orange)
			
			if !isCompact {
				Text(displayID)
					.font(.system(size: DesignSystem.FontSizes.caption2).weight(.medium))
					.foregroundColor(.primary)
					.lineLimit(1)
				
				if isTeamMode && teamCount > 0 {
					Text("+\(teamCount)")
						.font(.system(size: DesignSystem.FontSizes.caption2).weight(.bold))
						.foregroundColor(.accentColor)
				}
			} else {
				// Compact mode: just show team count if applicable
				if isTeamMode && teamCount > 0 {
					Text("\(teamCount + 1)")
						.font(.system(size: DesignSystem.FontSizes.caption2).weight(.bold))
						.foregroundColor(.accentColor)
				}
			}
		}
		.padding(.horizontal, isCompact ? DesignSystem.microPadding : DesignSystem.narrowPadding)
		.padding(.vertical, isCompact ? 2 : 3)
		.background(
			Group {
				if isTeamMode {
					Color.accentColor.opacity(0.1)
				} else {
					Color.orange.opacity(0.1)
				}
			}
		)
		.clipShape(Capsule())
		.help(isTeamMode ? "Team Mode: \(displayID) + \(teamCount) others" : "Solo Mode: \(displayID)")
	}
}

struct CopiedBanner: View {
	let text: String

	var body: some View {
		HStack(spacing: 10) {
			Image(systemName: "checkmark.circle.fill")
				.foregroundColor(.green)
				.font(.largeTitle)
			Text("Copied")
				.font(.largeTitle.weight(.semibold))
		}
		.padding(.horizontal, 24)
		.padding(.vertical, 16)
		.background(.ultraThinMaterial)
		.clipShape(Capsule())
		.overlay(
			Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1)
		)
		.shadow(color: .black.opacity(0.12), radius: 8, y: 4)
	}
}

struct FullScreenCopiedBanner: View {
	let text: String
	var playerName: String? = nil
	@State private var isPulsing = false

	var body: some View {
		ZStack {
			LinearGradient(
				colors: isPulsing ? [.green, .mint] : [.accentColor, .green],
				startPoint: .topLeading,
				endPoint: .bottomTrailing
			)
			.ignoresSafeArea()
			.animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isPulsing)

			VStack(spacing: 16) {
				Image(systemName: "checkmark.seal.fill")
					.font(.system(size: 140, weight: .bold))
					.symbolRenderingMode(.palette)
					.foregroundStyle(.white, .white.opacity(0.9))

				Text("COPIED!")
					.font(.system(size: 56, weight: .heavy, design: .rounded))
					.foregroundColor(.white)
					.shadow(color: .black.opacity(0.25), radius: 6, y: 2)

				if let name = playerName, !name.isEmpty {
					Text(name)
						.font(.system(size: 24, weight: .semibold))
						.foregroundColor(.white)
						.lineLimit(2)
						.truncationMode(.middle)
						.multilineTextAlignment(.center)
						.padding(.horizontal, 24)
				}

				if !text.isEmpty {
					Text(text)
						.font(.system(size: 18, weight: .medium, design: .monospaced))
						.foregroundColor(.white.opacity(0.95))
						.multilineTextAlignment(.center)
						.lineLimit(3)
						.minimumScaleFactor(0.7)
						.padding(.horizontal, 28)
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.transition(.opacity.combined(with: .scale))
		.onAppear { isPulsing = true }
	}
}

// MARK: - Arrow Key Handler
struct ArrowKeyHandler: NSViewRepresentable {
	let isEnabled: Bool
	let onLeft: () -> Void
	let onRight: () -> Void

	func makeNSView(context: Context) -> ArrowKeyView {
		let view = ArrowKeyView()
		view.onLeft = onLeft
		view.onRight = onRight
		view.setEnabled(isEnabled)
		return view
	}

	func updateNSView(_ nsView: ArrowKeyView, context: Context) {
		nsView.onLeft = onLeft
		nsView.onRight = onRight
		nsView.setEnabled(isEnabled)
	}
}

final class ArrowKeyView: NSView {
	var onLeft: (() -> Void)?
	var onRight: (() -> Void)?
	private var monitor: Any?
	private var enabled = true
	private let instanceID = UUID()

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		Logger.log("⌨️ ArrowKeyView[\(instanceID)] moved to window: installing monitor")
		installMonitor()
	}

	deinit {
		Logger.log("⌨️ ArrowKeyView[\(instanceID)] deinit: removing monitor")
		removeMonitor()
	}

	private func installMonitor() {
		removeMonitor()
		monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard let self else { return event }
			if self.enabled && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
				if event.keyCode == 123 {
					self.onLeft?()
					Logger.log("⌨️ ArrowKeyView[\(self.instanceID)] handled ←")
					return nil
				}
				if event.keyCode == 124 {
					self.onRight?()
					Logger.log("⌨️ ArrowKeyView[\(self.instanceID)] handled →")
					return nil
				}
			}
			return event
		}
		if monitor != nil { Logger.log("⌨️ ArrowKeyView[\(instanceID)] monitor installed") }
	}

	private func removeMonitor() {
		if let monitor {
			NSEvent.removeMonitor(monitor)
			self.monitor = nil
			Logger.log("⌨️ ArrowKeyView[\(instanceID)] monitor removed")
		}
	}

	func setEnabled(_ enabled: Bool) {
		self.enabled = enabled
		if enabled {
			Logger.log("⌨️ ArrowKeyView[\(instanceID)] enabling")
			installMonitor()
		} else {
			Logger.log("⌨️ ArrowKeyView[\(instanceID)] disabling")
			removeMonitor()
		}
	}
}

// MARK: - Folder Picker
struct FolderPicker: View {
	@ObservedObject var appState: AppStateManager
	@Binding var isPresented: Bool

	var body: some View {
		VStack {
			Text("Select Job Folder")
				.font(.headline)
				.padding()

			Spacer()

			Text("Choose a folder containing your job files")
				.foregroundColor(.secondary)
				.multilineTextAlignment(.center)
				.padding()

			Button("Select Folder") {
				selectFolder()
			}
			.buttonStyle(.borderedProminent)
			.padding()

			Spacer()
		}
		.frame(minWidth: 300, minHeight: 200)
	}

	private func selectFolder() {
		let openPanel = NSOpenPanel()
		openPanel.canChooseFiles = false
		openPanel.canChooseDirectories = true
		openPanel.allowsMultipleSelection = false
		openPanel.canCreateDirectories = true
		openPanel.title = "Select Job Folder"

		if openPanel.runModal() == .OK, let url = openPanel.url {
			appState.selectJobFolder(url)
			isPresented = false
		}
	}
}

// MARK: - Joke Bar View
struct JokeBarView: View {
	@EnvironmentObject var appState: AppStateManager

	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: "face.smiling")
				.foregroundColor(.accentColor)
				.font(.system(size: DesignSystem.IconSizes.small))
			Text(appState.currentJoke.isEmpty ? "Tap a name to see a joke!" : appState.currentJoke)
				.font(.footnote)
				.lineLimit(2)
				.truncationMode(.tail)
		}
		.padding(10)
		.background(Color(NSColor.controlBackgroundColor))
		.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 8, style: .continuous)
				.strokeBorder(Color.accentColor.opacity(0.15), lineWidth: 1)
		)
		.contentShape(Rectangle())
		.onTapGesture { appState.nextJoke() }
		.padding(.horizontal, 12)
		.padding(.bottom, 10)
	}
}


