import SwiftUI
import AppKit

// MARK: - Counter Allocation Strategy
enum CounterStrategy: String, CaseIterable, Codable {
	case photographerID = "photographer_id"
	case oddEven = "odd_even"
	case range = "range"
	
	var displayName: String {
		switch self {
		case .photographerID: return "Photographer ID Suffix"
		case .oddEven: return "Odd/Even Split"
		case .range: return "Number Range"
		}
	}
	
	var description: String {
		switch self {
		case .photographerID: return "Each photographer uses their ID as a suffix (e.g., Subject1Jeremiah, Subject2Ryan)"
		case .oddEven: return "Photographer A uses odd numbers (1,3,5...), Photographer B uses even numbers (2,4,6...)"
		case .range: return "Each photographer gets a specific number range (e.g., 1-500 vs 501-1000)"
		}
	}
}

struct CounterAllocation: Codable {
	let strategy: CounterStrategy
	let photographers: [String]
	let photographerRanges: [String: ClosedRange<Int>]?
	
	// Legacy support for existing two-photographer setups
	let photographerA: String?
	let photographerB: String?
	let rangeA: ClosedRange<Int>?
	let rangeB: ClosedRange<Int>?
	
	// New initializer for multiple photographers with ID strategy
	init(strategy: CounterStrategy, photographers: [String]) {
		self.strategy = strategy
		self.photographers = photographers
		self.photographerRanges = nil
		self.photographerA = nil
		self.photographerB = nil
		self.rangeA = nil
		self.rangeB = nil
	}
	
	// Legacy initializer for two-photographer setups
	init(strategy: CounterStrategy, photographerA: String, photographerB: String, rangeA: ClosedRange<Int>? = nil, rangeB: ClosedRange<Int>? = nil) {
		self.strategy = strategy
		self.photographers = [photographerA, photographerB]
		self.photographerRanges = nil
		self.photographerA = photographerA
		self.photographerB = photographerB
		self.rangeA = rangeA
		self.rangeB = rangeB
	}
	
	// New initializer for multiple photographers with ranges
	init(strategy: CounterStrategy, photographers: [String], ranges: [String: ClosedRange<Int>]) {
		self.strategy = strategy
		self.photographers = photographers
		self.photographerRanges = ranges
		self.photographerA = nil
		self.photographerB = nil
		self.rangeA = nil
		self.rangeB = nil
	}
	
	func isValidCounter(_ counter: Int, for photographerID: String) -> Bool {
		switch strategy {
		case .photographerID:
			// With photographer ID strategy, all counters are valid since naming is handled by ID suffix
			return true
		case .oddEven:
			// Legacy support
			let isPhotographerA = photographerID == (photographerA ?? photographers.first)
			let isOdd = counter % 2 == 1
			return isPhotographerA ? isOdd : !isOdd
		case .range:
			// Check new range system first, then fall back to legacy
			if let ranges = photographerRanges, let range = ranges[photographerID] {
				return range.contains(counter)
			} else if photographerID == photographerA, let range = rangeA {
				return range.contains(counter)
			} else if photographerID == photographerB, let range = rangeB {
				return range.contains(counter)
			}
			return false
		}
	}

	func getPreviousValidCounter(_ currentCounter: Int, for photographerID: String) -> Int {
		switch strategy {
		case .photographerID:
			return max(currentCounter - 1, 1)
		case .oddEven:
			let isPhotographerA = photographerID == (photographerA ?? photographers.first)
			let minValue = isPhotographerA ? 1 : 2
			if currentCounter <= minValue { return minValue }
			// Step back two to keep parity
			let stepBack = currentCounter - 2
			return max(stepBack, minValue)
		case .range:
			if let ranges = photographerRanges, let range = ranges[photographerID] {
				return max(currentCounter - 1, range.lowerBound)
			} else if photographerID == photographerA, let range = rangeA {
				return max(currentCounter - 1, range.lowerBound)
			} else if photographerID == photographerB, let range = rangeB {
				return max(currentCounter - 1, range.lowerBound)
			}
			return max(currentCounter - 1, 1)
		}
	}
	
	func getNextValidCounter(_ currentCounter: Int, for photographerID: String) -> Int {
		switch strategy {
		case .photographerID:
			// With photographer ID strategy, just increment normally since naming is handled by ID suffix
			return currentCounter + 1
		case .oddEven:
			// Legacy support
			let isPhotographerA = photographerID == (photographerA ?? photographers.first)
			if isPhotographerA {
				// Use odd numbers: if current is even, add 1; if odd, add 2
				return currentCounter % 2 == 0 ? currentCounter + 1 : currentCounter + 2
			} else {
				// Use even numbers: if current is odd, add 1; if even, add 2
				return currentCounter % 2 == 1 ? currentCounter + 1 : currentCounter + 2
			}
		case .range:
			// Check new range system first, then fall back to legacy
			if let ranges = photographerRanges, let range = ranges[photographerID] {
				return max(currentCounter + 1, range.lowerBound)
			} else if photographerID == photographerA, let range = rangeA {
				return max(currentCounter + 1, range.lowerBound)
			} else if photographerID == photographerB, let range = rangeB {
				return max(currentCounter + 1, range.lowerBound)
			}
			return currentCounter + 1
		}
	}
	
	func getAllocationDescription(for photographerID: String) -> String {
		switch strategy {
		case .photographerID:
			return "Using photographer ID: \(photographerID)"
		case .oddEven:
			// Legacy support
			let isPhotographerA = photographerID == (photographerA ?? photographers.first)
			return isPhotographerA ? "Odd numbers (1, 3, 5...)" : "Even numbers (2, 4, 6...)"
		case .range:
			// Check new range system first, then fall back to legacy
			if let ranges = photographerRanges, let range = ranges[photographerID] {
				return "Range: \(range.lowerBound)-\(range.upperBound)"
			} else if photographerID == photographerA, let range = rangeA {
				return "Range: \(range.lowerBound)-\(range.upperBound)"
			} else if photographerID == photographerB, let range = rangeB {
				return "Range: \(range.lowerBound)-\(range.upperBound)"
			}
			return "No allocation"
		}
	}
}

// MARK: - Manual Mode Team
struct ManualTeam: Identifiable, Codable, Equatable {
	let id: UUID
	var name: String
	var subjectCounter: Int
	var coachCounter: Int
	var buddyCounter: Int
	var managerCounter: Int

	init(name: String) {
		self.id = UUID()
		self.name = name
		self.subjectCounter = 1
		self.coachCounter = 1
		self.buddyCounter = 1
		self.managerCounter = 1
	}

	private enum CodingKeys: String, CodingKey {
		case id, name, subjectCounter, coachCounter, buddyCounter, managerCounter
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.id = try container.decode(UUID.self, forKey: .id)
		self.name = try container.decode(String.self, forKey: .name)
		self.subjectCounter = try container.decodeIfPresent(Int.self, forKey: .subjectCounter) ?? 1
		self.coachCounter = try container.decodeIfPresent(Int.self, forKey: .coachCounter) ?? 1
		self.buddyCounter = try container.decodeIfPresent(Int.self, forKey: .buddyCounter) ?? 1
		self.managerCounter = try container.decodeIfPresent(Int.self, forKey: .managerCounter) ?? 1
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(id, forKey: .id)
		try container.encode(name, forKey: .name)
		try container.encode(subjectCounter, forKey: .subjectCounter)
		try container.encode(coachCounter, forKey: .coachCounter)
		try container.encode(buddyCounter, forKey: .buddyCounter)
		try container.encode(managerCounter, forKey: .managerCounter)
	}

	mutating func incrementCounter(for type: SubjectType, allocation: CounterAllocation?, photographerID: String) -> Int {
		switch type {
		case .subject:
			let current = subjectCounter
			if let allocation = allocation {
				subjectCounter = allocation.getNextValidCounter(current, for: photographerID)
			} else {
				subjectCounter += 1
			}
			return current
		case .coach:
			let current = coachCounter
			if let allocation = allocation {
				coachCounter = allocation.getNextValidCounter(current, for: photographerID)
			} else {
				coachCounter += 1
			}
			return current
		case .manager:
			let current = managerCounter
			if let allocation = allocation {
				managerCounter = allocation.getNextValidCounter(current, for: photographerID)
			} else {
				managerCounter += 1
			}
			return current
		case .buddy:
			let current = buddyCounter
			if let allocation = allocation {
				buddyCounter = allocation.getNextValidCounter(current, for: photographerID)
			} else {
				buddyCounter += 1
			}
			return current
		}
	}

	mutating func decrementCounter(for type: SubjectType, allocation: CounterAllocation?, photographerID: String) -> Int {
		switch type {
		case .subject:
			let previous = allocation?.getPreviousValidCounter(subjectCounter, for: photographerID) ?? max(subjectCounter - 1, 1)
			subjectCounter = previous
			return subjectCounter
		case .coach:
			let previous = allocation?.getPreviousValidCounter(coachCounter, for: photographerID) ?? max(coachCounter - 1, 1)
			coachCounter = previous
			return coachCounter
		case .manager:
			let previous = allocation?.getPreviousValidCounter(managerCounter, for: photographerID) ?? max(managerCounter - 1, 1)
			managerCounter = previous
			return managerCounter
		case .buddy:
			let previous = allocation?.getPreviousValidCounter(buddyCounter, for: photographerID) ?? max(buddyCounter - 1, 1)
			buddyCounter = previous
			return buddyCounter
		}
	}

	func getCounter(for type: SubjectType) -> Int {
		switch type {
		case .subject: return subjectCounter
		case .coach: return coachCounter
		case .manager: return managerCounter
		case .buddy: return buddyCounter
		}
	}
}

// MARK: - Manual Mode Manager
class ManualModeManager: ObservableObject {
	struct RecentItem: Identifiable, Codable {
		let id: UUID
		var text: String
		var isChecked: Bool
		init(text: String, isChecked: Bool = false) {
			self.id = UUID()
			self.text = text
			self.isChecked = isChecked
		}
	}
	@Published var teams: [ManualTeam] = []
	@Published var selectedTeam: ManualTeam?
	@Published var selectedSubjectType: SubjectType = .subject
	@Published var lastCopiedText = ""
	@Published var copiedHistory: [RecentItem] = []
	@Published var heldItems: [String] = []
	@Published var heldIndex: Int = 0
	@Published var historyIndex: Int = 0
	@Published var counterAllocation: CounterAllocation?
	@Published var showingSessionSetup = false

	private var jobFolderURL: URL?
	weak var appState: AppStateManager?
	var photographerID: String { appState?.photographerID ?? "Unknown" }

	private var stateFileURL: URL? {
		guard let jobFolder = jobFolderURL else { return nil }
		return jobFolder.appendingPathComponent("manual_mode_data.json")
	}

	func setJobFolder(_ url: URL) {
		jobFolderURL = url
		loadState()
		checkSessionSetup()
	}
	
	func checkSessionSetup() {
        // Do not show any popup on first launch in Solo mode.
        // Only auto-configure when multiple photographers are present; otherwise, do nothing.
        guard counterAllocation == nil else { return }
        let allPhotographers = getAllAvailablePhotographers()
        if allPhotographers.count > 1 {
            let allocation = CounterAllocation(strategy: .photographerID, photographers: allPhotographers)
            setCounterAllocation(allocation)
        }
	}
	
	private func getAllAvailablePhotographers() -> [String] {
		guard let appState = appState else { return [photographerID] }
		
		// Get all photographer IDs from settings
		var allPhotographers = [photographerID] // Always include current photographer
		let teamPhotographers = appState.parseTeamIDs(appState.teamPhotographerIDsStorage)
		
		// Add team photographers if they're not already included
		for teamPhotographer in teamPhotographers {
			if !allPhotographers.contains(teamPhotographer) {
				allPhotographers.append(teamPhotographer)
			}
		}
		
		return allPhotographers.filter { !$0.isEmpty }
	}
	
	func setCounterAllocation(_ allocation: CounterAllocation) {
		counterAllocation = allocation
		showingSessionSetup = false
		
		// Adjust existing counters to match allocation
		for i in teams.indices {
			teams[i].subjectCounter = allocation.getNextValidCounter(0, for: photographerID)
			teams[i].coachCounter = allocation.getNextValidCounter(0, for: photographerID)
			teams[i].buddyCounter = allocation.getNextValidCounter(0, for: photographerID)
		teams[i].managerCounter = allocation.getNextValidCounter(0, for: photographerID)
		}
		
		saveState()
	}
	
	func getAllocationDescription() -> String? {
		return counterAllocation?.getAllocationDescription(for: photographerID)
	}
	
	func isCounterValid(_ counter: Int) -> Bool {
		return counterAllocation?.isValidCounter(counter, for: photographerID) ?? true
	}
	
	func syncWithSharedGroups(_ sharedGroups: [String]) {
		// Add teams from shared groups that don't exist yet (excluding "No Group")
		for groupName in sharedGroups {
			if groupName != "No Group" && !teams.contains(where: { $0.name.lowercased() == groupName.lowercased() }) {
				let team = ManualTeam(name: groupName)
				teams.append(team)
			}
		}
		// If we had no selected team and now have teams, select the first one
		if selectedTeam == nil && !teams.isEmpty {
			selectedTeam = teams.first
		}
		saveState()
	}
	
	func getTeamNames() -> [String] {
		return teams.map { $0.name }
	}

	func addTeam(_ name: String) {
		guard !name.isEmpty else { return }
		if teams.contains(where: { $0.name.lowercased() == name.lowercased() }) {
			return
		}
		let team = ManualTeam(name: name)
		teams.append(team)
		if selectedTeam == nil {
			selectedTeam = team
		}
		// Immediately sync to shared state
		appState?.addSharedGroup(name)
		saveState()
	}

	func selectTeam(_ team: ManualTeam) {
		selectedTeam = team
		saveState()
	}

	func deleteTeam(_ team: ManualTeam) {
		teams.removeAll { $0.id == team.id }
		if selectedTeam?.id == team.id {
			selectedTeam = teams.first
		}
		saveState()
	}

	func setSubjectType(_ type: SubjectType) {
		selectedSubjectType = type
		saveState()
	}

	func generateAndCopyNext() -> String {
		guard var team = selectedTeam else { return "" }

		let counter = team.incrementCounter(for: selectedSubjectType, allocation: counterAllocation, photographerID: photographerID)
		let text = generateName(team: team.name, type: selectedSubjectType, counter: counter)

		if let index = teams.firstIndex(where: { $0.id == team.id }) {
			teams[index] = team
			selectedTeam = team
		}

		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.setString(text, forType: .string)

		AppleScriptExecutor.executeScript(named: "Manual Data")

		lastCopiedText = text
		appendToHistory(text)
		saveState()
		return text
	}

	func stepForward() {
		guard var team = selectedTeam else { return }
		_ = team.incrementCounter(for: selectedSubjectType, allocation: counterAllocation, photographerID: photographerID)
		if let idx = teams.firstIndex(where: { $0.id == team.id }) {
			teams[idx] = team
			selectedTeam = team
			saveState()
		}
	}

	func stepBackward() {
		guard var team = selectedTeam else { return }
		_ = team.decrementCounter(for: selectedSubjectType, allocation: counterAllocation, photographerID: photographerID)
		if let idx = teams.firstIndex(where: { $0.id == team.id }) {
			teams[idx] = team
			selectedTeam = team
			saveState()
		}
	}
	
	private func generateName(team: String, type: SubjectType, counter: Int) -> String {
		if appState?.collaborationMode == .team,
		   let allocation = counterAllocation,
		   allocation.strategy == .photographerID,
		   !photographerID.isEmpty {
			return "\(team)_\(type.rawValue)\(counter)\(photographerID)_"
		}
		return "\(team)_\(type.rawValue)\(counter)_"
	}

	func getNextPreview() -> String {
		guard let team = selectedTeam else { return "Select a team" }
		let counter = team.getCounter(for: selectedSubjectType)
		if appState?.collaborationMode == .team,
		   let allocation = counterAllocation,
		   allocation.strategy == .photographerID,
		   !photographerID.isEmpty {
			return "\(selectedSubjectType.rawValue)\(counter)\(photographerID)"
		}
		return "\(selectedSubjectType.rawValue) \(counter)"
	}

	func getFullNextName() -> String {
		guard let team = selectedTeam else { return "Select a team" }
		let counter = team.getCounter(for: selectedSubjectType)
		return generateName(team: team.name, type: selectedSubjectType, counter: counter)
	}

	private func saveState() {
		guard let url = stateFileURL else { return }

		let state = ManualModeState(
			teams: teams,
			selectedTeamID: selectedTeam?.id,
			selectedSubjectType: selectedSubjectType,
			lastCopiedText: lastCopiedText,
			recentItems: copiedHistory,
			copiedHistory: nil,
			heldItems: heldItems,
			heldIndex: heldIndex,
			historyIndex: historyIndex,
			counterAllocation: counterAllocation
		)

		do {
			let encoder = JSONEncoder()
			encoder.outputFormatting = .prettyPrinted
			let data = try encoder.encode(state)
			try data.write(to: url)
		} catch {
			print("Failed to save state: \(error)")
		}
	}

	private func loadState() {
		guard let url = stateFileURL else { return }

		do {
			let data = try Data(contentsOf: url)
			let state = try JSONDecoder().decode(ManualModeState.self, from: data)
			teams = state.teams
			selectedTeam = teams.first { $0.id == state.selectedTeamID }
			selectedSubjectType = state.selectedSubjectType
			lastCopiedText = state.lastCopiedText
			if let items = state.recentItems {
				copiedHistory = items
			} else if let legacy = state.copiedHistory {
				copiedHistory = legacy.map { RecentItem(text: $0) }
			} else {
				copiedHistory = []
			}
			heldItems = state.heldItems ?? []
			heldIndex = min(max(0, state.heldIndex ?? 0), max(0, (heldItems.count - 1)))
			historyIndex = min(max(0, state.historyIndex ?? 0), max(0, (copiedHistory.count - 1)))
			counterAllocation = state.counterAllocation
		} catch {
			print("No existing state file or failed to load: \(error)")
			teams = []
			selectedTeam = nil
			lastCopiedText = ""
			copiedHistory = []
			heldItems = []
			heldIndex = 0
			historyIndex = 0
			counterAllocation = nil
		}
	}

	struct ManualModeState: Codable {
		let teams: [ManualTeam]
		let selectedTeamID: UUID?
		let selectedSubjectType: SubjectType
		let lastCopiedText: String
		let recentItems: [RecentItem]?
		let copiedHistory: [String]?
		let heldItems: [String]?
		let heldIndex: Int?
		let historyIndex: Int?
		let counterAllocation: CounterAllocation?
	}

	private func appendToHistory(_ text: String) {
		guard !text.isEmpty else { return }
		copiedHistory.insert(RecentItem(text: text), at: 0)
		if copiedHistory.count > 50 { copiedHistory.removeLast(copiedHistory.count - 50) }
		historyIndex = 0
	}

	func copyText(_ text: String) {
		guard !text.isEmpty else { return }
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.setString(text, forType: .string)
		AppleScriptExecutor.executeScript(named: "Manual Data")
		lastCopiedText = text
		saveState()
	}

	func holdCurrent() {
		let text = getFullNextName()
		guard !text.isEmpty else { return }
		hold(text: text)
	}

	func removeHeldItem(at index: Int) {
		guard heldItems.indices.contains(index) else { return }
		heldItems.remove(at: index)
		if heldItems.isEmpty {
			heldIndex = 0
		} else {
			heldIndex = min(heldIndex, heldItems.count - 1)
		}
		saveState()
	}

	func currentHeld() -> String? {
		guard !heldItems.isEmpty, heldItems.indices.contains(heldIndex) else { return nil }
		return heldItems[heldIndex]
	}

	func nextHeld() {
		guard !heldItems.isEmpty else { return }
		heldIndex = (heldIndex + 1) % heldItems.count
		saveState()
	}

	func prevHeld() {
		guard !heldItems.isEmpty else { return }
		heldIndex = (heldIndex - 1 + heldItems.count) % heldItems.count
		saveState()
	}

	func copyHeldCurrent() {
		guard let s = currentHeld() else { return }
		copyText(s)
	}

	func hold(text: String) {
		guard !text.isEmpty else { return }
		if !heldItems.contains(text) {
			heldItems.insert(text, at: 0)
			heldIndex = 0
			saveState()
		}
	}

	func currentHistory() -> String? {
		guard !copiedHistory.isEmpty, copiedHistory.indices.contains(historyIndex) else { return nil }
		return copiedHistory[historyIndex].text
	}

	func nextHistory() {
		guard !copiedHistory.isEmpty else { return }
		historyIndex = (historyIndex + 1) % copiedHistory.count
		saveState()
	}

	func prevHistory() {
		guard !copiedHistory.isEmpty else { return }
		historyIndex = (historyIndex - 1 + copiedHistory.count) % copiedHistory.count
		saveState()
	}

	func toggleRecentChecked(id: UUID) {
		if let idx = copiedHistory.firstIndex(where: { $0.id == id }) {
			copiedHistory[idx].isChecked.toggle()
			saveState()
		}
	}
}

// MARK: - Manual Mode View
struct ManualModeView: View {
	@StateObject private var manager = ManualModeManager()
	@State private var newTeamName = ""
	@State private var showCopiedBanner = false
	@State private var copiedText = ""
	@Environment(\.horizontalSizeClass) var horizontalSizeClass
	@EnvironmentObject var appState: AppStateManager

	var isCompact: Bool {
		horizontalSizeClass == .compact
	}

	var body: some View {
		ScrollView {
			VStack(spacing: isCompact ? 12 : 16) {
				// Team Management
				TeamManagementCard(
					manager: manager,
					newTeamName: $newTeamName
				)

				if manager.selectedTeam != nil {
					// Type Selection
					TypeSelectionCard(manager: manager)

					// Main Action
					MainActionCard(
						manager: manager,
						showCopiedBanner: $showCopiedBanner,
						copiedText: $copiedText
					)

					// Info Cards
					if !manager.lastCopiedText.isEmpty {
						LastCopiedCard(text: manager.lastCopiedText)
							.environmentObject(appState)
							.environmentObject(manager)
					}

					if let team = manager.selectedTeam {
						StatsCard(team: team)
					}
				}
				// Joke Bar
				JokeBarView()
					.padding(.top, 12)
					.environmentObject(appState)
			}
			.padding(isCompact ? 12 : 20)
		}
		.overlay(alignment: .center) {
			if showCopiedBanner {
				FullScreenCopiedBanner(text: copiedText)
					.transition(.scale.combined(with: .opacity))
					.animation(.spring(response: 0.3), value: showCopiedBanner)
			}
		}
		.background(
			ArrowKeyHandler(
				isEnabled: appState.currentMode == .manual,
				onLeft: { manager.stepBackward() },
				onRight: { manager.stepForward() }
			)
		)
		.onDisappear {
			// Ensure clean teardown when switching modes
			Logger.log("📤 ManualModeView.onDisappear: cleaning up")
		}
		.onAppear {
			// Set the appState reference for immediate syncing
			manager.appState = appState
			if let jobFolder = appState.jobFolderURL {
				manager.setJobFolder(jobFolder)
			}
			// Sync with shared groups from CSV mode
			manager.syncWithSharedGroups(appState.sharedGroups)
		}
		.onChange(of: appState.jobFolderURL) { _, newURL in
			// When switching jobs, reload Manual Mode state from new job folder
			if let url = newURL {
				manager.setJobFolder(url)
				// Also sync groups after switching jobs
				manager.syncWithSharedGroups(appState.sharedGroups)
			}
		}
		.onChange(of: manager.teams) { _, _ in
			// Sync manual teams back to shared state
			appState.syncGroupsFromManual(manager.getTeamNames())
		}
		.sheet(isPresented: $manager.showingSessionSetup) {
			SessionSetupView(manager: manager)
		}
	}
}

// MARK: - Component Views for Manual Mode
struct TeamManagementCard: View {
	@ObservedObject var manager: ManualModeManager
	@Binding var newTeamName: String
	@Environment(\.horizontalSizeClass) var horizontalSizeClass

	var body: some View {
		// Use standard ModernCard pattern like other components
		ModernCard {
			VStack(alignment: .leading, spacing: 12) {
				// Header with title and delete button
				HStack {
					Text("TEAMS")
						.font(.caption)
						.fontWeight(.semibold)
						.foregroundColor(.secondary)

					Spacer()

					if let team = manager.selectedTeam {
						Button(role: .destructive) {
							manager.deleteTeam(team)
						} label: {
							Image(systemName: "trash")
								.font(.caption)
								.foregroundColor(.red)
						}
						.buttonStyle(.plain)
					}
				}

				// Team grid
				if !manager.teams.isEmpty {
					TeamGrid(teams: manager.teams, selectedTeam: manager.selectedTeam) { team in
						manager.selectTeam(team)
					}
				} else {
					// Empty state - compact for narrow window
					VStack(spacing: 4) {
						Image(systemName: "person.3")
							.font(.callout)
							.foregroundColor(.secondary)
						Text("No teams yet")
							.font(.caption)
							.foregroundColor(.secondary)
						Text("Add team below")
							.font(.caption2)
							.foregroundColor(.secondary)
					}
					.padding(.vertical, 8)
				}

				// Add new team section
				HStack(spacing: 8) {
					TextField("Team name", text: $newTeamName)
						.textFieldStyle(.roundedBorder)
						.font(.caption)
						.onSubmit { addTeam() }

					Button("Add", action: addTeam)
						.buttonStyle(.borderedProminent)
						.controlSize(.small)
						.disabled(newTeamName.isEmpty)
				}
			}
			.padding(horizontalSizeClass == .compact ? 12 : 16)
		}
	}

	private func addTeam() {
		if !newTeamName.isEmpty {
			manager.addTeam(newTeamName)
			newTeamName = ""
		}
	}
}

// MARK: - Team List Component
struct TeamGrid: View {
	let teams: [ManualTeam]
	let selectedTeam: ManualTeam?
	let onTeamSelect: (ManualTeam) -> Void
	@Environment(\.horizontalSizeClass) var horizontalSizeClass

	var body: some View {
		ScrollView {
			VStack(spacing: horizontalSizeClass == .compact ? 3 : 4) {
				ForEach(teams) { team in
					TeamCard(
						team: team,
						isSelected: selectedTeam?.id == team.id,
						onTap: { onTeamSelect(team) }
					)
				}
			}
			.padding(.vertical, horizontalSizeClass == .compact ? 2 : 4)
			.padding(.horizontal, horizontalSizeClass == .compact ? 3 : 4) // Match spacing between cards
		}
		.frame(maxHeight: horizontalSizeClass == .compact ? 130 : 150) // Taller to show more teams
	}
}

struct TypeSelectionCard: View {
	@ObservedObject var manager: ManualModeManager
	@Environment(\.horizontalSizeClass) var horizontalSizeClass

	var body: some View {
		ModernCard {
			VStack(alignment: .leading, spacing: 12) {
				Text("TYPE")
					.font(.caption)
					.fontWeight(.semibold)
					.foregroundColor(.secondary)

				VStack(alignment: .leading, spacing: 8) {
					ForEach(SubjectType.allCases, id: \.self) { type in
						TypeButton(
							type: type,
							isSelected: manager.selectedSubjectType == type
						) {
							manager.setSubjectType(type)
						}
					}
				}
			}
			.padding(horizontalSizeClass == .compact ? 12 : 16)
		}
	}
}

struct TypeButton: View {
	let type: SubjectType
	let isSelected: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			HStack(spacing: 6) {
				Image(systemName: type.icon)
					.symbolRenderingMode(.hierarchical)
				Text(type.rawValue)
					.fontWeight(.semibold)
			}
			.frame(maxWidth: .infinity)
			.padding(.vertical, 8)
			.background(
				Group {
					if isSelected {
						LinearGradient(colors: [.accentColor, .accentColor.opacity(0.85)],
										   startPoint: .topLeading, endPoint: .bottomTrailing)
					} else {
						Color(NSColor.controlBackgroundColor)
					}
				}
			)
			.foregroundColor(isSelected ? .white : .primary)
			.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
			.overlay(
				RoundedRectangle(cornerRadius: 8, style: .continuous)
					.strokeBorder(isSelected ? .white.opacity(0.18) : Color.accentColor.opacity(0.2), lineWidth: 1)
			)
		}
		.buttonStyle(ResponsiveButtonStyle())
	}
}

struct CompactTypeButton: View {
	let type: SubjectType
	let isSelected: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Text(type.shortName)
				.font(.caption.weight(.semibold))
				.frame(maxWidth: .infinity)
				.padding(.vertical, 6)
				.background(
					Group {
						if isSelected {
							LinearGradient(
								colors: [.accentColor, .accentColor.opacity(0.85)],
								startPoint: .topLeading,
								endPoint: .bottomTrailing
							)
						} else {
							Color(NSColor.controlBackgroundColor)
						}
					}
				)
				.foregroundColor(isSelected ? .white : .primary)
				.clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
				.overlay(
					RoundedRectangle(cornerRadius: 6, style: .continuous)
						.strokeBorder(isSelected ? .white.opacity(0.18) : Color.accentColor.opacity(0.2), lineWidth: 1)
				)
		}
		.buttonStyle(ResponsiveButtonStyle())
	}
}

struct MainActionCard: View {
	@ObservedObject var manager: ManualModeManager
	@Binding var showCopiedBanner: Bool
	@Binding var copiedText: String
	@Environment(\.horizontalSizeClass) var horizontalSizeClass
	@State private var showFullName = false
	@EnvironmentObject var appState: AppStateManager

	var body: some View {
		Button(action: performCopy) {
			ModernCard {
				VStack(spacing: 10) {
					Text(manager.getNextPreview())
						.font(.system(
							size: horizontalSizeClass == .compact ? 22 : 30,
							weight: .bold,
							design: .monospaced
						))
						.foregroundColor(.white)
						.lineLimit(1)
						.minimumScaleFactor(0.5)
						.padding(.horizontal, 12)

					Text("Tap to copy & advance")
						.font(.caption)
						.foregroundColor(.white.opacity(0.85))

					Text("Use ←/→ to adjust next number (no copy)")
						.font(.caption2)
						.foregroundColor(.white.opacity(0.7))

					Text(manager.getFullNextName())
						.font(.caption2)
						.foregroundColor(.white.opacity(0.65))
						.lineLimit(1)
						.truncationMode(.middle)
						.padding(.horizontal, 12)
					
					// Show allocation info if configured
					if let allocation = manager.getAllocationDescription() {
						Text(allocation)
							.font(.caption2)
							.foregroundColor(.white.opacity(0.5))
							.lineLimit(1)
							.padding(.horizontal, 12)
					}
				}
				.frame(maxWidth: .infinity)
				.padding(.vertical, horizontalSizeClass == .compact ? 20 : 26)
				.background(
					LinearGradient(
						colors: [.accentColor, .accentColor.opacity(0.85)],
						startPoint: .topLeading,
						endPoint: .bottomTrailing
					)
				)
				.clipShape(RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))
				.overlay(
					RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
						.strokeBorder(.white.opacity(0.15), lineWidth: 1)
				)
			}
		}
		.buttonStyle(ResponsiveButtonStyle())
		.keyboardShortcut(.return, modifiers: [])
		// Removed per design: banner is presented at top-level in ManualModeView
	}

	private func performCopy() {
		let text = manager.generateAndCopyNext()
		copiedText = text
		appState.nextJoke()
		showCopiedBanner = true
		DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
			showCopiedBanner = false
		}
	}
}

struct LastCopiedCard: View {
	let text: String
	@Environment(\.horizontalSizeClass) var horizontalSizeClass
	@EnvironmentObject var appState: AppStateManager
	@EnvironmentObject var manager: ManualModeManager
	@State private var isExpanded = false

	var body: some View {
		ModernCard {
			VStack(alignment: .leading, spacing: 6) {
				HStack(spacing: 6) {
					Text("LAST COPIED")
						.font(.caption2)
						.fontWeight(.semibold)
						.foregroundColor(.secondary)
					Spacer()
					Button(isExpanded ? "Hide" : "Show") { isExpanded.toggle() }
						.buttonStyle(.bordered)
						.controlSize(.mini)
				}

				// Current item (always visible)
				Button(action: { manager.copyText(manager.currentHistory() ?? text) }) {
					HStack(spacing: 8) {
						Image(systemName: manager.copiedHistory.first?.isChecked == true ? "checkmark.circle.fill" : "circle")
							.foregroundColor(manager.copiedHistory.first?.isChecked == true ? .green : .secondary)
						Text(manager.currentHistory() ?? text)
							.font(.system(size: horizontalSizeClass == .compact ? 11 : 12, design: .monospaced))
							.foregroundColor(.secondary)
							.lineLimit(1)
							.truncationMode(.middle)
					}
				}
				.buttonStyle(.plain)
				.help("Click to re-copy without advancing")

				if isExpanded && !manager.copiedHistory.isEmpty {
					Divider().opacity(0.5)
					VStack(alignment: .leading, spacing: 4) {
						ForEach(manager.copiedHistory) { item in
							HStack(spacing: 8) {
								Button(action: { manager.toggleRecentChecked(id: item.id) }) {
									Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
										.foregroundColor(item.isChecked ? .green : .secondary)
								}
								.buttonStyle(.plain)

								Button(action: { manager.copyText(item.text) }) {
									Text(item.text)
										.font(.system(size: horizontalSizeClass == .compact ? 11 : 12, design: .monospaced))
										.foregroundColor(.primary)
										.lineLimit(1)
										.truncationMode(.middle)
								}
								.buttonStyle(.plain)
							}
						}
					}
				}
			}
			.padding(horizontalSizeClass == .compact ? 8 : 10)
		}
	}
}

struct StatsCard: View {
	let team: ManualTeam
	@Environment(\.horizontalSizeClass) var horizontalSizeClass

	var body: some View {
		ModernCard {
			HStack {
				StatItem(icon: "person.fill", count: team.subjectCounter - 1, label: "Subjects")
				Divider().frame(height: 40)
				StatItem(icon: "star.fill", count: team.coachCounter - 1, label: "Coaches")
				Divider().frame(height: 40)
				StatItem(icon: "briefcase.fill", count: team.managerCounter - 1, label: "Managers")
				Divider().frame(height: 40)
				StatItem(icon: "person.2.fill", count: team.buddyCounter - 1, label: "Buddies")
			}
			.padding(horizontalSizeClass == .compact ? 12 : 16)
		}
	}
}

struct StatItem: View {
	let icon: String
	let count: Int
	let label: String

	var body: some View {
		VStack(spacing: 4) {
			Image(systemName: icon)
				.font(.title3)
				.foregroundColor(.accentColor)
			Text("\(count)")
				.font(.title2)
				.fontWeight(.bold)
			Text(label)
				.font(.caption2)
				.foregroundColor(.secondary)
		}
		.frame(maxWidth: .infinity)
	}
}

// MARK: - Compact Team Card Component
struct TeamCard: View {
	let team: ManualTeam
	let isSelected: Bool
	let onTap: () -> Void
	@Environment(\.horizontalSizeClass) var horizontalSizeClass

	var body: some View {
		ModernCard {
			ZStack {
				// Centered team name - much smaller
				Text(team.name)
					.font(horizontalSizeClass == .compact ? .caption2 : .caption)
					.fontWeight(isSelected ? .semibold : .regular)
					.foregroundColor(isSelected ? .accentColor : .primary)
					.lineLimit(1)
					.multilineTextAlignment(.center)

				// Selection indicator in top-right corner
				if isSelected {
					VStack {
						HStack {
							Spacer()
							Image(systemName: "checkmark.circle.fill")
								.foregroundColor(.accentColor)
								.font(.caption2)
						}
						Spacer()
					}
				}
			}
			.padding(horizontalSizeClass == .compact ? 6 : 8)
			.padding(.vertical, horizontalSizeClass == .compact ? 2 : 3)
			.frame(minHeight: horizontalSizeClass == .compact ? 18 : 20)
			.frame(maxWidth: .infinity) // Force all cards to same width
		}
		.overlay(
			RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
				.strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : .clear, lineWidth: 1)
		)
		.shadow(color: isSelected ? Color.accentColor.opacity(0.15) : Color.black.opacity(0.05),
				radius: isSelected ? 4 : 2,
				y: isSelected ? 2 : 1)
		.onTapGesture(perform: onTap)
	}
}

// MARK: - Session Setup View
struct SessionSetupView: View {
	@ObservedObject var manager: ManualModeManager
	@Environment(\.dismiss) private var dismiss
	
	@State private var selectedStrategy: CounterStrategy = .photographerID
	@State private var photographerA = ""
	@State private var photographerB = ""
	@State private var rangeAStart = "1"
	@State private var rangeAEnd = "500"
	@State private var rangeBStart = "501"
	@State private var rangeBEnd = "1000"
	@State private var availablePhotographers: [String] = []
	
	var body: some View {
		VStack(spacing: 0) {
			// Header
			HStack {
				Text("Manual Session Setup")
					.font(.title2)
					.fontWeight(.bold)
				
				Spacer()
				
				Button("Skip") {
					// Create a default allocation using photographer ID strategy
					let allocation = CounterAllocation(
						strategy: .photographerID,
						photographers: availablePhotographers.isEmpty ? [manager.photographerID] : availablePhotographers
					)
					manager.setCounterAllocation(allocation)
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
			}
			.padding()
			.background(Color(NSColor.controlBackgroundColor))
			
			// Content
			ScrollView {
				VStack(alignment: .leading, spacing: 24) {
					// Instructions
					VStack(alignment: .leading, spacing: 8) {
						Text("Prevent Naming Conflicts")
							.font(.headline)
						
						Text("Configure how photographers will split counter numbers to avoid conflicts when working offline simultaneously.")
							.font(.body)
							.foregroundColor(.secondary)
					}
					
					// Current Photographer
					VStack(alignment: .leading, spacing: 8) {
						Text("Current Photographer")
							.font(.headline)
						
						Text("You are: \(manager.photographerID)")
							.font(.body)
							.padding()
							.background(Color.accentColor.opacity(0.1))
							.clipShape(RoundedRectangle(cornerRadius: 8))
					}
					
					// Strategy Selection
					VStack(alignment: .leading, spacing: 16) {
						Text("Counter Strategy")
							.font(.headline)
						
						VStack(spacing: 12) {
							ForEach(CounterStrategy.allCases, id: \.self) { strategy in
								StrategyCard(
									strategy: strategy,
									isSelected: selectedStrategy == strategy,
									onSelect: { selectedStrategy = strategy }
								)
							}
						}
					}
					
					// Configuration based on strategy
					if selectedStrategy == .photographerID {
						PhotographerIDConfigView(
							availablePhotographers: availablePhotographers,
							currentPhotographer: manager.photographerID
						)
					} else if selectedStrategy == .oddEven {
						OddEvenConfigView(
							photographerA: $photographerA,
							photographerB: $photographerB,
							currentPhotographer: manager.photographerID
						)
					} else {
						RangeConfigView(
							photographerA: $photographerA,
							photographerB: $photographerB,
							rangeAStart: $rangeAStart,
							rangeAEnd: $rangeAEnd,
							rangeBStart: $rangeBStart,
							rangeBEnd: $rangeBEnd,
							currentPhotographer: manager.photographerID
						)
					}
					
					// Setup button
					HStack {
						Spacer()
						
						Button("Setup Session") {
							setupSession()
						}
						.buttonStyle(.borderedProminent)
						.disabled(!isConfigurationValid)
					}
				}
				.padding()
			}
		}
		.frame(width: 600, height: 500)
		.onAppear {
			// Pre-fill with current photographer
			photographerA = manager.photographerID
			// Load available photographers
			availablePhotographers = getAllAvailablePhotographers()
			// Default to photographer ID strategy if multiple photographers available
			if availablePhotographers.count > 1 {
				selectedStrategy = .photographerID
			}
		}
	}
	
	private func getAllAvailablePhotographers() -> [String] {
		guard let appState = manager.appState else { return [manager.photographerID] }
		
		// Get all photographer IDs from settings
		var allPhotographers = [manager.photographerID] // Always include current photographer
		let teamPhotographers = appState.parseTeamIDs(appState.teamPhotographerIDsStorage)
		
		// Add team photographers if they're not already included
		for teamPhotographer in teamPhotographers {
			if !allPhotographers.contains(teamPhotographer) {
				allPhotographers.append(teamPhotographer)
			}
		}
		
		return allPhotographers.filter { !$0.isEmpty }
	}
	
	private var isConfigurationValid: Bool {
		switch selectedStrategy {
		case .photographerID:
			return !availablePhotographers.isEmpty
		case .oddEven:
			return !photographerA.isEmpty && !photographerB.isEmpty && photographerA != photographerB
		case .range:
			guard !photographerA.isEmpty && !photographerB.isEmpty && photographerA != photographerB else { return false }
			guard let aStart = Int(rangeAStart), let aEnd = Int(rangeAEnd),
				  let bStart = Int(rangeBStart), let bEnd = Int(rangeBEnd) else { return false }
			return aStart <= aEnd && bStart <= bEnd && aEnd < bStart
		}
	}
	
	private func setupSession() {
		let allocation: CounterAllocation
		
		switch selectedStrategy {
		case .photographerID:
			allocation = CounterAllocation(
				strategy: .photographerID,
				photographers: availablePhotographers
			)
		case .oddEven:
			allocation = CounterAllocation(
				strategy: .oddEven,
				photographerA: photographerA,
				photographerB: photographerB,
				rangeA: nil,
				rangeB: nil
			)
		case .range:
			guard let aStart = Int(rangeAStart), let aEnd = Int(rangeAEnd),
				  let bStart = Int(rangeBStart), let bEnd = Int(rangeBEnd) else { return }
			
			allocation = CounterAllocation(
				strategy: .range,
				photographerA: photographerA,
				photographerB: photographerB,
				rangeA: aStart...aEnd,
				rangeB: bStart...bEnd
			)
		}
		
		manager.setCounterAllocation(allocation)
	}
}

struct StrategyCard: View {
	let strategy: CounterStrategy
	let isSelected: Bool
	let onSelect: () -> Void
	
	var body: some View {
		Button(action: onSelect) {
			VStack(alignment: .leading, spacing: 8) {
				HStack {
					Text(strategy.displayName)
						.font(.subheadline)
						.fontWeight(.semibold)
					
					Spacer()
					
					if isSelected {
						Image(systemName: "checkmark.circle.fill")
							.foregroundColor(.accentColor)
					} else {
						Image(systemName: "circle")
							.foregroundColor(.secondary)
					}
				}
				
				Text(strategy.description)
					.font(.caption)
					.foregroundColor(.secondary)
					.multilineTextAlignment(.leading)
			}
			.padding()
			.background(isSelected ? Color.accentColor.opacity(0.1) : Color(NSColor.controlBackgroundColor))
			.clipShape(RoundedRectangle(cornerRadius: 8))
			.overlay(
				RoundedRectangle(cornerRadius: 8)
					.strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
			)
		}
		.buttonStyle(.plain)
	}
}

struct OddEvenConfigView: View {
	@Binding var photographerA: String
	@Binding var photographerB: String
	let currentPhotographer: String
	
	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("Photographer Assignment")
				.font(.headline)
			
			VStack(alignment: .leading, spacing: 12) {
				HStack {
					Text("Photographer A (Odd Numbers):")
						.frame(width: 200, alignment: .leading)
					TextField("Enter name", text: $photographerA)
						.textFieldStyle(.roundedBorder)
				}
				
				HStack {
					Text("Photographer B (Even Numbers):")
						.frame(width: 200, alignment: .leading)
					TextField("Enter name", text: $photographerB)
						.textFieldStyle(.roundedBorder)
				}
			}
			
			Text("You (\(currentPhotographer)) will use \(photographerA == currentPhotographer ? "odd" : "even") numbers.")
				.font(.caption)
				.foregroundColor(.secondary)
		}
	}
}

struct RangeConfigView: View {
	@Binding var photographerA: String
	@Binding var photographerB: String
	@Binding var rangeAStart: String
	@Binding var rangeAEnd: String
	@Binding var rangeBStart: String
	@Binding var rangeBEnd: String
	let currentPhotographer: String
	
	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("Range Assignment")
				.font(.headline)
			
			VStack(alignment: .leading, spacing: 12) {
				HStack {
					Text("Photographer A:")
						.frame(width: 120, alignment: .leading)
					TextField("Name", text: $photographerA)
						.textFieldStyle(.roundedBorder)
						.frame(width: 120)
					Text("Range:")
					TextField("Start", text: $rangeAStart)
						.textFieldStyle(.roundedBorder)
						.frame(width: 60)
					Text("to")
					TextField("End", text: $rangeAEnd)
						.textFieldStyle(.roundedBorder)
						.frame(width: 60)
				}
				
				HStack {
					Text("Photographer B:")
						.frame(width: 120, alignment: .leading)
					TextField("Name", text: $photographerB)
						.textFieldStyle(.roundedBorder)
						.frame(width: 120)
					Text("Range:")
					TextField("Start", text: $rangeBStart)
						.textFieldStyle(.roundedBorder)
						.frame(width: 60)
					Text("to")
					TextField("End", text: $rangeBEnd)
						.textFieldStyle(.roundedBorder)
						.frame(width: 60)
				}
			}
			
			if let aStart = Int(rangeAStart), let aEnd = Int(rangeAEnd),
			   let bStart = Int(rangeBStart), let bEnd = Int(rangeBEnd) {
				if photographerA == currentPhotographer {
					Text("You will use numbers \(aStart)-\(aEnd)")
						.font(.caption)
						.foregroundColor(.secondary)
				} else if photographerB == currentPhotographer {
					Text("You will use numbers \(bStart)-\(bEnd)")
						.font(.caption)
						.foregroundColor(.secondary)
				}
			}
		}
	}
}

// MARK: - Photographer ID Config View
struct PhotographerIDConfigView: View {
	let availablePhotographers: [String]
	let currentPhotographer: String
	
	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("Photographer ID Strategy")
				.font(.headline)
			
			Text("Each photographer will use their ID as a suffix for unique naming.")
				.font(.body)
				.foregroundColor(.secondary)
			
			VStack(alignment: .leading, spacing: 8) {
				Text("Available Photographers:")
					.font(.subheadline)
					.fontWeight(.medium)
				
				ForEach(availablePhotographers, id: \.self) { photographer in
					HStack {
						Image(systemName: photographer == currentPhotographer ? "person.fill" : "person")
							.foregroundColor(photographer == currentPhotographer ? .accentColor : .secondary)
						Text(photographer)
							.fontWeight(photographer == currentPhotographer ? .medium : .regular)
						if photographer == currentPhotographer {
							Text("(You)")
								.font(.caption)
								.foregroundColor(.accentColor)
						}
						Spacer()
					}
					.padding(.vertical, 4)
					.padding(.horizontal, 12)
					.background(photographer == currentPhotographer ? Color.accentColor.opacity(0.1) : Color.clear)
					.clipShape(RoundedRectangle(cornerRadius: 6))
				}
			}
			
			VStack(alignment: .leading, spacing: 8) {
				Text("Example Names:")
					.font(.subheadline)
					.fontWeight(.medium)
				
				ForEach(Array(availablePhotographers.prefix(3)), id: \.self) { photographer in
					Text("Team_Subject1\(photographer)_")
						.font(.system(.caption, design: .monospaced))
						.foregroundColor(.secondary)
						.padding(.leading, 12)
				}
			}
		}
		.padding()
		.background(Color(NSColor.controlBackgroundColor).opacity(0.5))
		.clipShape(RoundedRectangle(cornerRadius: 8))
	}
}

