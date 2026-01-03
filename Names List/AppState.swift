import SwiftUI
import Foundation

// MARK: - App Mode
enum AppMode: String, CaseIterable {
	case csv = "Photo Lists"
	case manual = "Manual Entry"
}

// MARK: - Collaboration
enum CollaborationMode: String, Codable {
	case solo
	case team
}

struct JobConfig: Codable {
	var collaborationMode: CollaborationMode
	var myPhotographerID: String
	var teamPhotographers: [String]
}

// MARK: - Subject Type
enum SubjectType: String, CaseIterable, Codable {
	case subject = "Subject"
	case coach = "Coach"
	case buddy = "Buddy"
	case manager = "Manager"

	var icon: String {
		switch self {
		case .subject: return "person.fill"
		case .coach: return "star.fill"
		case .buddy: return "person.2.fill"
		case .manager: return "briefcase.fill"
		}
	}

	var shortName: String {
		switch self {
		case .subject: return "Sub"
		case .coach: return "Coach"
		case .buddy: return "Buddy"
		case .manager: return "Manager"
		}
	}
}

// MARK: - Shared App State Manager
class AppStateManager: ObservableObject {
	@Published var jobFolderURL: URL?
	@Published var isJobFolderSelected = false
	@Published var detectedCSVFile: URL?
	@Published var availableCSVFiles: [URL] = []
	@Published var hasValidCSV = false
	@Published var currentMode: AppMode = .manual
	@Published var currentJoke: String = ""
	@Published var sharedGroups: [String] = []
	@Published var collaborationMode: CollaborationMode = .solo
	@Published var jobConfig: JobConfig?

	// Device Identity
	@AppStorage("photographerID") var photographerID: String = ""
	@AppStorage("skipPhotographerSetup") var skipPhotographerSetup: Bool = false
	@AppStorage("teamPhotographerIDs") var teamPhotographerIDsStorage: String = "" // comma or newline separated IDs
	@Published var showingPhotographerSetup = false

	private let jokes: [String] = [
		"What do you call a conversation between ticks? Tick talk.",
		"What were prehistoric sleepovers called? Dino-SNORES.",
		"What's a bee's favorite musical? Stinging in the Rain.",
		"What kind of cow wears a crown? A dairy queen.",
		"What do turkeys like to eat for dessert? Apple Gobbler.",
		"Why do storks have so little money? They have such big bills.",
		"Which reptile always knows what time it is? A grandfather croc.",
		"Are the moon and Earth good friends? Yes, they've been going around together for years.",
		"Can a horse join the army? No, the Neigh-vy.",
		"Can bees fly in the rain? Not without their little yellow jackets.",
		"How did the hammerhead shark do on his math test? He nailed it.",
		"How did the snake escape from jail? It scaled the wall.",
		"How do baby geese get out of their shells? They follow eggs-it signs.",
		"How do dolphins make important decisions? They flipper a coin.",
		"How do porcupines communicate? Through spine language.",
		"How do rabbits travel? In HARE-planes.",
		"How do skeletons send their mail? By bony express.",
		"How do slugs get up mountains? They slime to the top.",
		"How do snakes sign their letters? With hugs and hisses.",
		"How do you make a skeleton laugh? Tickle its funny bone."
	]
	private var shuffledJokes: [String] = []
	private var jokeIndex: Int = 0

	func selectJobFolder(_ url: URL) {
		let didStartAccessing = url.startAccessingSecurityScopedResource()
		jobFolderURL = url
		isJobFolderSelected = true
		saveJobFolderBookmark(url)

		// Clear any currently loaded CSV data from previous job
		// This is handled by the UI components watching for job folder changes

		// Load or create per-job configuration
		loadJobConfig()

		// Scan for data files (CSV/XLSX) with valid structure
		scanForValidCSV()

		if !didStartAccessing {
			Logger.warn("Warning: Could not access security scoped resource")
		}
	}

	// MARK: - Job Config (per-job)
	private func jobConfigURL() -> URL? {
		guard let jobFolderURL else { return nil }
		return jobFolderURL.appendingPathComponent("job.json")
	}

	private func migrateLegacyJobConfig() -> JobConfig {
		// Prefer explicit team list if present; otherwise use smart detection
		let existingTeam = parseTeamIDs(teamPhotographerIDsStorage)
		let detection = detectPhotographerMode()
		// Default new jobs to Solo mode; still carry detected team list for convenience
		let inferredMode: CollaborationMode = .solo
		let legacyID = photographerID
		let sanitizedID: String = (legacyID == "SingleUser" || legacyID == "TempUser") ? "" : legacyID
		let team: [String] = !existingTeam.isEmpty ? existingTeam : detection.detectedPhotographers
		return JobConfig(collaborationMode: inferredMode, myPhotographerID: sanitizedID, teamPhotographers: team)
	}

	func loadJobConfig() {
		guard let url = jobConfigURL() else { return }
		let fm = FileManager.default
		do {
			if fm.fileExists(atPath: url.path) {
				let data = try Data(contentsOf: url)
				let decoded = try JSONDecoder().decode(JobConfig.self, from: data)
				jobConfig = decoded
				// Apply to runtime state
				collaborationMode = decoded.collaborationMode
				if !decoded.myPhotographerID.isEmpty { photographerID = decoded.myPhotographerID }
				if !decoded.teamPhotographers.isEmpty { storeTeamIDs(decoded.teamPhotographers) }
			} else {
				let created = migrateLegacyJobConfig()
				jobConfig = created
				collaborationMode = created.collaborationMode
				if !created.myPhotographerID.isEmpty { photographerID = created.myPhotographerID }
				if !created.teamPhotographers.isEmpty { storeTeamIDs(created.teamPhotographers) }
				try saveJobConfig()
			}
		} catch {
			Logger.warn("⚠️ Failed to load job config: \(error)")
		}
	}

	@discardableResult
	func saveJobConfig() throws -> URL? {
		guard let url = jobConfigURL() else { return nil }
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
		let config = jobConfig ?? JobConfig(collaborationMode: collaborationMode, myPhotographerID: photographerID, teamPhotographers: parseTeamIDs(teamPhotographerIDsStorage))
		let data = try encoder.encode(config)
		try data.write(to: url, options: .atomic)
		return url
	}

	// MARK: - Job Folder Bookmark
	private let jobFolderBookmarkKey = "jobFolderBookmark.v1"

	init() {
		// Initialize with shuffled jokes and show first one immediately
		shuffleJokes()
		showRandomJoke()
		// Restore job folder if previously saved
		restoreJobFolderBookmark()
		// Load recent files list
		loadRecentFiles()
	}
	
	private func shuffleJokes() {
		shuffledJokes = jokes.shuffled()
		jokeIndex = 0
	}
	
	func nextJoke() {
		guard !shuffledJokes.isEmpty else { return }
		
		// If we've gone through all jokes, reshuffle
		if jokeIndex >= shuffledJokes.count {
			shuffleJokes()
		}
		
		currentJoke = shuffledJokes[jokeIndex]
		jokeIndex += 1
	}
	
	private func showRandomJoke() {
		guard !shuffledJokes.isEmpty else { return }
		currentJoke = shuffledJokes[0]
		jokeIndex = 1
	}
	
	func selectCSVFile(_ url: URL) {
		Logger.log("🎯 AppState.selectCSVFile called with: \(url.lastPathComponent)")
		Logger.log("🎯 Available CSV files: \(availableCSVFiles.map { $0.lastPathComponent })")
		guard availableCSVFiles.contains(url) else { 
			Logger.warn("❌ Selected CSV not in available files!")
			return 
		}
		Logger.log("🎯 Setting detectedCSVFile from \(detectedCSVFile?.lastPathComponent ?? "nil") to \(url.lastPathComponent)")
		if Thread.isMainThread {
			detectedCSVFile = url
		} else {
			DispatchQueue.main.async { self.detectedCSVFile = url }
		}
		// Track recents
		addRecentFile(url)
	}
	
	func refreshCSVFiles() {
		scanForValidCSV()
	}
	
	func addSharedGroup(_ groupName: String) {
		let trimmedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedName.isEmpty, !sharedGroups.contains(trimmedName), trimmedName != "No Group" else { return }
		let apply = {
			self.sharedGroups.append(trimmedName)
			self.sharedGroups.sort()
		}
		if Thread.isMainThread { apply() } else { DispatchQueue.main.async { apply() } }
	}

	// MARK: - Job Folder Bookmark Helpers
	private func saveJobFolderBookmark(_ url: URL) {
		if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
			UserDefaults.standard.set(data, forKey: jobFolderBookmarkKey)
		}
	}

	private func restoreJobFolderBookmark() {
		guard let data = UserDefaults.standard.data(forKey: jobFolderBookmarkKey) else { return }
		var isStale = false
		if let restored = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale) {
			let didStartAccessing = restored.startAccessingSecurityScopedResource()
			jobFolderURL = restored
			isJobFolderSelected = true
			// Load job-specific configuration and then scan for files
			loadJobConfig()
			scanForValidCSV()
			if !didStartAccessing {
				Logger.warn("Warning: Could not access restored job folder security scoped resource")
			}
		}
	}
	
	func syncGroupsFromCSV(_ csvGroups: [String]) {
		for group in csvGroups {
			addSharedGroup(group)
		}
	}
	
	func syncGroupsFromManual(_ manualTeams: [String]) {
		for team in manualTeams {
			addSharedGroup(team)
		}
	}
	
	func replaceSharedGroups(_ newGroups: [String]) {
		let filtered = newGroups.filter { !$0.isEmpty && $0 != "No Group" }.sorted()
		if Thread.isMainThread {
			sharedGroups = filtered
		} else {
			DispatchQueue.main.async { self.sharedGroups = filtered }
		}
	}
	
	func checkPhotographerSetup() {
		// In single photographer mode, auto-set a default ID and skip setup
		if collaborationMode == .solo {
			if photographerID.isEmpty || photographerID == "SingleUser" {
				photographerID = "Single Photographer"
			}
			// Skip setup dialog for single mode
			showingPhotographerSetup = false
			return
		}

		// For team mode, show setup unless user has chosen to skip
		if !skipPhotographerSetup {
			showingPhotographerSetup = true
		}
	}
	
	// MARK: - Smart Detection
	func detectPhotographerMode() -> (shouldUseTeamMode: Bool, detectedPhotographers: [String], confidence: Float) {
		guard let jobFolder = jobFolderURL else {
			return (false, [], 0.0)
		}
		
		do {
			let contents = try FileManager.default.contentsOfDirectory(at: jobFolder, includingPropertiesForKeys: nil)
			let csvFiles = contents.filter { $0.pathExtension.lowercased() == "csv" && !isSystemGeneratedCSV($0) }
			
			var detectedPhotographers: Set<String> = []
			var originalCount = 0
			var photographerCopyCount = 0
			
			for csvFile in csvFiles {
				if isValidCSVFile(csvFile) {
					if isAnyPhotographerCSV(csvFile) {
						// Extract photographer ID from filename
						let fileName = csvFile.deletingPathExtension().lastPathComponent
						if let lastUnderscore = fileName.lastIndex(of: "_") {
							let photographerID = String(fileName[fileName.index(after: lastUnderscore)...])
							detectedPhotographers.insert(photographerID)
							photographerCopyCount += 1
						}
					} else {
						originalCount += 1
					}
				}
			}
			
			let totalPhotographers = detectedPhotographers.count
			let shouldUseTeamMode = totalPhotographers >= 2
			
			// Calculate confidence based on evidence
			var confidence: Float = 0.0
			if totalPhotographers >= 2 {
				confidence = min(1.0, Float(totalPhotographers) / 3.0) // High confidence with 3+ photographers
			} else if totalPhotographers == 1 && photographerCopyCount > 0 {
				confidence = 0.6 // Medium confidence - someone is using team mode
			} else if originalCount > 0 && photographerCopyCount == 0 {
				confidence = 0.8 // High confidence for solo mode
			}
			
			Logger.log("🤖 Smart Detection Results:")
			Logger.log("   Detected photographers: \(Array(detectedPhotographers))")
			Logger.log("   Should use team mode: \(shouldUseTeamMode)")
			Logger.log("   Confidence: \(confidence)")
			
			return (shouldUseTeamMode, Array(detectedPhotographers), confidence)
			
		} catch {
			Logger.error("❌ Smart detection failed: \(error)")
			return (false, [], 0.0)
		}
	}
	
	func setPhotographerID(_ id: String) {
		// Allow comma/newline separated input; first token is the working ID, rest are stored as team
		let parsed = parseTeamIDs(id)
		if let first = parsed.first {
			photographerID = first
			let rest = Array(parsed.dropFirst())
			if !rest.isEmpty {
				let existing = parseTeamIDs(teamPhotographerIDsStorage)
				storeTeamIDs(existing + rest)
			}
		} else {
			photographerID = id.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		showingPhotographerSetup = false
		
		Logger.log("Photographer ID set to: \(photographerID)")
		if !teamPhotographerIDsStorage.isEmpty { Logger.log("Team IDs stored: \(teamPhotographerIDsStorage)") }
		
		// Persist photographer ID to per-job config
		var cfg = jobConfig ?? JobConfig(collaborationMode: collaborationMode, myPhotographerID: photographerID, teamPhotographers: parseTeamIDs(teamPhotographerIDsStorage))
		cfg.myPhotographerID = photographerID
		jobConfig = cfg
		_ = try? saveJobConfig()
		
		// Rescan to find existing photographer copies (but don't force creation)
		DispatchQueue.main.async {
			self.scanForValidCSV()
		}
	}
	
	func skipPhotographerSetupPermanently() {
		skipPhotographerSetup = true
		photographerID = "SingleUser" // Default ID for single-user mode
		showingPhotographerSetup = false
	}
	
	func resetPhotographerSetup() {
		skipPhotographerSetup = false
		photographerID = ""
		showingPhotographerSetup = true
	}
	
	// MARK: - Photographer CSV Copy Management

	// System-generated CSVs created by auto-merge should be hidden from picker/logic
	private func isSystemGeneratedCSVName(_ fileName: String) -> Bool {
		return fileName.hasPrefix("backup_") || fileName.hasPrefix("merged_") || fileName.hasPrefix("conflicts_")
	}

	private func isSystemGeneratedCSV(_ url: URL) -> Bool {
		return isSystemGeneratedCSVName(url.lastPathComponent)
	}
	
	func getPhotographerCSVPath(for originalCSV: URL, photographerID: String) -> URL {
		let directory = originalCSV.deletingLastPathComponent()
		let originalName = originalCSV.deletingPathExtension().lastPathComponent
		// Sanitize ID for filenames: keep alphanumerics and _-
		let safeID = photographerID.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
		let photographerFileName = "\(originalName)_\(safeID).csv"
		return directory.appendingPathComponent(photographerFileName)
	}
	
	func createPhotographerCSVCopy(from sourceCSV: URL) -> URL? {
		guard !photographerID.isEmpty && photographerID != "Single Photographer" else {
			Logger.warn("No photographer ID set or in single mode, cannot create copy")
			return nil
		}
		
		// Use the actual source CSV file - don't reconstruct paths
		let originalCSV = sourceCSV  // Use the detected CSV file directly

		// Avoid creating copies from system-generated files (backups, merged, conflicts)
		if isSystemGeneratedCSV(originalCSV) {
			Logger.warn("⚠️ Skipping photographer copy for system-generated CSV: \(originalCSV.lastPathComponent)")
			return nil
		}
		let photographerCSV = getPhotographerCSVPath(for: originalCSV, photographerID: photographerID)
		
		Logger.log("Creating photographer copy:")
		Logger.log("  Source: \(originalCSV.lastPathComponent)")
		Logger.log("  Source Path: \(originalCSV.path)")
		Logger.log("  Target: \(photographerCSV.lastPathComponent)")
		Logger.log("  Target Path: \(photographerCSV.path)")
		Logger.log("  Photographer ID: \(photographerID)")
		
		// If photographer copy already exists, do NOT create again (avoid any writes)
		if FileManager.default.fileExists(atPath: photographerCSV.path) {
			Logger.warn("⚠️ Photographer copy already exists: \(photographerCSV.lastPathComponent). Skipping creation.")
			return photographerCSV
		}
		
		// Check if source CSV exists (it should, since it was detected)
		guard FileManager.default.fileExists(atPath: originalCSV.path) else {
			Logger.error("❌ Source CSV does not exist at: \(originalCSV.path)")
			Logger.warn("   Available files in directory:")
			if let contents = try? FileManager.default.contentsOfDirectory(at: originalCSV.deletingLastPathComponent(), includingPropertiesForKeys: nil) {
				for file in contents.prefix(10) {
					Logger.warn("   - \(file.lastPathComponent)")
				}
			}
			return nil
		}
		
		// Create a copy for this photographer from the source CSV (do not rewrite other copies)
		do {
			try FileManager.default.copyItem(at: originalCSV, to: photographerCSV)
			Logger.log("✅ Successfully created photographer CSV copy: \(photographerCSV.lastPathComponent)")
			
			// Refresh list and select the newly created copy
			DispatchQueue.main.async {
				self.scanForValidCSV()
				self.selectCSVFile(photographerCSV)
			}
			return photographerCSV
		} catch {
			Logger.error("❌ Failed to create photographer CSV copy: \(error)")
			return nil
		}
	}

	/// Create a photographer copy for a specific photographer ID from a specific original CSV
	func createPhotographerCopy(forOriginal originalCSV: URL, photographerID: String) -> URL? {
		let id = photographerID.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !id.isEmpty else { return nil }
		if isSystemGeneratedCSV(originalCSV) { return nil }
		let target = getPhotographerCSVPath(for: originalCSV, photographerID: id)
		// If it already exists, do NOT treat it as created (avoid overwriting later)
		if FileManager.default.fileExists(atPath: target.path) { return nil }
		do {
			try FileManager.default.copyItem(at: originalCSV, to: target)
			Logger.log("✅ Created team photographer copy: \(target.lastPathComponent)")
			return target
		} catch {
			Logger.error("❌ Failed to create team photographer copy for \(id): \(error)")
			return nil
		}
	}

	/// Create photographer CSV copies for multiple photographer IDs from all detected original CSVs
	@discardableResult
	func createPhotographerCSVCopies(for photographerIDs: [String]) -> [URL] {
		var ids = Array(Set(photographerIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
		// Ensure the local photographer's copy is included when distributing (but not for single mode)
		if !photographerID.isEmpty && !skipPhotographerSetup && photographerID != "SingleUser" && photographerID != "Single Photographer" {
			if !ids.contains(photographerID) { ids.append(photographerID) }
		}
		guard !ids.isEmpty else { return [] }
		let originals = getOriginalCSVs()
		var created: [URL] = []
		var createdPerOriginal: [URL: [URL]] = [:]
		for original in originals {
			Logger.log("👥 Creating copies for original: \(original.lastPathComponent) IDs: \(ids)")
			for id in ids {
				if let url = createPhotographerCopy(forOriginal: original, photographerID: id) {
					created.append(url)
					createdPerOriginal[original, default: []].append(url)
				}
			}
		}

		// Initialize placeholders only for newly created copies per original (never rewrite existing copies)
		for (original, copies) in createdPerOriginal {
			guard !copies.isEmpty else { continue }
			let trueOriginal = findTrueOriginalWithPlaceholders(for: original)
			Logger.log("🔁 Initializing placeholders for new copies of \(trueOriginal.lastPathComponent): \(copies.map { $0.lastPathComponent })")
			distributePlaceholders(from: trueOriginal, to: copies)
		}
		// Refresh CSV listing to include new copies and keep current selection if possible
		DispatchQueue.main.async {
			self.scanForValidCSV()
		}
		return created
	}

	// MARK: - Placeholder Distribution
	private func findTrueOriginalWithPlaceholders(for detectedOriginal: URL) -> URL {
		// If the detected original has "_csv" in the name, try to find the version without it
		let fileName = detectedOriginal.deletingPathExtension().lastPathComponent
		if fileName.hasSuffix("_csv") {
			let nameWithoutCSV = String(fileName.dropLast(4)) // Remove "_csv"
			let directory = detectedOriginal.deletingLastPathComponent()
			let trueOriginal = directory.appendingPathComponent("\(nameWithoutCSV).csv")
			
			// Check if the true original exists and has placeholders
			if FileManager.default.fileExists(atPath: trueOriginal.path) {
				Logger.log("🔍 Using true original for placeholders: \(trueOriginal.lastPathComponent) instead of \(detectedOriginal.lastPathComponent)")
				return trueOriginal
			}
		}
		
		// Fallback to the detected original
		return detectedOriginal
	}
	
	private func distributePlaceholders(from originalCSV: URL, to createdCopies: [URL]) {
		Logger.log("🔄 Starting placeholder distribution")
		Logger.log("   Reading from: \(originalCSV.lastPathComponent)")
		
		// Union of provided copies (fresh) and any discovered copies on disk
		let discovered = getPhotographerCopiesForOriginal(originalCSV)
		let unionSet = Set(createdCopies) .union(discovered)
		let copies = Array(unionSet)
		if createdCopies.isEmpty {
			Logger.log("   Using scanned photographer copies: \(copies.map { $0.lastPathComponent })")
		} else {
			Logger.log("   Using provided photographer copies: \(createdCopies.map { $0.lastPathComponent })")
			if !discovered.isEmpty { Logger.log("   Also discovered copies: \(discovered.map { $0.lastPathComponent })") }
		}
		guard !copies.isEmpty else { 
			Logger.error("❌ No photographer copies found for distribution")
			return 
		}
		do {
			let content = try String(contentsOf: originalCSV, encoding: .utf8)
			let rawLines = content.components(separatedBy: .newlines)
			guard let headerLine = rawLines.first, !headerLine.isEmpty else { return }
			let delimiter = headerLine.contains(",") ? "," : ";"
			let headers = headerLine.components(separatedBy: delimiter).map {
				$0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
			}
			// Find name indices with common header variants
			func idx(_ candidates: [String]) -> Int? {
				for c in candidates {
					if let i = headers.firstIndex(where: { $0.caseInsensitiveCompare(c) == .orderedSame }) { return i }
				}
				return nil
			}
			let firstNameIdx = idx(["Student firstname", "First Name", "Firstname"]) ?? 1
			let lastNameIdx = idx(["Student lastname", "Last Name", "Lastname"]) ?? 2
			let dataLines = rawLines.dropFirst().filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
			var nonPlaceholders: [String] = []
			var placeholders: [String] = []
			
			func splitRespectingQuotes(_ line: String, by delim: String) -> [String] {
				var result: [String] = []
				var current = ""
				var inQuotes = false
				for ch in line {
					if ch == "\"" {
						inQuotes.toggle()
						current.append(ch)
					} else if String(ch) == delim && !inQuotes {
						result.append(current)
						current = ""
					} else {
						current.append(ch)
					}
				}
				result.append(current)
				return result
			}
			for line in dataLines {
				let fields = splitRespectingQuotes(line, by: delimiter)
				if fields.count > max(firstNameIdx, lastNameIdx) {
					let fn = fields[firstNameIdx].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
					let ln = fields[lastNameIdx].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
					Logger.log("🔍 Checking row: fn='\(fn)' ln='\(ln)'")
					if fn == "Add" && ln.hasPrefix("Subject") {
						Logger.log("✅ Found placeholder: \(fn) \(ln)")
						placeholders.append(line)
					} else {
						nonPlaceholders.append(line)
					}
				} else {
					nonPlaceholders.append(line)
				}
			}
			
			Logger.log("📊 Found \(placeholders.count) placeholder rows and \(nonPlaceholders.count) non-placeholder rows")
			Logger.log("📊 Distributing across \(copies.count) photographer copies")
			
			// Sort placeholders by Subject number for organized distribution
			let sortedPlaceholders = placeholders.sorted { placeholder1, placeholder2 in
				let fields1 = splitRespectingQuotes(placeholder1, by: delimiter)
				let fields2 = splitRespectingQuotes(placeholder2, by: delimiter)
				
				if fields1.count > lastNameIdx && fields2.count > lastNameIdx {
					let lastName1 = fields1[lastNameIdx].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
					let lastName2 = fields2[lastNameIdx].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
					
					// Extract trailing numbers from Subject names
					let extractNumber = { (lastName: String) -> Int in
						let digitsReversed = lastName.reversed().prefix { $0.isNumber }
						let digits = String(digitsReversed.reversed())
						return Int(digits) ?? Int.max
					}
					
					let num1 = extractNumber(lastName1)
					let num2 = extractNumber(lastName2)
					return num1 < num2
				}
				return placeholder1 < placeholder2
			}
			
			// Distribute placeholders in consecutive blocks instead of round-robin
			var buckets: [[String]] = Array(repeating: [], count: copies.count)
			let placeholdersPerCopy = sortedPlaceholders.count / copies.count
			let remainderPlaceholders = sortedPlaceholders.count % copies.count
			
			var currentIndex = 0
			for bucketIndex in 0..<copies.count {
				// Calculate how many placeholders this bucket should get
				let baseCount = placeholdersPerCopy
				let extraCount = bucketIndex < remainderPlaceholders ? 1 : 0
				let totalForThisBucket = baseCount + extraCount
				
				// Assign consecutive placeholders to this bucket
				for _ in 0..<totalForThisBucket {
					if currentIndex < sortedPlaceholders.count {
						buckets[bucketIndex].append(sortedPlaceholders[currentIndex])
						
						// Extract Subject number for logging
						let fields = splitRespectingQuotes(sortedPlaceholders[currentIndex], by: delimiter)
						if fields.count > lastNameIdx {
							let lastName = fields[lastNameIdx].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
							Logger.log("📦 \(lastName) assigned to photographer \(bucketIndex + 1)")
						}
						
						currentIndex += 1
					}
				}
			}
			
			// Log distribution summary
			Logger.log("📋 Distribution Summary:")
			for (bucketIndex, bucket) in buckets.enumerated() {
				if !bucket.isEmpty {
					var subjectNumbers: [Int] = []
					for placeholder in bucket {
						let fields = splitRespectingQuotes(placeholder, by: delimiter)
						if fields.count > lastNameIdx {
							let lastName = fields[lastNameIdx].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
							let digitsReversed = lastName.reversed().prefix { $0.isNumber }
							let digits = String(digitsReversed.reversed())
							if let number = Int(digits) {
								subjectNumbers.append(number)
							}
						}
					}
					subjectNumbers.sort()
					if !subjectNumbers.isEmpty {
						let range = subjectNumbers.count > 1 ? "\(subjectNumbers.first!)-\(subjectNumbers.last!)" : "\(subjectNumbers.first!)"
						Logger.log("   Photographer \(bucketIndex + 1): Subject\(range) (\(bucket.count) placeholders)")
					}
				}
			}
			
			// Write each copy
			for (idx, copyURL) in copies.enumerated() {
			Logger.log("✏️ Writing to \(copyURL.lastPathComponent):")
			Logger.log("   - \(nonPlaceholders.count) non-placeholder rows")
			Logger.log("   - \(buckets[idx].count) placeholder rows")
				
				var outLines: [String] = [headerLine]
				outLines.append(contentsOf: nonPlaceholders)
				outLines.append(contentsOf: buckets[idx])
				let out = outLines.joined(separator: "\n") + "\n"
			try out.write(to: copyURL, atomically: true, encoding: .utf8)
			Logger.log("📤 Successfully wrote \(outLines.count) total lines to \(copyURL.lastPathComponent)")
			}
		} catch {
			Logger.error("❌ Failed distributing placeholders: \(error)")
		}
	}

	// MARK: - Team IDs Helpers
	func parseTeamIDs(_ raw: String) -> [String] {
		let separators = CharacterSet(charactersIn: ",\n")
		return raw.components(separatedBy: separators).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
	}

	func storeTeamIDs(_ ids: [String]) {
		let unique = Array(Set(ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
		teamPhotographerIDsStorage = unique.joined(separator: ",")
		// Persist team list to per-job config
		var cfg = jobConfig ?? JobConfig(collaborationMode: collaborationMode, myPhotographerID: photographerID, teamPhotographers: unique)
		cfg.teamPhotographers = unique
		jobConfig = cfg
		_ = try? saveJobConfig()
	}
	
	func getOriginalCSV(from anyCSV: URL) -> URL {
		// If this is already an original CSV (doesn't contain photographer ID), return it
		let fileName = anyCSV.deletingPathExtension().lastPathComponent
		
		// Check if this looks like a photographer copy (contains _PhotographerID pattern)
		// Exclude common suffixes like "_csv" by requiring the photographer ID to not be "csv"
		let photographerPattern = "_([A-Za-z0-9]+)$"
		if let regex = try? NSRegularExpression(pattern: photographerPattern),
		   let match = regex.firstMatch(in: fileName, range: NSRange(fileName.startIndex..., in: fileName)) {
			
			// Extract the potential photographer ID
			let fullMatchRange = Range(match.range, in: fileName)!
			let photographerIDRange = Range(match.range(at: 1), in: fileName)!
			let photographerID = String(fileName[photographerIDRange])
			
			// Don't treat "_csv" as a photographer ID
			if photographerID.lowercased() != "csv" {
				// This is a photographer copy, reconstruct the original name
				let reconstructedOriginalName = String(fileName[..<fullMatchRange.lowerBound])
				let directory = anyCSV.deletingLastPathComponent()
				let reconstructedOriginal = directory.appendingPathComponent("\(reconstructedOriginalName).csv")
				
				// Check if the reconstructed original exists
				if FileManager.default.fileExists(atPath: reconstructedOriginal.path) {
					return reconstructedOriginal
				}
				
				// If reconstructed original doesn't exist, try removing "_csv" suffix if present
				if reconstructedOriginalName.hasSuffix("_csv") {
					let nameWithoutCSV = String(reconstructedOriginalName.dropLast(4)) // Remove "_csv"
					let alternativeOriginal = directory.appendingPathComponent("\(nameWithoutCSV).csv")
					if FileManager.default.fileExists(atPath: alternativeOriginal.path) {
						Logger.log("🔍 Found alternative original: \(alternativeOriginal.lastPathComponent) instead of \(reconstructedOriginal.lastPathComponent)")
						return alternativeOriginal
					}
				}
				
				// Fallback to reconstructed name even if it doesn't exist
				return reconstructedOriginal
			}
		}
		
		// This is already the original CSV
		return anyCSV
	}
	
	func findExistingPhotographerCopy(for originalCSV: URL) -> URL? {
		let expectedCopyPath = getPhotographerCSVPath(for: originalCSV, photographerID: photographerID)
		if FileManager.default.fileExists(atPath: expectedCopyPath.path) {
			Logger.log("Found existing photographer copy: \(expectedCopyPath.lastPathComponent)")
			return expectedCopyPath
		}
		return nil
	}
	
	
	func isPhotographerCSV(_ url: URL) -> Bool {
		let fileName = url.deletingPathExtension().lastPathComponent
		return fileName.contains("_\(photographerID)")
	}
	
	func isAnyPhotographerCSV(_ url: URL) -> Bool {
		let fileName = url.deletingPathExtension().lastPathComponent

		// Look for pattern: basename_photographerID
		// The photographerID should be a name/ID, not a file extension like "xls" or "csv"
		guard let lastUnderscore = fileName.lastIndex(of: "_") else { return false }

		let prefix = String(fileName[..<lastUnderscore])
		let suffix = String(fileName[fileName.index(after: lastUnderscore)...])

		// Must have both prefix and suffix
		if prefix.isEmpty || suffix.isEmpty { return false }

		// Suffix cannot be "csv" (that's the extension)
		if suffix.lowercased() == "csv" { return false }

		// Skip common file type indicators that shouldn't be treated as photographer IDs
		let fileTypeIndicators = ["xls", "xlsx", "pdf", "doc", "docx", "txt", "json", "xml", "html"]
		if fileTypeIndicators.contains(suffix.lowercased()) { return false }

		// Suffix should look like a name/ID (alphabetic start, reasonable length)
		if suffix.count < 2 || suffix.count > 50 { return false }
		if !suffix.first!.isLetter { return false }

		// Allow alphanumerics, underscores, hyphens
		let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
		return suffix.unicodeScalars.allSatisfy { allowed.contains($0) }
	}
	
	func getOriginalCSVFromPhotographerCopy(_ photographerCSV: URL) -> URL? {
		let fileName = photographerCSV.deletingPathExtension().lastPathComponent
		guard let range = fileName.range(of: "_\(photographerID)") else { return nil }
		
		let originalName = String(fileName[..<range.lowerBound])
		let directory = photographerCSV.deletingLastPathComponent()
		return directory.appendingPathComponent("\(originalName).csv")
	}
	
	// MARK: - Auto Merge Support
	
	func getAllPhotographerCopies() -> [URL] {
		return availableCSVFiles.filter { isAnyPhotographerCSV($0) }
	}

	// MARK: - Collaboration Mode Helpers
	func setCollaborationMode(_ mode: CollaborationMode) {
		collaborationMode = mode
		var cfg = jobConfig ?? JobConfig(collaborationMode: mode, myPhotographerID: photographerID, teamPhotographers: parseTeamIDs(teamPhotographerIDsStorage))
		cfg.collaborationMode = mode
		jobConfig = cfg
		_ = try? saveJobConfig()
	}
	
	func getOriginalCSVs() -> [URL] {
		// Originals are CSVs that do NOT end with _<ID>.csv, but may have internal underscores like _xls
		return availableCSVFiles.filter { url in
			!isAnyPhotographerCSV(url)
		}
	}
	
	func getPhotographerCopiesForOriginal(_ originalCSV: URL) -> [URL] {
		let originalName = originalCSV.deletingPathExtension().lastPathComponent
		// First, use the in-memory list
		var matches = availableCSVFiles.filter { csvFile in
			let fileName = csvFile.deletingPathExtension().lastPathComponent
			// Must match originalName followed by underscore and a valid photographer suffix
			if !fileName.hasPrefix(originalName + "_") { return false }
			return isAnyPhotographerCSV(csvFile)
		}
		if !matches.isEmpty { return matches }
		
		// Fallback: scan the job folder directly (in case the list hasn't refreshed yet)
		if let jobFolder = jobFolderURL {
			do {
				let contents = try FileManager.default.contentsOfDirectory(at: jobFolder, includingPropertiesForKeys: nil)
				let csvs = contents.filter { $0.pathExtension.lowercased() == "csv" && !isSystemGeneratedCSV($0) }
				matches = csvs.filter { csvFile in
					let fileName = csvFile.deletingPathExtension().lastPathComponent
					return fileName.hasPrefix(originalName + "_") && isAnyPhotographerCSV(csvFile)
				}
				if !matches.isEmpty {
				Logger.log("🔎 Fallback scan found photographer copies: \(matches.map { $0.lastPathComponent })")
				}
				return matches
			} catch {
				Logger.warn("⚠️ Failed to scan job folder for photographer copies: \(error)")
			}
		}
		return matches
	}

	private func scanForValidCSV() {
		guard let jobFolder = jobFolderURL else { return }

		do {
			let fileManager = FileManager.default
			let contents = try fileManager.contentsOfDirectory(at: jobFolder,
															includingPropertiesForKeys: nil)

			var validDataFiles: [URL] = [] // CSV and Excel
			var originalCSVFiles: [URL] = []
			
			for fileURL in contents {
				let ext = fileURL.pathExtension.lowercased()
				if ext == "csv" || ext == "xlsx" || ext == "xls" {
					// Exclude system-generated files from consideration
					if isSystemGeneratedCSV(fileURL) { continue }
					// For CSV, ensure structure looks valid; for Excel, accept for now
					if ext == "csv" {
						if isValidCSVFile(fileURL) {
							validDataFiles.append(fileURL)
							if !isPhotographerCSV(fileURL) && !isAnyPhotographerCSV(fileURL) {
								originalCSVFiles.append(fileURL)
							}
						}
					} else {
						// XLSX/XLS accepted; original determination based on name (no _ID suffix)
						validDataFiles.append(fileURL)
						let fileName = fileURL.deletingPathExtension().lastPathComponent
						if !fileName.contains("_") || !isAnyPhotographerCSV(fileURL) {
							originalCSVFiles.append(fileURL)
						}
					}
				}
			}

			// Sort CSV files by name for consistent ordering
			validDataFiles.sort { $0.lastPathComponent < $1.lastPathComponent }
			originalCSVFiles.sort { $0.lastPathComponent < $1.lastPathComponent }
			
			let nextFiles = validDataFiles
			
			let nextDetected: URL?
			let nextHasValid: Bool
			let nextMode: AppMode
			if !validDataFiles.isEmpty {
				// Strategy: prefer existing photographer copy, then original CSVs
				let myPhotographerCSVs = validDataFiles.filter { isPhotographerCSV($0) }
				
				if !photographerID.isEmpty && !myPhotographerCSVs.isEmpty {
					// Use existing photographer copy
					Logger.log("📸 Found existing photographer copy: \(myPhotographerCSVs.first!.lastPathComponent)")
					nextDetected = myPhotographerCSVs.first
				} else if !originalCSVFiles.isEmpty {
					// Use first original CSV (not a photographer copy)
					Logger.log("📄 Using original CSV: \(originalCSVFiles.first?.lastPathComponent ?? "unknown")")
					nextDetected = originalCSVFiles.first
				} else {
					// Fallback to any valid CSV
					Logger.warn("⚠️ Fallback to any data file: \(validDataFiles.first?.lastPathComponent ?? "unknown")")
					nextDetected = validDataFiles.first
				}
				nextHasValid = true
				nextMode = .csv
			} else {
				// No valid CSV found, default to manual mode
				nextDetected = nil
				nextHasValid = false
				nextMode = .manual
			}
			DispatchQueue.main.async {
				self.availableCSVFiles = nextFiles
				self.detectedCSVFile = nextDetected
				self.hasValidCSV = nextHasValid
				self.currentMode = nextMode
			}

		} catch {
			Logger.error("Error scanning for CSV files: \(error)")
			DispatchQueue.main.async {
				self.availableCSVFiles = []
				self.detectedCSVFile = nil
				self.hasValidCSV = false
				self.currentMode = .manual
			}
		}
	}

	private func isValidCSVFile(_ url: URL) -> Bool {
		do {
			var content = try String(contentsOf: url, encoding: .utf8)
			// Handle potential UTF-8 BOM
			if content.hasPrefix("\u{FEFF}") {
				content = String(content.dropFirst())
			}
			let lines = content.components(separatedBy: .newlines)
			guard !lines.isEmpty else { return false }

			let headerLine = lines[0]
			let delimiter = headerLine.contains(",") ? "," : ";"
			let headers = headerLine.components(separatedBy: delimiter)
			guard !headers.isEmpty else { return false }

			// More flexible validation - check for common CSV patterns
			let firstHeader = headers[0].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "").lowercased()
			
			// Accept traditional barcode CSVs
			if firstHeader == "child id" || firstHeader == "barcode" || firstHeader == "id" {
				return true
			}
			
			// Accept roster-style CSVs (name-based)
			let nameHeaders = ["first name", "firstname", "first", "name", "player", "student"]
			if nameHeaders.contains(firstHeader) {
				Logger.log("📋 Detected roster-style CSV: \(url.lastPathComponent) (first header: \(firstHeader))")
				return true
			}
			
			// If we have at least 2 columns that look like data, accept it
			let nonEmptyHeaders = headers.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
			if nonEmptyHeaders.count >= 2 {
				Logger.log("📋 Accepting CSV with \(nonEmptyHeaders.count) non-empty headers: \(url.lastPathComponent)")
				return true
			}
			
			Logger.log("❌ Rejecting CSV - no recognizable pattern: \(url.lastPathComponent) (first header: \(firstHeader))")
			return false

		} catch {
			Logger.log("❌ Error reading CSV file \(url.lastPathComponent): \(error)")
			return false
		}
	}

	// MARK: - Recent Files (security-scoped bookmarks)
	@Published var recentFiles: [URL] = []
	private let recentBookmarksKey = "recentFileBookmarks.v1"
	private let recentLimit = 10

	func loadRecentFiles() {
		guard let stored = UserDefaults.standard.array(forKey: recentBookmarksKey) as? [Data] else { return }
		var resolved: [URL] = []
		for data in stored {
			var isStale = false
			if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale) {
				resolved.append(url)
			}
		}
		recentFiles = resolved
	}

	func saveRecentFiles() {
		let bookmarks: [Data] = recentFiles.compactMap { url in
			try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
		}
		UserDefaults.standard.set(bookmarks, forKey: recentBookmarksKey)
	}

	func addRecentFile(_ url: URL) {
		var list = recentFiles.filter { $0 != url }
		list.insert(url, at: 0)
		if list.count > recentLimit { list = Array(list.prefix(recentLimit)) }
		recentFiles = list
		saveRecentFiles()
	}

	// Allow UI to inject user-chosen files into available list
	func addAvailableFile(_ url: URL) {
		if !availableCSVFiles.contains(url) {
			availableCSVFiles.append(url)
			availableCSVFiles.sort { $0.lastPathComponent < $1.lastPathComponent }
		}
	}

	// MARK: - Working file resolution (no auto-creation)
	func getWorkingCSVFile(for detectedCSV: URL) -> URL {
		// In team mode, prefer an existing photographer copy, but never auto-create
		if collaborationMode == .team && !photographerID.isEmpty && photographerID != "SingleUser" && photographerID != "Single Photographer" {
			if isPhotographerCSV(detectedCSV) { return detectedCSV }
			if isAnyPhotographerCSV(detectedCSV) { return detectedCSV }
			if let existingCopy = findExistingPhotographerCopy(for: detectedCSV) { return existingCopy }
		}
		// Solo/default: use detected file directly
		return detectedCSV
	}
}


