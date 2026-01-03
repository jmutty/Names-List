import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Player Model for CSV
struct Player: Identifiable, Codable, Hashable {
	let id: UUID
	var firstName: String
	var lastName: String
	var group: String
	var barcode: String
	var isPhotographed: Bool
	var hasPhoto: Bool
	var allColumns: [String: String]
	var originalData: [String: String] = [:] // Store original values when edited
	var fullName: String { "\(firstName) \(lastName)" }
	
	// Helper to check if a field has been changed from original
	func hasOriginalValue(for field: String) -> Bool {
		return !(originalData[field]?.isEmpty ?? true)
	}
	
	// Helper to get original value for a field
	func getOriginalValue(for field: String) -> String? {
		return originalData[field]
	}

	// Helper to determine the barcode column name using the same logic as CSV parsing
	func barcodeColumnName() -> String {
		// Use the same priority as HeaderAliases.barcodeExact
		let barcodeCandidates = ["Barcode", "Barcode (1)", "Child ID", "Student ID", "ID"]
		for candidate in barcodeCandidates {
			if allColumns.keys.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
				return allColumns.keys.first { $0.caseInsensitiveCompare(candidate) == .orderedSame } ?? candidate
			}
		}
		// Fallback to any column containing "barcode" or "id"
		for key in allColumns.keys {
			let lower = key.lowercased()
			if lower.contains("barcode") || lower == "id" {
				return key
			}
		}
		return "Barcode" // Default fallback
	}
}

// MARK: - Column Mappings for Roster Mode
struct ColumnMappings: Codable, Equatable {
	var firstName: String?
	var lastName: String?
	var fullName: String?  // For combined name columns
	var team: String?
	
	static let `default` = ColumnMappings()
	
	// Check if we have enough mapping to work with
	var isValid: Bool {
		let hasName = (firstName != nil && lastName != nil) || fullName != nil
		return hasName && team != nil
	}
	
	// Get the display name for roster mode
	func getDisplayName(from player: Player) -> String {
		// Prefer separate first/last when both are mapped and present
		if let firstName = firstName, let lastName = lastName,
		   let first = player.allColumns[firstName], !first.isEmpty,
		   let last = player.allColumns[lastName], !last.isEmpty {
			let firstTrimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
			let lastTrimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
			return "\(firstTrimmed) \(lastTrimmed)".trimmingCharacters(in: .whitespacesAndNewlines)
		}
		
		// Otherwise, use the combined full name mapping if provided
		if let fullName = fullName, let value = player.allColumns[fullName], !value.isEmpty {
			return value.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		
		// Fallbacks if only one of the name parts is available
		if let firstName = firstName, let first = player.allColumns[firstName], !first.isEmpty {
			return first.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		if let lastName = lastName, let last = player.allColumns[lastName], !last.isEmpty {
			return last.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		
		// Final fallback to the parsed CSV fields
		return player.fullName
	}
	
	// Get the team name for roster mode
	func getTeamName(from player: Player) -> String {
		if let team = team, let value = player.allColumns[team], !value.isEmpty {
			return value.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		return player.group
	}
}

// MARK: - CSV Manager
class CSVManager: ObservableObject {
	@Published var currentFileName: String = "Names List"
	@Published var players: [Player] = []
	@Published var uniqueGroups: [String] = []
	@Published var isLoading = false
	@Published var errorMessage: String?
	@Published var csvHeaders: [String] = []
	@Published var saveStatus: String = "All changes saved"
	
	// Roster mode properties
	@Published var isRosterMode = false
	@Published var columnMappings: ColumnMappings = .default
	@Published var showingColumnMapping = false

	weak var appState: AppStateManager?
	var photographerID: String { appState?.photographerID ?? "Unknown" }

	private var currentFileURL: URL?
	private var isAccessingSecurityScopedResource = false

	var publicCurrentFileURL: URL? { currentFileURL }
	private var playerIDMap: [String: UUID] = [:]
	private var barcodeColumnIndex: Int?
	private var pendingSaveWorkItem: DispatchWorkItem?
	private var header: [String] = []
	private var delimiter: String = ","
	private let saveQueue = DispatchQueue(label: "csv.save.queue", qos: .userInitiated)
	// Create a new placeholder player with a specific barcode and insert it at the top
	@discardableResult
	func createManualPlaceholder(barcode: String) -> Player {
		let headers = csvHeaders
		
		// Use the same priority-based barcode detection as CSV parsing
		let barcodeHeader: String
		if let index = CSVService.findHeaderIndexWithPriority(in: headers, prioritizedCandidates: HeaderAliases.barcodeExact) {
			barcodeHeader = headers[index]
		} else if let index = CSVService.findHeaderIndex(in: headers, containsAny: HeaderAliases.barcodeContains) {
			barcodeHeader = headers[index]
		} else {
			barcodeHeader = "Barcode"
		}
		let groupHeader: String = {
			if let idx = CSVService.findHeaderIndex(in: headers, equalsAny: HeaderAliases.group) { return headers[idx] }
			return "Group"
		}()
		let firstHeader: String = {
			if let idx = CSVService.findHeaderIndex(in: headers, equalsAny: HeaderAliases.firstName) { return headers[idx] }
			return "First Name"
		}()
		let lastHeader: String = {
			if let idx = CSVService.findHeaderIndex(in: headers, equalsAny: HeaderAliases.lastName) { return headers[idx] }
			return "Last Name"
		}()

		var columns: [String:String] = [:]
		for h in headers { columns[h] = columns[h] ?? "" }
		columns[barcodeHeader] = barcode
		columns[firstHeader] = "Add"
		columns[lastHeader] = "Subject"
		columns[groupHeader] = columns[groupHeader] ?? "No Group"

		let newPlayer = Player(
			id: UUID(),
			firstName: "Add",
			lastName: "Subject",
			group: columns[groupHeader] ?? "No Group",
			barcode: barcode,
			isPhotographed: false,
			hasPhoto: false,
			allColumns: columns,
			originalData: [:]
		)

		// Insert at the beginning so it appears early
		players.insert(newPlayer, at: 0)
		// Persist immediately
		saveCSV()
		// Refresh groups
		refreshGroupsFromPlayers()
		return newPlayer
	}

	deinit { stopAccessingFile() }

	private func stopAccessingFile() {
		if isAccessingSecurityScopedResource, let url = currentFileURL {
			url.stopAccessingSecurityScopedResource()
			isAccessingSecurityScopedResource = false
		}
	}

	func loadCSV(from url: URL) {
		Logger.log("🔄 CSVManager.loadCSV called with: \(url.lastPathComponent)")
		
		// Prevent concurrent loads
		if isLoading {
			Logger.log("🔄 CSV load already in progress, skipping")
			return
		}
		
		// Clear shared groups before loading new CSV to prevent persistence from previous files
		appState?.replaceSharedGroups([])
		
		stopAccessingFile()
		if Thread.isMainThread {
			isLoading = true
			errorMessage = nil
		} else {
			DispatchQueue.main.async {
				self.isLoading = true
				self.errorMessage = nil
			}
		}

		// Get the working CSV/excel file (photographer-specific copy if available)
		var workingURL = appState?.getWorkingCSVFile(for: url) ?? url
		let ext = workingURL.pathExtension.lowercased()
		if ext == "xls" || ext == "xlsx" {
			// Convert Excel to CSV via Numbers
			let directory = workingURL.deletingLastPathComponent()
			let baseName = workingURL.deletingPathExtension().lastPathComponent
			let converted = directory.appendingPathComponent("\(baseName)_converted.csv")
			Logger.log("🧩 Converting Excel to CSV using Numbers: \(workingURL.lastPathComponent) → \(converted.lastPathComponent)")
			if AppleScriptExecutor.convertXLSToCSVUsingNumbers(xlsURL: workingURL, outputURL: converted) {
				workingURL = converted
				Logger.log("✅ Conversion succeeded: \(converted.lastPathComponent)")
			} else {
				DispatchQueue.main.async {
					self.isLoading = false
					self.errorMessage = "Failed to open Excel file. Please install Apple Numbers or convert the file to CSV manually."
				}
				return
			}
		}
		
		Logger.log("📁 CSVManager will load: \(workingURL.lastPathComponent)")
		Logger.log("📁 Previous file was: \(currentFileName)")
		
		DispatchQueue.main.async {
			self.currentFileURL = workingURL
			self.currentFileName = workingURL.lastPathComponent
			self.isAccessingSecurityScopedResource = workingURL.startAccessingSecurityScopedResource()
			self.playerIDMap = [:]
		}

		DispatchQueue.global(qos: .userInitiated).async {
			do {
				var content = try String(contentsOf: workingURL, encoding: .utf8)
				if content.hasPrefix("\u{FEFF}") {
					content = String(content.dropFirst())
				}
				let parseResult = self.parseCSV(content: content)
				DispatchQueue.main.async {
					self.players = parseResult.players
					self.csvHeaders = parseResult.headers
					
					// Check for roster mode and auto-configure if needed
					Logger.log("📋 CSV Headers: \(parseResult.headers)")
					Logger.log("👥 Sample players: \(parseResult.players.prefix(3).map { "\($0.firstName) \($0.lastName) (\($0.barcode))" })")
					
					if self.detectRosterMode(parseResult.headers, players: parseResult.players) {
						Logger.log("🎯 Roster CSV detected, enabling roster mode")
						self.isRosterMode = true
						self.columnMappings = self.autoDetectRosterColumns(parseResult.headers)
						
						Logger.log("🔗 Column mappings: firstName=\(self.columnMappings.firstName ?? "nil"), lastName=\(self.columnMappings.lastName ?? "nil"), fullName=\(self.columnMappings.fullName ?? "nil"), team=\(self.columnMappings.team ?? "nil")")
						
						// Show mapping UI if detection wasn't perfect
						if !self.columnMappings.isValid {
							Logger.log("⚠️ Column detection incomplete, showing mapping UI")
							self.showingColumnMapping = true
						} else {
							Logger.log("✅ Column mappings are valid, roster mode ready")
						}
					} else {
						Logger.log("📊 Regular CSV detected, using standard mode")
						// Reset roster mode for regular CSVs
						self.isRosterMode = false
						self.columnMappings = .default
					}
					
					// Include all groups, and add "No Group" if there are players without groups
					let allGroups = Set(parseResult.players.map { $0.group }.filter { !$0.isEmpty && $0 != "No Group" })
					var groupsArray = Array(allGroups).sorted()
					
					// Add "No Group" if there are players without groups
					let hasPlayersWithoutGroups = parseResult.players.contains { $0.group.isEmpty || $0.group == "No Group" }
					if hasPlayersWithoutGroups {
						groupsArray.append("No Group")
					}
					
					self.uniqueGroups = groupsArray
					self.ensureMetadataColumns()
					// Avoid re-entrancy during mode switches; defer refresh to the next runloop
					DispatchQueue.main.async {
						self.refreshGroupsFromPlayers() // Ensure all groups are captured
					}
					self.isLoading = false
				}
			} catch {
				DispatchQueue.main.async {
					self.errorMessage = "Failed to load CSV: \(error.localizedDescription)"
					self.isLoading = false
					self.stopAccessingFile()
				}
			}
		}
	}

	func reloadFromCurrentFile() { guard let url = currentFileURL else { return }; loadCSV(from: url) }

	private func parseCSV(content: String) -> (players: [Player], headers: [String]) {
		let lines = content.components(separatedBy: .newlines)
		guard let headerLine = lines.first, !headerLine.isEmpty else { return ([], []) }

		delimiter = headerLine.contains(",") ? "," : ";"
		var players: [Player] = []
		header = headerLine.components(separatedBy: delimiter)
		
		// Track dedup keys → index to merge exact duplicate roster rows (ignoring metadata columns)
		var dedupKeyToIndex: [String: Int] = [:]

		let parsedHeaders = header.map { CSVService.cleanHeader($0) }
		let cleanHeadersForMatching = parsedHeaders

		func indexOfHeader(equalsAny candidates: [String]) -> Int? {
			CSVService.findHeaderIndex(in: cleanHeadersForMatching, equalsAny: candidates)
		}

		func indexOfHeader(containsAny substrings: [String]) -> Int? {
			CSVService.findHeaderIndex(in: cleanHeadersForMatching, containsAny: substrings)
		}

		let firstNameIdx = indexOfHeader(equalsAny: HeaderAliases.firstName) ?? 1
		let lastNameIdx = indexOfHeader(equalsAny: HeaderAliases.lastName) ?? 2
		let groupIdx = indexOfHeader(equalsAny: HeaderAliases.group) ?? 6
		let photoIdx = indexOfHeader(equalsAny: HeaderAliases.photo) ?? indexOfHeader(containsAny: ["has photo"]) ?? 22
		let referenceIdx = indexOfHeader(equalsAny: HeaderAliases.reference) ?? indexOfHeader(containsAny: ["reference", "photograph", "photographed", "taken", "captured", "shot", "complete", "done"]) ?? 10
		let photographedByIdx = indexOfHeader(equalsAny: ["Photographed By"])
		let photographedAtIdx = indexOfHeader(equalsAny: ["Photographed At"])
		barcodeColumnIndex = CSVService.findHeaderIndexWithPriority(in: parsedHeaders, prioritizedCandidates: HeaderAliases.barcodeExact) ?? indexOfHeader(containsAny: HeaderAliases.barcodeContains)

		let dataLines = lines.dropFirst().filter { !$0.trim().isEmpty }

		for line in dataLines {
			let components = CSVService.splitRespectingQuotes(line, by: delimiter)

			let maxRequiredIndex = max(firstNameIdx, lastNameIdx, barcodeColumnIndex ?? 0)
			guard components.count > maxRequiredIndex else { continue }

			func cleanField(_ field: String) -> String {
				field.trim().trimmingCharacters(in: CharacterSet(charactersIn: "\""))
			}

			var allCols: [String: String] = [:]
			for (i, comp) in components.enumerated() {
				if i < parsedHeaders.count {
					allCols[parsedHeaders[i]] = cleanField(comp)
				}
			}

			let firstName = cleanField(components[firstNameIdx])
			let lastName = cleanField(components[lastNameIdx])
			let group = groupIdx < components.count ? cleanField(components[groupIdx]) : ""
			var barcode = (barcodeColumnIndex != nil && barcodeColumnIndex! < components.count) ? cleanField(components[barcodeColumnIndex!]) : ""
			
			// Build a stable dedup key for roster rows based on all non-metadata columns
			let dedupIgnoredHeaders: Set<String> = ["Photographed By", "Photographed At", "Last Edited By", "Last Edited At"]
			var dedupParts: [String] = []
			for (i, headerName) in parsedHeaders.enumerated() {
				if dedupIgnoredHeaders.contains(headerName) { continue }
				let value = i < components.count ? cleanField(components[i]) : ""
				dedupParts.append("\(headerName.lowercased())=\(value.lowercased())")
			}
			let rosterSignature = "\(firstName.lowercased())|\(lastName.lowercased())|\(group.lowercased())"
			let dedupKey = dedupParts.joined(separator: "|")
			
			// Generate synthetic barcode for roster mode if empty
			if barcode.isEmpty {
				barcode = "ROSTER_\(firstName.replacingOccurrences(of: " ", with: ""))_\(lastName.replacingOccurrences(of: " ", with: ""))_\(UUID().uuidString.prefix(8))"
			}
			
			// Long barcodes are processed normally
			let hasPhoto = (photoIdx < components.count) ? !cleanField(components[photoIdx]).isEmpty : false
			
			// Photographed flag can be a boolean column OR inferred from 'Photographed By/At'
			let referenceRaw = (referenceIdx < components.count) ? cleanField(components[referenceIdx]) : ""
			let photographedBy = (photographedByIdx != nil && photographedByIdx! < components.count) ? cleanField(components[photographedByIdx!]) : ""
			let photographedAt = (photographedAtIdx != nil && photographedAtIdx! < components.count) ? cleanField(components[photographedAtIdx!]) : ""
			let isPhoto = CSVService.parseBoolean(referenceRaw) || !photographedBy.isEmpty || !photographedAt.isEmpty

			guard !firstName.isEmpty, !lastName.isEmpty else { continue }

			// If duplicate full row (ignoring metadata), merge into existing entry preferring photographed/filled values
			if barcode.hasPrefix("ROSTER_"), let existingIndex = dedupKeyToIndex[dedupKey] {
				var existing = players[existingIndex]
				// Merge flags
				existing.isPhotographed = existing.isPhotographed || isPhoto
				existing.hasPhoto = existing.hasPhoto || hasPhoto
				// Merge notable columns if empty in existing
				if !photographedBy.isEmpty { existing.allColumns["Photographed By"] = photographedBy }
				if !photographedAt.isEmpty { existing.allColumns["Photographed At"] = photographedAt }
				// Keep the most complete group/name if existing values are empty
				if existing.group.isEmpty && !group.isEmpty { existing.group = group }
				if existing.firstName.isEmpty && !firstName.isEmpty { existing.firstName = firstName }
				if existing.lastName.isEmpty && !lastName.isEmpty { existing.lastName = lastName }
				players[existingIndex] = existing
				continue
			}

			let id = playerIDMap[barcode] ?? UUID()
			playerIDMap[barcode] = id

			var originalData: [String: String] = [:]
			for (columnName, value) in allCols {
				if columnName.hasSuffix("_O") && !value.isEmpty {
					let baseFieldName = String(columnName.dropLast(2))
					originalData[baseFieldName] = value
				}
			}
			
			let player = Player(
				id: id,
				firstName: firstName,
				lastName: lastName,
				group: group.isEmpty ? "No Group" : group,
				barcode: barcode,
				isPhotographed: isPhoto,
				hasPhoto: hasPhoto,
				allColumns: allCols,
				originalData: originalData
			)
			players.append(player)
			
			// Remember where this dedup key landed so future duplicates can merge into it
			if barcode.hasPrefix("ROSTER_") { dedupKeyToIndex[dedupKey] = players.count - 1 }
		}

		return (players: players, headers: parsedHeaders)
	}

	func saveCSV() {
		guard let url = currentFileURL else {
			Logger.warn("⚠️ saveCSV: No currentFileURL - skipping save (this is normal for roster mode)")
			DispatchQueue.main.async {
				self.saveStatus = "Roster mode - no save needed"
			}
			return
		}
		Logger.log("💾 saveCSV called for: \(url.lastPathComponent)")

		// Update save status
		DispatchQueue.main.async {
			self.saveStatus = "Saving..."
		}
		
		// Debounce writes to avoid frequent disk operations when rapidly marking
		pendingSaveWorkItem?.cancel()
		let work = DispatchWorkItem { [weak self, players, barcodeColumnIndex, url] in
			guard let self = self else { return }
		Logger.log("💾 saveCSV work item executing...")
			if !self.isAccessingSecurityScopedResource {
				self.isAccessingSecurityScopedResource = url.startAccessingSecurityScopedResource()
			}
			do {
				let original = try String(contentsOf: url, encoding: .utf8)
				let lines = original.components(separatedBy: .newlines)
				guard !lines.isEmpty else { return }

				// Check if we need to add original data columns
				let originalHeaders = lines[0].components(separatedBy: self.delimiter)
				var needsOriginalColumns = false
				var updatedHeaders = originalHeaders
				
				// Find all unique original data fields from all players
				var originalDataFields: Set<String> = []
				for player in players {
					for key in player.originalData.keys {
						originalDataFields.insert(key)
					}
				}
				
                Logger.log("📊 Found original data fields: \(originalDataFields)")
                Logger.log("📊 Players with original data: \(players.filter { !$0.originalData.isEmpty }.count)")
				
				// Add original data columns with _O suffix if they don't exist and there's original data
				if !originalDataFields.isEmpty {
					// Check existing original headers to avoid duplicates
					_ = originalHeaders.filter { $0.hasSuffix("_O") }
					
					for field in originalDataFields {
						let originalColumnName = "\(field)_O"
						if !originalHeaders.contains(originalColumnName) {
							needsOriginalColumns = true
							// Add a space before original columns for clarity as requested
							if updatedHeaders.last?.hasSuffix("_O") == false && !updatedHeaders.contains("") {
								updatedHeaders.append("") // Empty column for spacing
							}
							updatedHeaders.append(originalColumnName)
						}
					}
				}
				
				// Ensure metadata columns are present in the saved header
				let metadataColumns = ["Photographed By", "Photographed At", "Last Edited By", "Last Edited At"]
				var didAppendMetadata = false
				for column in metadataColumns {
					if !updatedHeaders.contains(column) {
						updatedHeaders.append(column)
						didAppendMetadata = true
					}
				}
				// If we added metadata columns, mark header as updated so we write it out
				if didAppendMetadata { needsOriginalColumns = true }
				
				var updatedLines: [String] = []
				
				// Add header line (updated if needed)
				if needsOriginalColumns {
					updatedLines.append(updatedHeaders.joined(separator: self.delimiter))
				} else {
					updatedLines.append(lines[0])
				}
				
				let dict = Dictionary(uniqueKeysWithValues: players.map { ($0.barcode, $0) })
				// Build a roster key map for name+team updates when no barcode column exists (current values)
				func normalizeGroup(_ g: String) -> String {
					let v = g.lowercased().trim()
					if v.isEmpty || v == "no group" { return "no group" }
					return v
				}
				let rosterDict: [String: Player] = players.reduce(into: [:]) { acc, p in
					let key = "\(p.firstName.lowercased().trim())|\(p.lastName.lowercased().trim())|\(normalizeGroup(p.group))"
					// Prefer photographed entries when duplicates exist
					if let existing = acc[key] {
						let scoreExisting = (existing.isPhotographed ? 1 : 0) + ((existing.allColumns["Photographed By"]?.isEmpty == false) ? 1 : 0)
						let scoreNew = (p.isPhotographed ? 1 : 0) + ((p.allColumns["Photographed By"]?.isEmpty == false) ? 1 : 0)
						if scoreNew > scoreExisting { acc[key] = p }
					} else {
						acc[key] = p
					}
				}
				// Also build a map using original name+team (so 'Add Subject' rows get updated)
				let originalRosterDict: [String: Player] = players.reduce(into: [:]) { acc, p in
					// Try to fetch original first/last/group from stored originalData using alias headers
					func origValue(_ aliases: [String]) -> String? {
						for (k, v) in p.originalData {
							if aliases.contains(where: { k.caseInsensitiveCompare($0) == .orderedSame }) {
								return v
							}
						}
						return nil
					}
					let origFirst = origValue(HeaderAliases.firstName)
					let origLast = origValue(HeaderAliases.lastName)
					let origGroup = origValue(HeaderAliases.group)
					if let of = origFirst?.lowercased().trim(), let ol = origLast?.lowercased().trim(), let ogv = origGroup?.lowercased().trim(), !of.isEmpty || !ol.isEmpty {
						let key = "\(of)|\(ol)|\(normalizeGroup(ogv))"
						// Prefer the most complete/photographed entry
						if let existing = acc[key] {
							let scoreExisting = (existing.isPhotographed ? 1 : 0) + ((existing.allColumns["Photographed By"]?.isEmpty == false) ? 1 : 0)
							let scoreNew = (p.isPhotographed ? 1 : 0) + ((p.allColumns["Photographed By"]?.isEmpty == false) ? 1 : 0)
							if scoreNew > scoreExisting { acc[key] = p }
						} else {
							acc[key] = p
						}
					}
				}

				for line in lines.dropFirst() {
					guard !line.trim().isEmpty else { continue }
					var comps = line.components(separatedBy: self.delimiter)
					
					// Extend components array if we added new columns
					while comps.count < updatedHeaders.count {
						comps.append("")
					}
					
					if let idx = barcodeColumnIndex, comps.count > idx {
						let code = comps[idx].trim().trimmingCharacters(in: CharacterSet(charactersIn: "\""))
						if let pl = dict[code] {
						// Debug for specific barcode (commented out to reduce console noise)
						// if code == "851575881907221" { 
						//     print("💾 Processing player with barcode \(code): \(pl.firstName) \(pl.lastName)")
						//     print("💾 allColumns['Student firstname'] = '\(pl.allColumns["Student firstname"] ?? "nil")'")
						// }
							// Update all columns according to the updated headers
							for (hIdx, hName) in updatedHeaders.enumerated() {
								if hIdx < comps.count {
									// Update existing column position
									if hName.hasSuffix("_O") {
										// This is an original data column
										let baseFieldName = String(hName.dropLast(2)) // Remove "_O" suffix
										if let originalValue = pl.originalData[baseFieldName] {
											comps[hIdx] = "\"\(originalValue)\""
											// Debug: Setting _O column '\(hName)' = '\(originalValue)'
										} else {
											comps[hIdx] = "" // Empty if no original data
										}
									} else {
										// This is a main column - use current value from allColumns
										// Remove quotes from header name for lookup
										let cleanHeaderName = hName.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
										if let currentValue = pl.allColumns[cleanHeaderName] {
											let oldValue = comps[hIdx]
											comps[hIdx] = "\"\(currentValue)\""
							// Removed excessive debug logging for Student firstname updates
										}
									}
								} else {
									// This is a new column we're adding
									if hName.hasSuffix("_O") {
										let baseFieldName = String(hName.dropLast(2))
										if let originalValue = pl.originalData[baseFieldName] {
											comps.append("\"\(originalValue)\"")
											// Debug: Appending _O column '\(hName)' = '\(originalValue)'
										} else {
											comps.append("")
										}
									} else {
										// Remove quotes from header name for lookup
										let cleanHeaderName = hName.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
										if let currentValue = pl.allColumns[cleanHeaderName] {
											comps.append("\"\(currentValue)\"")
							// Removed excessive debug logging for Student firstname appends
										} else {
											comps.append("")
										}
									}
								}
							}
						}
					} else if self.isRosterMode {
						// Match by First + Last + Group in roster CSVs (no barcode column)
						let fnIdx = CSVService.findHeaderIndex(in: updatedHeaders, equalsAny: HeaderAliases.firstName)
						let lnIdx = CSVService.findHeaderIndex(in: updatedHeaders, equalsAny: HeaderAliases.lastName)
						let gpIdx = CSVService.findHeaderIndex(in: updatedHeaders, equalsAny: HeaderAliases.group)
						if let fi = fnIdx, let li = lnIdx, let gi = gpIdx,
						   fi < comps.count, li < comps.count, gi < comps.count {
							let fn = comps[fi].trim().trimmingCharacters(in: CharacterSet(charactersIn: "\""))
							let ln = comps[li].trim().trimmingCharacters(in: CharacterSet(charactersIn: "\""))
							let gp = comps[gi].trim().trimmingCharacters(in: CharacterSet(charactersIn: "\""))
							let key = "\(fn.lowercased())|\(ln.lowercased())|\(normalizeGroup(gp))"
							// Prefer exact match on current values; fallback to original values
							let playerMatch = rosterDict[key] ?? originalRosterDict[key]
							if let pl = playerMatch {
								for (hIdx, hName) in updatedHeaders.enumerated() {
									if hIdx < comps.count {
										if hName.hasSuffix("_O") {
											let baseFieldName = String(hName.dropLast(2))
											if let originalValue = pl.originalData[baseFieldName] {
												comps[hIdx] = "\"\(originalValue)\""
											} else {
												comps[hIdx] = ""
											}
										} else {
											let cleanHeaderName = hName.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
											if let v = pl.allColumns[cleanHeaderName] {
												comps[hIdx] = "\"\(v)\""
											}
										}
									} else {
										if hName.hasSuffix("_O") {
											let baseFieldName = String(hName.dropLast(2))
											if let originalValue = pl.originalData[baseFieldName] {
												comps.append("\"\(originalValue)\"")
											} else {
												comps.append("")
											}
										} else {
											let cleanHeaderName = hName.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
											if let v = pl.allColumns[cleanHeaderName] {
												comps.append("\"\(v)\"")
											} else {
												comps.append("")
											}
										}
									}
								}
							}
						}
					}
					updatedLines.append(comps.joined(separator: self.delimiter))
				}

				// Secondary pass: explicitly replace original "Add Subject" style rows by original values if still present
				if self.isRosterMode {
					let fnIdx = CSVService.findHeaderIndex(in: updatedHeaders, equalsAny: HeaderAliases.firstName)
					let lnIdx = CSVService.findHeaderIndex(in: updatedHeaders, equalsAny: HeaderAliases.lastName)
					let gpIdx = CSVService.findHeaderIndex(in: updatedHeaders, equalsAny: HeaderAliases.group)
					if let fi = fnIdx, let li = lnIdx, let gi = gpIdx {
						// Build quick lookup of updated lines
						for (lineIndex, line) in updatedLines.enumerated() where lineIndex > 0 {
							// nothing here; we'll search per player for exact match when needed
							_ = line
						}
						for p in players {
							// Need original values to target the placeholder row
							guard let origFirstKeyIdx = CSVService.findHeaderIndex(in: Array(p.originalData.keys), equalsAny: HeaderAliases.firstName),
								  let origLastKeyIdx = CSVService.findHeaderIndex(in: Array(p.originalData.keys), equalsAny: HeaderAliases.lastName)
							else { continue }
							let origFirstKey = Array(p.originalData.keys)[origFirstKeyIdx]
							let origLastKey = Array(p.originalData.keys)[origLastKeyIdx]
							let origFirst = p.originalData[origFirstKey]?.trim() ?? ""
							let origLast = p.originalData[origLastKey]?.trim() ?? ""
							let origGroup: String = {
								if let gkIdx = CSVService.findHeaderIndex(in: Array(p.originalData.keys), equalsAny: HeaderAliases.group) {
									let gk = Array(p.originalData.keys)[gkIdx]
									return p.originalData[gk]?.trim() ?? ""
								}
								return ""
							}()
							guard !origFirst.isEmpty || !origLast.isEmpty else { continue }
							
							// Search updatedLines for a row that still has original First/Last/Group
							for idx in 1..<updatedLines.count {
								var rowComps = updatedLines[idx].components(separatedBy: self.delimiter)
								while rowComps.count < updatedHeaders.count { rowComps.append("") }
								func clean(_ s: String) -> String { s.trim().trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
								let f = fi < rowComps.count ? clean(rowComps[fi]).lowercased() : ""
								let l = li < rowComps.count ? clean(rowComps[li]).lowercased() : ""
								let g = gi < rowComps.count ? clean(rowComps[gi]).lowercased() : ""
								// Treat empty group and "No Group" as equivalent
								let og = origGroup.lowercased()
								let groupMatches = (g == og) || (g.isEmpty && og == "no group") || (g == "no group" && og.isEmpty)
								if f == origFirst.lowercased() && l == origLast.lowercased() && groupMatches {
									// Overwrite with player's current values
									rowComps[fi] = "\"\(p.firstName)\""
									rowComps[li] = "\"\(p.lastName)\""
									rowComps[gi] = "\"\(p.group == "No Group" ? "" : p.group)\""
									updatedLines[idx] = rowComps.joined(separator: self.delimiter)
									break
								}
							}
						}
					}
				}

				// Add new rows for players that don't exist in the original CSV (like manual placeholders)
				if let idx = barcodeColumnIndex {
					let existingBarcodes = Set(lines.dropFirst().compactMap { line -> String? in
						guard !line.trim().isEmpty else { return nil }
						let comps = line.components(separatedBy: self.delimiter)
						guard idx < comps.count else { return nil }
						return comps[idx].trim().trimmingCharacters(in: CharacterSet(charactersIn: "\""))
					})
					
					let newPlayers = players.filter { !existingBarcodes.contains($0.barcode) }
					
					if !newPlayers.isEmpty {
						print("💾 Adding \(newPlayers.count) new rows to CSV")
						for newPlayer in newPlayers {
							var newRow: [String] = []
							for header in updatedHeaders {
								let cleanHeaderName = header.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
								if header.hasSuffix("_O") {
									// Original data column
									let baseFieldName = String(header.dropLast(2))
									if let originalValue = newPlayer.originalData[baseFieldName] {
										newRow.append("\"\(originalValue)\"")
									} else {
										newRow.append("")
									}
								} else if let value = newPlayer.allColumns[cleanHeaderName], !value.isEmpty {
									newRow.append("\"\(value)\"")
								} else {
									newRow.append("")
								}
							}
							updatedLines.append(newRow.joined(separator: self.delimiter))
							print("💾 Added new row for barcode: \(newPlayer.barcode)")
						}
					}
				} else {
					// Roster mode (no barcode column): append only truly new players by First+Last+Team
					Logger.log("💾 Roster mode (no barcode): computing new rows to append by name+team")
					
					// Build set of existing name+team keys from the UPDATED lines (post in-place updates)
					let fnIdx = CSVService.findHeaderIndex(in: updatedHeaders, equalsAny: HeaderAliases.firstName)
					let lnIdx = CSVService.findHeaderIndex(in: updatedHeaders, equalsAny: HeaderAliases.lastName)
					let gpIdx = CSVService.findHeaderIndex(in: updatedHeaders, equalsAny: HeaderAliases.group)
					
					var existingKeys: Set<String> = []
					if let fi = fnIdx, let li = lnIdx, let gi = gpIdx {
						for line in updatedLines.dropFirst() {
							guard !line.trim().isEmpty else { continue }
							let comps = line.components(separatedBy: self.delimiter)
							if fi < comps.count, li < comps.count, gi < comps.count {
								let fn = comps[fi].trim().trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
								let ln = comps[li].trim().trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
								let gp = comps[gi].trim().trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
								existingKeys.insert("\(fn)|\(ln)|\(gp)")
							}
						}
					}
					
					// Determine which players are new by name+team
					let newPlayers = players.filter { p in
						let key = "\(p.firstName.lowercased().trim())|\(p.lastName.lowercased().trim())|\(p.group.lowercased().trim())"
						return !existingKeys.contains(key)
					}
					
					Logger.log("💾 Roster mode: appending \(newPlayers.count) new rows")
					
					for pl in newPlayers {
						var newRow: [String] = []
						for header in updatedHeaders {
							let cleanHeaderName = header.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
							if header.hasSuffix("_O") {
								let baseFieldName = String(header.dropLast(2))
								if let originalValue = pl.originalData[baseFieldName] {
									newRow.append("\"\(originalValue)\"")
								} else {
									newRow.append("")
								}
							} else if let value = pl.allColumns[cleanHeaderName], !value.isEmpty {
								newRow.append("\"\(value)\"")
							} else {
								newRow.append("")
							}
						}
						updatedLines.append(newRow.joined(separator: self.delimiter))
					}
				}

				let joined = updatedLines.joined(separator: "\n")
				// Debug: Writing CSV with \(updatedLines.count) lines
				// Debug: Headers: \(updatedHeaders)
				try joined.write(to: url, atomically: true, encoding: .utf8)
				print("✅ CSV saved successfully to: \(url.path)")

				// Update save status
				DispatchQueue.main.async {
					self.saveStatus = "All changes saved"
				}

				// Update csvHeaders to include new original data columns
				if needsOriginalColumns {
					print("🔄 Updating csvHeaders with new original columns")
					DispatchQueue.main.async {
						self.csvHeaders = updatedHeaders.map { $0.trim().replacingOccurrences(of: "\"", with: "") }
					}
				}
			} catch {
				print("❌ Failed to save CSV: \(error)")
			}
		}
		pendingSaveWorkItem = work
		saveQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
	}

	func updatePlayer(_ player: Player) {
		if let i = players.firstIndex(where: { $0.id == player.id }) {
			let originalPlayer = players[i]
			var updatedPlayer = player
			
			// Store original data for changed fields
			
			// Store original values for name/group fields using actual CSV header names (aliases supported)
			let firstHeader: String? = {
				if let idx = CSVService.findHeaderIndex(in: csvHeaders, equalsAny: HeaderAliases.firstName) { return csvHeaders[idx] }
				return nil
			}()
			let lastHeader: String? = {
				if let idx = CSVService.findHeaderIndex(in: csvHeaders, equalsAny: HeaderAliases.lastName) { return csvHeaders[idx] }
				return nil
			}()
			let groupHeader: String? = {
				if let idx = CSVService.findHeaderIndex(in: csvHeaders, equalsAny: HeaderAliases.group) { return csvHeaders[idx] }
				return nil
			}()
			if let h = firstHeader {
				let orig = originalPlayer.allColumns[h] ?? originalPlayer.firstName
				let newv = updatedPlayer.allColumns[h] ?? updatedPlayer.firstName
				if orig != newv, !orig.isEmpty, !originalPlayer.hasOriginalValue(for: h) {
					updatedPlayer.originalData[h] = orig
				}
			}
			if let h = lastHeader {
				let orig = originalPlayer.allColumns[h] ?? originalPlayer.lastName
				let newv = updatedPlayer.allColumns[h] ?? updatedPlayer.lastName
				if orig != newv, !orig.isEmpty, !originalPlayer.hasOriginalValue(for: h) {
					updatedPlayer.originalData[h] = orig
				}
			}
			if let h = groupHeader {
				let orig = originalPlayer.allColumns[h] ?? originalPlayer.group
				let newv = updatedPlayer.allColumns[h] ?? updatedPlayer.group
				if orig != newv, !orig.isEmpty, !originalPlayer.hasOriginalValue(for: h) {
					updatedPlayer.originalData[h] = orig
				}
			}
			
			// Handle barcode field using player properties
			if let barcodeHeader = csvHeaders.first(where: { $0.contains("Barcode") || $0 == "Child ID" }) {
				let originalBarcodeValue = originalPlayer.barcode
				let newBarcodeValue = updatedPlayer.barcode
				let hasBarcodeOriginal = originalPlayer.hasOriginalValue(for: barcodeHeader)
				
				if originalBarcodeValue != newBarcodeValue,
				   !originalBarcodeValue.isEmpty,
				   !hasBarcodeOriginal {
					updatedPlayer.originalData[barcodeHeader] = originalBarcodeValue
				}
			}
			
			
			// Preserve existing original data from the original player
			for (key, value) in originalPlayer.originalData {
				if updatedPlayer.originalData[key] == nil {
					updatedPlayer.originalData[key] = value
				}
			}
			
			// Add Last Edited metadata (local time, sortable format)
			let formatter = DateFormatter()
			formatter.locale = Locale(identifier: "en_US_POSIX")
			formatter.timeZone = .current
			formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
			let timestamp = formatter.string(from: Date())
			let editorID = photographerID.isEmpty ? "Single Photographer" : photographerID
			updatedPlayer.allColumns["Last Edited By"] = editorID
			updatedPlayer.allColumns["Last Edited At"] = timestamp
			
			players[i] = updatedPlayer
			
			// Refresh the entire groups list to add new groups and remove unused ones
			refreshGroupsFromPlayers()
			
			saveCSV()
		}
	}

	func markAsPhotographed(id: UUID) {
		if let i = players.firstIndex(where: { $0.id == id }) {
			var updatedPlayer = players[i]
			updatedPlayer.isPhotographed = true
			
			let formatter = DateFormatter()
			formatter.locale = Locale(identifier: "en_US_POSIX")
			formatter.timeZone = .current
			formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
			let timestamp = formatter.string(from: Date())
			
			// Set Reference = yes
			if let ref = csvHeaders.first(where: { $0 == "Reference" }) {
				updatedPlayer.allColumns[ref] = "yes"
			}
			
			// Set photographer metadata (only if not already set)
			if updatedPlayer.allColumns["Photographed By"]?.isEmpty != false {
				let shooterID = photographerID.isEmpty ? "Single Photographer" : photographerID
				updatedPlayer.allColumns["Photographed By"] = shooterID
				updatedPlayer.allColumns["Photographed At"] = timestamp
			}
			
			players[i] = updatedPlayer
			saveCSV()
		}
	}

	func markAsNotPhotographed(id: UUID) {
		if let i = players.firstIndex(where: { $0.id == id }) {
			var updatedPlayer = players[i]
			updatedPlayer.isPhotographed = false
			if let ref = csvHeaders.first(where: { $0 == "Reference" }) {
				updatedPlayer.allColumns[ref] = ""
			}
			// Clear photographed metadata when unmarking
			updatedPlayer.allColumns["Photographed By"] = ""
			updatedPlayer.allColumns["Photographed At"] = ""
			players[i] = updatedPlayer
			saveCSV()
		}
	}
	
	func addNewGroup(_ groupName: String) {
		let trimmedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedName.isEmpty, !uniqueGroups.contains(trimmedName), trimmedName != "No Group" else { return }
		uniqueGroups.append(trimmedName)
		uniqueGroups.sort()
		// Immediately sync to shared state
		appState?.addSharedGroup(trimmedName)
		// Added new group: \(trimmedName)
	}
	
	func syncWithSharedGroups(_ sharedGroups: [String]) {
		// Add shared groups that aren't in CSV groups yet
		for group in sharedGroups {
			if !uniqueGroups.contains(group) && group != "No Group" {
				uniqueGroups.append(group)
			}
		}
		uniqueGroups.sort()
	}
	
	private func ensureMetadataColumns() {
		let requiredColumns = ["Photographed By", "Photographed At", "Last Edited By", "Last Edited At"]
		var columnsToAdd: [String] = []
		
		for column in requiredColumns {
			if !csvHeaders.contains(column) {
				columnsToAdd.append(column)
			}
		}
		
		if !columnsToAdd.isEmpty {
			// Add missing columns to headers
			csvHeaders.append(contentsOf: columnsToAdd)
			
			// Add empty values for existing players
			for i in players.indices {
				for column in columnsToAdd {
					players[i].allColumns[column] = ""
				}
			}
		}
	}
	
	/// Clear all loaded CSV data (for folder switching)
	func clearLoadedData() {
		DispatchQueue.main.async {
			self.players = []
			self.uniqueGroups = []
			self.csvHeaders = []
			self.currentFileName = "Names List"
			self.currentFileURL = nil
			self.playerIDMap = [:]
			
			// Stop accessing security scoped resource if needed
			if self.isAccessingSecurityScopedResource {
				self.currentFileURL?.stopAccessingSecurityScopedResource()
				self.isAccessingSecurityScopedResource = false
			}
			
			self.isLoading = false
		}
		
		// Clear shared groups to prevent persistence across different CSV files
		appState?.replaceSharedGroups([])
	}
	
	/// Refresh the groups list from all current players - rebuilds the entire list
	func refreshGroupsFromPlayers() {
		let currentGroups = Set(players.map { $0.group }.filter { !$0.isEmpty && $0 != "No Group" })
		var currentGroupsArray = Array(currentGroups).sorted()
		
		// Add "No Group" if there are players without groups
		let hasPlayersWithoutGroups = players.contains { $0.group.isEmpty || $0.group == "No Group" }
		if hasPlayersWithoutGroups {
			currentGroupsArray.append("No Group")
		}
		
		// Only update if the groups have actually changed
		if Set(uniqueGroups) != Set(currentGroupsArray) {
			// Ensure UI updates happen on main thread
			if Thread.isMainThread {
				uniqueGroups = currentGroupsArray
				appState?.replaceSharedGroups(currentGroupsArray)
			} else {
				DispatchQueue.main.async {
					self.uniqueGroups = currentGroupsArray
					self.appState?.replaceSharedGroups(currentGroupsArray)
				}
			}
		}
	}
	
	// MARK: - Roster Mode Functions
	
	/// Auto-detect roster columns from CSV headers
	func autoDetectRosterColumns(_ headers: [String]) -> ColumnMappings {
		var mappings = ColumnMappings()
		
		// Filter out empty headers first
		let nonEmptyHeaders = headers.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
		Logger.log("🧹 Filtered headers (removed empty): \(nonEmptyHeaders)")
		
		// First name detection
		let firstNameAliases = ["first", "firstname", "fname", "given", "first name"]
		mappings.firstName = nonEmptyHeaders.first { header in
			let lower = header.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
			return firstNameAliases.contains { lower.contains($0) }
		}
		
		// Last name detection  
		let lastNameAliases = ["last", "lastname", "surname", "lname", "family", "last name"]
		mappings.lastName = nonEmptyHeaders.first { header in
			let lower = header.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
			return lastNameAliases.contains { lower.contains($0) }
		}
		
		// Full name detection (only if we don't have first/last)
		if mappings.firstName == nil || mappings.lastName == nil {
			let nameAliases = ["name", "player", "student", "person", "full name", "fullname"]
			mappings.fullName = nonEmptyHeaders.first { header in
				let lower = header.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
				return nameAliases.contains { alias in
					lower == alias || (lower.contains(alias) && !lower.contains("first") && !lower.contains("last"))
				}
			}
			Logger.log("🔤 Full name detection: searching for \(nameAliases) in \(nonEmptyHeaders.map { $0.lowercased() })")
			Logger.log("🔤 Found full name column: \(mappings.fullName ?? "nil")")
		}
		
		// Team detection
		let teamAliases = ["team", "group", "class", "division", "squad", "homeroom"]
		mappings.team = nonEmptyHeaders.first { header in
			let lower = header.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
			return teamAliases.contains { lower.contains($0) }
		}
		
		Logger.log("🎯 Auto-detected roster columns: firstName=\(mappings.firstName ?? "nil"), lastName=\(mappings.lastName ?? "nil"), fullName=\(mappings.fullName ?? "nil"), team=\(mappings.team ?? "nil")")
		
		return mappings
	}
	
	/// Check if CSV appears to be a roster (no barcode column)
	func detectRosterMode(_ headers: [String], players: [Player]) -> Bool {
		Logger.log("🔍 Detecting roster mode for headers: \(headers)")
		
		// Check if we have any barcode-like columns
		let hasBarcodeColumn = CSVService.findHeaderIndexWithPriority(in: headers, prioritizedCandidates: HeaderAliases.barcodeExact) != nil ||
							   CSVService.findHeaderIndex(in: headers, containsAny: HeaderAliases.barcodeContains) != nil
		
		Logger.log("📊 Has barcode column: \(hasBarcodeColumn)")
		
		// If there's a barcode column, check if it's actually populated with data
		// (some roster CSVs might have empty barcode columns)
		if hasBarcodeColumn && !players.isEmpty {
			let hasRealBarcodes = players.contains { !$0.barcode.hasPrefix("ROSTER_") && !$0.barcode.isEmpty }
			Logger.log("🏷️ Has real barcodes: \(hasRealBarcodes)")
			if hasRealBarcodes {
				Logger.log("❌ Not a roster - has real barcode data")
				return false // Has real barcodes, not a roster
			}
		}
		
		// Check if we can detect name and team columns
		let mappings = autoDetectRosterColumns(headers)
		Logger.log("🎯 Column mappings valid: \(mappings.isValid)")
		Logger.log("📝 Mappings: firstName=\(mappings.firstName ?? "nil"), lastName=\(mappings.lastName ?? "nil"), fullName=\(mappings.fullName ?? "nil"), team=\(mappings.team ?? "nil")")
		
		let isRoster = mappings.isValid
		Logger.log("🏆 Final roster detection result: \(isRoster)")
		return isRoster
	}
	
	/// Generate roster-style output for Capture One
	func generateRosterOutput(for player: Player) -> String {
		let playerName = columnMappings.getDisplayName(from: player)
		let teamName = columnMappings.getTeamName(from: player)
		
		// Format: Team_PlayerName_
		return "\(teamName)_\(playerName)_"
	}
}

// MARK: - CSV Mode View
// MARK: - Toast Types
enum ToastType {
	case success, error, info
}

// MARK: - CSV Mode View
struct CSVModeView: View {
	@StateObject private var csvManager = CSVManager()
	@State private var selectedPlayerID: UUID?
	@State private var searchText = ""
	@State private var lastJobFolderURL: URL?
	@State private var showOnlyUnphotographed = false
	@State private var showMyWorkOnly = false
	@State private var showCopiedBanner = false
	@State private var copiedBarcode = ""
	@State private var copiedPlayerName = ""
	@State private var editingPlayer: Player?
	@State private var selectedGroups: [String: Bool] = [:]
	@State private var showingGroupFilter = false
	@State private var showingMergeCSVs = false
    // Legacy dual setup removed; consolidated under Settings
	@FocusState private var isSearchFocused: Bool
	@Environment(\.horizontalSizeClass) var horizontalSizeClass
	@EnvironmentObject var appState: AppStateManager
	@State private var isCaptureOneRunning = false

	// Toast notifications
	@State private var showToast = false
	@State private var toastMessage = ""
	@State private var toastType: ToastType = .success
	@State private var toastAction: (() -> Void)?

	// Toast notification helpers
	private func showToast(_ message: String, type: ToastType = .success, action: (() -> Void)? = nil) {
		toastMessage = message
		toastType = type
		toastAction = action
		showToast = true

		// Auto-hide after 4 seconds
		DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
			showToast = false
		}
	}

	// Check if Capture One is running
	private func checkCaptureOneStatus() {
		// Use runningApplications instead of spawning a process for sandbox safety
		let running = NSWorkspace.shared.runningApplications
		isCaptureOneRunning = running.contains { app in
			(app.localizedName?.contains("Capture One") ?? false) ||
			(app.bundleIdentifier?.contains("com.phaseone.captureone") ?? false)
		}
	}

	// Lightweight file preview for Recents tooltip
	private func filePreview(for url: URL) -> String {
		guard url.pathExtension.lowercased() == "csv",
			let content = try? String(contentsOf: url, encoding: .utf8) else { return url.lastPathComponent }
		let lines = content.components(separatedBy: .newlines).filter { !$0.trim().isEmpty }
		guard !lines.isEmpty else { return url.lastPathComponent }
		let headerLine = lines[0]
		let delimiter = headerLine.contains(",") ? "," : ";"
		let headers = headerLine.components(separatedBy: delimiter).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "") }
		let count = max(lines.count - 1, 0)
		let headerPreview = headers.prefix(4).joined(separator: ", ") + (headers.count > 4 ? ", …" : "")
		return "\(url.lastPathComponent) — \(count) rows — [\(headerPreview)]"
	}
	@State private var viewWidth: CGFloat = DesignSystem.narrowWindowWidth

	// Buddy Photo Mode
	@State private var isBuddyMode = false
	@State private var buddySelectedPlayerIDs: Set<UUID> = []
	
	// Edit Copyright Mode
	@State private var isEditCopyrightMode = false
	
	private var isNarrowLayout: Bool {
		DesignSystem.isNarrowLayout(width: viewWidth)
	}

	private var placeholderPlayersSorted: [Player] {
		let placeholders = csvManager.players.filter { $0.firstName == "Add" && $0.lastName.hasPrefix("Subject") }
		return placeholders.sorted { a, b in
			let na = extractTrailingNumber(from: a.lastName)
			let nb = extractTrailingNumber(from: b.lastName)
			if na != nb { return na < nb }
			// Stable fallback when numbers equal or missing
			return a.barcode < b.barcode
		}
	}

	private func extractTrailingNumber(from text: String) -> Int {
		let digitsReversed = text.reversed().prefix { $0.isNumber }
		let digits = String(digitsReversed.reversed())
		return Int(digits) ?? Int.max
	}

	private func baseNameWithoutTrailingNumber(from text: String) -> String {
		let digitsReversed = text.reversed().prefix { $0.isNumber }
		let dropCount = digitsReversed.count
		let base = String(text.dropLast(dropCount))
		return base.trimmingCharacters(in: .whitespaces)
	}

	private func indexForPlaceholder(number: Int) -> Int? {
		placeholderPlayersSorted.firstIndex { extractTrailingNumber(from: $0.lastName) == number }
	}

	private var realPlayers: [Player] {
		csvManager.players.filter { !($0.firstName == "Add" && $0.lastName.hasPrefix("Subject")) }
	}

	private var notPhotographedCount: Int {
		realPlayers.filter { !$0.isPhotographed }.count
	}

	private var playersFilteredByPhotographStatus: [Player] {
		var filtered = realPlayers
		
		if showOnlyUnphotographed {
			filtered = filtered.filter { !$0.isPhotographed }
		}
		
		if showMyWorkOnly {
			filtered = filtered.filter { player in
				player.allColumns["Photographed By"] == csvManager.photographerID ||
				player.allColumns["Last Edited By"] == csvManager.photographerID
			}
		}
		
		return filtered
	}

	private var playersFilteredBySearch: [Player] {
		if searchText.isEmpty {
			return playersFilteredByPhotographStatus
		}
		return playersFilteredByPhotographStatus.filter { player in
			player.fullName.localizedCaseInsensitiveContains(searchText) ||
			player.firstName.localizedCaseInsensitiveContains(searchText) ||
			player.lastName.localizedCaseInsensitiveContains(searchText) ||
			player.barcode.localizedCaseInsensitiveContains(searchText)
		}
	}

	private var playersFilteredByGroup: [Player] {
		if selectedGroups.isEmpty || !selectedGroups.contains(where: { $0.value }) {
			return playersFilteredBySearch
		}
		return playersFilteredBySearch.filter { player in
			// Include players with groups that are selected
			if !player.group.isEmpty && player.group != "No Group" {
				return selectedGroups[player.group] == true
			}
			// Include players without groups if "No Group" is selected or if all groups are selected
			else {
				return selectedGroups["No Group"] == true || selectedGroups.values.allSatisfy { $0 }
			}
		}
	}

	var filteredPlayers: [Player] {
		playersFilteredByGroup.sorted { a, b in
			let aBase = baseNameWithoutTrailingNumber(from: a.fullName)
			let bBase = baseNameWithoutTrailingNumber(from: b.fullName)
			if aBase != bBase { return aBase < bBase }
			let aNum = extractTrailingNumber(from: a.fullName)
			let bNum = extractTrailingNumber(from: b.fullName)
			if aNum != bNum { return aNum < bNum }
			return a.fullName < b.fullName
		}
	}

	@ViewBuilder
	private func fileHeaderView(geometry: GeometryProxy) -> some View {
				if csvManager.currentFileName != "Names List" {
			CSVFileHeaderView(csvManager: csvManager, geometry: geometry)
					.padding(.horizontal, DesignSystem.adaptivePadding(for: viewWidth))
					.padding(.top, isNarrowLayout ? DesignSystem.microSpacing : (horizontalSizeClass == .compact ? 8 : 12))
				}
	}

	@ViewBuilder
	private func searchAndToolbarView(geometry: GeometryProxy) -> some View {
		CSVSearchAndToolbarView(
			csvManager: csvManager,
			searchText: $searchText,
			showOnlyUnphotographed: $showOnlyUnphotographed,
			isBuddyMode: $isBuddyMode,
			isEditCopyrightMode: $isEditCopyrightMode,
			editingPlayer: $editingPlayer,
			showingMergeCSVs: $showingMergeCSVs,
			selectedGroups: $selectedGroups,
			showingGroupFilter: $showingGroupFilter,
			geometry: geometry,
			viewWidth: viewWidth,
			horizontalSizeClass: horizontalSizeClass,
			buddySelectedPlayerIDs: $buddySelectedPlayerIDs,
			executeBuddyCopy: executeBuddyCopy,
			handlePlayerTap: handlePlayerTap
		)
	}
	
	@ViewBuilder
	private func groupsFilterBarView(geometry: GeometryProxy) -> some View {
		CSVGroupsFilterBarView(
			csvManager: csvManager,
			selectedGroups: $selectedGroups,
			showingGroupFilter: $showingGroupFilter,
			geometry: geometry,
			viewWidth: viewWidth,
			horizontalSizeClass: horizontalSizeClass
		)
	}

	@ViewBuilder
	private func statsBarView(geometry: GeometryProxy) -> some View {
		CSVStatsBarView(
			csvManager: csvManager,
			geometry: geometry,
			viewWidth: viewWidth,
			filteredPlayers: filteredPlayers,
			realPlayers: realPlayers,
			notPhotographedCount: notPhotographedCount,
			buddySelectedPlayerIDs: Array(buddySelectedPlayerIDs),
			isBuddyMode: isBuddyMode,
			isEditCopyrightMode: isEditCopyrightMode
		)
	}

	var body: some View {
		GeometryReader { geometry in
			VStack(spacing: 0) {
				fileHeaderView(geometry: geometry)
				searchAndToolbarView(geometry: geometry)
				groupsFilterBarView(geometry: geometry)
				statsBarView(geometry: geometry)

				// Players list with scroll-to-selection support
				CSVPlayersListView(
					csvManager: csvManager,
					filteredPlayers: filteredPlayers,
					selectedPlayerID: $selectedPlayerID,
					buddySelectedPlayerIDs: buddySelectedPlayerIDs,
					isBuddyMode: isBuddyMode,
					editingPlayer: $editingPlayer,
					handlePlayerTap: handlePlayerTap
				)
				// Joke Bar
				JokeBarView()
					.padding(.top, isNarrowLayout ? DesignSystem.narrowSpacing : 12)
					.environmentObject(appState)

			// Footer with status
			HStack(spacing: 16) {
				// Save status
				HStack(spacing: 4) {
					Image(systemName: csvManager.saveStatus == "Saving..." ? "circle.dashed" : "checkmark.circle")
						.foregroundColor(csvManager.saveStatus == "Saving..." ? .orange : .green)
						.font(.caption)
					Text(csvManager.saveStatus)
						.font(.caption)
						.foregroundColor(.secondary)
				}

				Spacer()

				// Capture One status
				Button(action: { checkCaptureOneStatus() }) {
					HStack(spacing: 4) {
						Image(systemName: isCaptureOneRunning ? "camera.fill" : "camera")
							.foregroundColor(isCaptureOneRunning ? .green : .secondary)
							.font(.caption)
						Text(isCaptureOneRunning ? "Capture One Connected" : "Capture One Not Running")
							.font(.caption)
							.foregroundColor(.secondary)
					}
					.padding(.horizontal, 8)
					.padding(.vertical, 4)
					.background(Color.secondary.opacity(0.1))
					.clipShape(RoundedRectangle(cornerRadius: 12))
				}
				.buttonStyle(.plain)
				.help(isCaptureOneRunning ? "Capture One is running and ready for integration" : "Click to check Capture One status")
			}
			.padding(.horizontal, DesignSystem.adaptivePadding(for: viewWidth))
			.padding(.vertical, 8)
			}
			.onAppear {
				viewWidth = geometry.size.width
			}
			.onChange(of: geometry.size.width) { _, newWidth in
				viewWidth = newWidth
			}
		}
		.sheet(item: $editingPlayer) { player in
			EditPlayerSheet(
				player: player,
				csvHeaders: csvManager.csvHeaders,
				availableGroups: csvManager.uniqueGroups,
				placeholderPlayers: placeholderPlayersSorted,
				csvManager: csvManager,
				onSave: { updated in
					csvManager.updatePlayer(updated)
					// Highlight the edited (now real) player in the list after sheet closes
					selectedPlayerID = updated.id
				},
				onNavigateIndexChange: { newIndex in
					// No longer remember position - always start from lowest number
				},
				onAdvanceToNextFrom: { lastPlaceholderNumber in
					// No longer remember position - always start from lowest number
				}
			)
			.onDisappear {
				// Restore focus to search after closing edit
				isSearchFocused = true
			}
		}
		.sheet(isPresented: $showingMergeCSVs) {
			MergeCSVsView(currentCSV: appState.detectedCSVFile)
				.environmentObject(appState)
		}
		.sheet(isPresented: $csvManager.showingColumnMapping) {
			ColumnMappingView(csvManager: csvManager)
		}
        // Dual setup modal removed; use Settings
		.alert("Error", isPresented: .constant(csvManager.errorMessage != nil)) {
			Button("OK") { csvManager.errorMessage = nil }
		} message: {
			Text(csvManager.errorMessage ?? "")
		}
		.overlay(alignment: .center) {
			if showCopiedBanner {
				FullScreenCopiedBanner(text: copiedBarcode, playerName: copiedPlayerName)
					.transition(.scale.combined(with: .opacity))
					.animation(.spring(response: 0.3), value: showCopiedBanner)
			}
		}
		.overlay(alignment: .top) {
			if showToast {
				ToastView(message: toastMessage, type: toastType, action: toastAction)
					.padding(.top, 20)
					.transition(.move(edge: .top).combined(with: .opacity))
					.animation(.spring(response: 0.3), value: showToast)
			}
		}
		.onAppear {
			// Set the appState reference for immediate syncing
			csvManager.appState = appState
			if let csvFile = appState.detectedCSVFile {
				csvManager.loadCSV(from: csvFile)
			}
			// Load recents
			appState.loadRecentFiles()
			// Check Capture One status
			checkCaptureOneStatus()
			// Sync with shared groups from Manual mode
			csvManager.syncWithSharedGroups(appState.sharedGroups)
			// Refresh groups from current players to catch any new groups
			csvManager.refreshGroupsFromPlayers()
			// Autofocus search on enter CSV mode
			isSearchFocused = true
		}
		.onChange(of: appState.photographerID) { _, newPhotographerID in
			// Reload CSV when photographer ID changes to use appropriate copy
			if let csvFile = appState.detectedCSVFile {
				print("Photographer ID changed to: \(newPhotographerID)")
				print("Current detected CSV: \(csvFile.lastPathComponent)")
				
				// Check if the currently detected CSV is already the right photographer copy
				if appState.isPhotographerCSV(csvFile) {
					print("Already using correct photographer copy, no reload needed")
				} else {
					print("Reloading to use appropriate CSV copy")
					DispatchQueue.main.async {
						csvManager.loadCSV(from: csvFile)
					}
				}
			}
		}
		.onDisappear {
			Logger.log("📤 CSVModeView.onDisappear: scheduling save")
			csvManager.saveCSV()
		}
		.onChange(of: csvManager.uniqueGroups) { _, newGroups in
			selectedGroups = Dictionary(uniqueKeysWithValues: newGroups.map { ($0, true) })
            // Sync CSV groups back to shared state
            appState.syncGroupsFromCSV(newGroups)
        }
        // No need to select barcode column; first matching header is used automatically
        .onExitCommand {
            if !searchText.isEmpty { searchText = "" }
        }
        .onAppear {
            // Store initial job folder URL
            lastJobFolderURL = appState.jobFolderURL
            // CSVModeView appeared
        }
        .onChange(of: appState.jobFolderURL) { oldValue, newValue in
            // Clear CSV data when job folder changes
            if oldValue != newValue && oldValue != nil {
                // Job folder changed, clearing CSV data
                csvManager.clearLoadedData()
                selectedPlayerID = nil
                searchText = ""
                selectedGroups = [:]
                showOnlyUnphotographed = false
                showMyWorkOnly = false
                // CSV data cleared
                
                // Force reload after a short delay to ensure AppState has scanned the new folder
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if let detectedFile = appState.detectedCSVFile {
                        csvManager.loadCSV(from: detectedFile)
                    }
                }
            }
            lastJobFolderURL = newValue
        }
        .onChange(of: appState.detectedCSVFile) { oldValue, newValue in
            // Auto-load the detected CSV when it changes (e.g., after folder scan)
            if let detectedFile = newValue, detectedFile != oldValue {
                // Check if this is actually a different file (different path, not just different name)
                let isDifferentFile = oldValue?.path != newValue?.path
                let currentlyLoadedFile = csvManager.publicCurrentFileURL
                let isLoadingDifferentFile = currentlyLoadedFile?.path != detectedFile.path
                
                // Load if it's a different file OR if no CSV is loaded
                let shouldLoad = csvManager.players.isEmpty || csvManager.currentFileName == "Names List" || isLoadingDifferentFile
                
                if shouldLoad {
                    csvManager.loadCSV(from: detectedFile)
                }
            }
        }
    }
}

// MARK: - CSV File Header View
struct CSVFileHeaderView: View {
	@ObservedObject var csvManager: CSVManager
	@EnvironmentObject var appState: AppStateManager
	let geometry: GeometryProxy

	private var isNarrowLayout: Bool {
		geometry.size.width < 600
	}

	var body: some View {
					ModernCard {
						HStack(spacing: isNarrowLayout ? DesignSystem.microSpacing : DesignSystem.narrowSpacing) {
							Image(systemName: "doc.text")
								.foregroundColor(.accentColor)
								.font(isNarrowLayout ? .caption2 : .caption)
							
							if appState.availableCSVFiles.count > 1 {
								// Show picker when multiple CSV files are available
								VStack(alignment: .leading, spacing: 2) {
									if !isNarrowLayout {
										Text("Select CSV File:")
											.font(.system(size: DesignSystem.FontSizes.caption))
											.foregroundColor(.secondary)
									}
									Picker("Select CSV File", selection: Binding(
										get: { appState.detectedCSVFile },
										set: { newFile in
											if let newFile = newFile {
												appState.selectCSVFile(newFile)
												// Let loadCSV handle the working file logic
												csvManager.loadCSV(from: newFile)
											}
										}
									)) {
										ForEach(appState.availableCSVFiles, id: \.self) { csvFile in
											HStack {
												Text(csvFile.lastPathComponent)
													.font(.system(size: DesignSystem.FontSizes.caption))
												if appState.isPhotographerCSV(csvFile) {
													Text("📸")
														.font(.system(size: DesignSystem.FontSizes.caption2))
												}
											}
											.tag(csvFile as URL?)
										}
									}
									.labelsHidden()
									.frame(maxWidth: .infinity, alignment: .leading)
								}
							} else {
								// Show just the filename when only one CSV file
								VStack(alignment: .leading, spacing: 1) {
									Text(csvManager.currentFileName)
										.font(.system(size: isNarrowLayout ? DesignSystem.FontSizes.caption : DesignSystem.FontSizes.callout))
										.lineLimit(1)
										.truncationMode(.middle)
									
									// Show photographer indicator if using a photographer copy
									if let currentURL = appState.detectedCSVFile,
									   appState.isPhotographerCSV(currentURL) {
										Text("📸 \(appState.photographerID)'s Copy")
											.font(.system(size: DesignSystem.FontSizes.caption2))
											.foregroundColor(.accentColor)
									}
								}
							}
							
							Spacer()
							
							// Roster mode toggle
							if !csvManager.csvHeaders.isEmpty {
								Button(action: {
									csvManager.isRosterMode.toggle()
									if csvManager.isRosterMode {
										// Auto-detect columns when enabling roster mode
										csvManager.columnMappings = csvManager.autoDetectRosterColumns(csvManager.csvHeaders)
										if !csvManager.columnMappings.isValid {
											csvManager.showingColumnMapping = true
										}
									}
								}) {
									HStack(spacing: 4) {
										Image(systemName: csvManager.isRosterMode ? "list.clipboard.fill" : "list.clipboard")
											.font(.system(size: DesignSystem.FontSizes.caption2))
										if !isNarrowLayout {
											Text("Roster")
												.font(.system(size: DesignSystem.FontSizes.caption2))
										}
									}
									.foregroundColor(csvManager.isRosterMode ? .accentColor : .secondary)
								}
								.buttonStyle(.plain)
								.help(csvManager.isRosterMode ? "Disable roster mode" : "Enable roster mode for name-only CSVs")
							
							// Column mapping button (only when roster mode is enabled)
							if csvManager.isRosterMode {
								Button(action: {
									csvManager.showingColumnMapping = true
								}) {
									Image(systemName: "slider.horizontal.3")
										.font(.system(size: DesignSystem.FontSizes.caption2))
										.foregroundColor(.accentColor)
								}
								.buttonStyle(.plain)
								.help("Configure column mapping")
							}
							}
							
							// Refresh button to scan for new CSV files
							Button {
								appState.refreshCSVFiles()
								// Reload the current CSV if it's still available, or load the new default
								if let currentCSV = appState.detectedCSVFile {
									csvManager.loadCSV(from: currentCSV)
								}
							} label: {
								Image(systemName: "arrow.clockwise")
									.font(.system(size: DesignSystem.FontSizes.caption2))
									.foregroundColor(.secondary)
							}
							.buttonStyle(.plain)
							.help("Refresh CSV file list")
							
							// Show count of available CSV files when multiple exist (compact for narrow)
							if appState.availableCSVFiles.count > 1 {
								Text(isNarrowLayout ? "\(appState.availableCSVFiles.count)" : "\(appState.availableCSVFiles.count) CSV files")
									.font(.system(size: DesignSystem.FontSizes.caption2))
									.foregroundColor(.secondary)
							}
						}
		}
	}
}

// MARK: - CSV Search and Toolbar View
struct CSVSearchAndToolbarView: View {
	@ObservedObject var csvManager: CSVManager
	@EnvironmentObject var appState: AppStateManager
	@Binding var searchText: String
	@Binding var showOnlyUnphotographed: Bool
	@Binding var isBuddyMode: Bool
	@Binding var isEditCopyrightMode: Bool
	@Binding var editingPlayer: Player?
	@Binding var showingMergeCSVs: Bool
	@Binding var selectedGroups: [String: Bool]
	@Binding var showingGroupFilter: Bool
	@FocusState var isSearchFocused: Bool
	let geometry: GeometryProxy
	let viewWidth: CGFloat
	let horizontalSizeClass: UserInterfaceSizeClass?
	@Binding var buddySelectedPlayerIDs: Set<UUID>
	let executeBuddyCopy: () -> Void
	let handlePlayerTap: (Player) -> Void

	// Helper functions that need to be passed in or computed
	var placeholderPlayersSorted: [Player] {
		csvManager.players.filter { $0.firstName == "Add" }.sorted {
			let aNum = extractTrailingNumber(from: $0.fullName)
			let bNum = extractTrailingNumber(from: $1.fullName)
			if aNum != bNum { return aNum < bNum }
			return $0.fullName < $1.fullName
		}
	}

	func extractTrailingNumber(from name: String) -> Int {
		let components = name.split(separator: " ")
		if let last = components.last, let number = Int(last) {
			return number
		}
		return Int.max
	}


	private var isNarrowLayout: Bool {
		geometry.size.width < 600
	}

	var body: some View {
		Group {
				// Search bar
				ModernCard {
					HStack(spacing: isNarrowLayout ? DesignSystem.microSpacing : DesignSystem.narrowSpacing) {
						Image(systemName: "magnifyingglass")
							.foregroundColor(.secondary)
							.font(.system(size: isNarrowLayout ? DesignSystem.IconSizes.narrowMedium : DesignSystem.IconSizes.medium))
						TextField(isNarrowLayout ? "Search..." : "Search players...", text: $searchText)
							.focused($isSearchFocused)
							.textFieldStyle(.plain)
							.font(.system(size: isNarrowLayout ? DesignSystem.FontSizes.callout : DesignSystem.FontSizes.body))
						if !searchText.isEmpty {
							Button {
								searchText = ""
							} label: {
								Image(systemName: "xmark.circle.fill")
									.foregroundColor(.secondary)
									.font(.system(size: isNarrowLayout ? DesignSystem.IconSizes.narrowSmall : DesignSystem.IconSizes.small))
							}
							.buttonStyle(.plain)
							.help("Esc to clear")
						}
						
						// Roster mode indicator
						if csvManager.isRosterMode {
							HStack(spacing: 4) {
								Image(systemName: "list.clipboard.fill")
									.font(.system(size: isNarrowLayout ? DesignSystem.IconSizes.narrowSmall : DesignSystem.IconSizes.small))
								if !isNarrowLayout {
									Text("Roster")
										.font(.system(size: DesignSystem.FontSizes.caption2))
										.fontWeight(.medium)
								}
							}
							.foregroundColor(.accentColor)
							.padding(.horizontal, 8)
							.padding(.vertical, 4)
							.background(Color.accentColor.opacity(0.1))
							.clipShape(RoundedRectangle(cornerRadius: 6))
						}
					}
					.padding(DesignSystem.adaptivePadding(for: viewWidth))
				}
				.padding(.horizontal, DesignSystem.adaptivePadding(for: viewWidth))
				.padding(.top, isNarrowLayout ? DesignSystem.microSpacing : (horizontalSizeClass == .compact ? 8 : 12))

			// Hidden command to focus search with Cmd+F
			Button("Focus Search Hidden") { isSearchFocused = true }
				.keyboardShortcut("f", modifiers: [.command])
				.frame(width: 0, height: 0)
				.opacity(0.001)

			// Toolbar - Full implementation
				if isNarrowLayout {
					// Single horizontal row toolbar for narrow layout - centered
					HStack {
						Spacer()
						
						HStack(spacing: DesignSystem.microSpacing) {
							Toggle(isOn: $showOnlyUnphotographed) {
								Image(systemName: "checkmark.circle")
							}
							.toggleStyle(.button)
							.tint(showOnlyUnphotographed ? .accentColor : .gray)
							.controlSize(.regular)

							Toggle(isOn: $isBuddyMode) {
								Image(systemName: isBuddyMode ? "person.2.fill" : "person.2")
							}
							.toggleStyle(.button)
							.tint(isBuddyMode ? .orange : .gray)
							.controlSize(.regular)
							.onChange(of: isBuddyMode) { oldValue, newValue in
								if oldValue && !newValue && !buddySelectedPlayerIDs.isEmpty {
									// Buddy mode turned OFF - execute batch copy/send
									executeBuddyCopy()
								} else if !newValue {
									// Clear selection when turning OFF without selection
									buddySelectedPlayerIDs.removeAll()
								}
							}

							Toggle(isOn: $isEditCopyrightMode) {
								Image(systemName: isEditCopyrightMode ? "c.circle.fill" : "c.circle")
							}
							.toggleStyle(.button)
							.tint(isEditCopyrightMode ? .blue : .gray)
							.controlSize(.regular)

						// Add new player button
							Button {
				// Prefer an existing placeholder that already has a barcode
				if let withBarcode = placeholderPlayersSorted.first(where: { !($0.barcode.trim().isEmpty) }) {
					editingPlayer = withBarcode
				} else if let anyPlaceholder = placeholderPlayersSorted.first {
					editingPlayer = anyPlaceholder
				} else {
					// No placeholders remain; create one with a unique 15-digit numeric barcode
					let existing = Set(csvManager.players.map { $0.barcode })
					let code = BarcodeGenerator.generateUnique15Digit(existing: existing)
					let newPlaceholder = csvManager.createManualPlaceholder(barcode: code)
					editingPlayer = newPlaceholder
				}
							} label: {
								Image(systemName: "person.badge.plus")
							}
							.buttonStyle(.bordered)
							.tint(.orange)
							.controlSize(.regular)
							.disabled(csvManager.players.isEmpty)

						// Merge CSVs button
							Button {
								showingMergeCSVs = true
							} label: {
								Image(systemName: "arrow.triangle.merge")
							}
							.buttonStyle(.bordered)
							.controlSize(.regular)
							.help("Merge work from multiple photographers")
						}
						
						Spacer()
					}
					.padding(.horizontal, DesignSystem.adaptivePadding(for: viewWidth))
					.padding(.vertical, DesignSystem.microSpacing)
				} else {
					// Horizontal toolbar for wider layouts - centered
					HStack {
						Spacer()
						
						HStack(spacing: 8) {
								Toggle(isOn: $showOnlyUnphotographed) {
									Image(systemName: "checkmark.circle")
								}
								.toggleStyle(.button)
								.tint(showOnlyUnphotographed ? .accentColor : .gray)
								.controlSize(.regular)

								Toggle(isOn: $isBuddyMode) {
									Image(systemName: isBuddyMode ? "person.2.fill" : "person.2")
								}
								.toggleStyle(.button)
								.tint(isBuddyMode ? .orange : .gray)
								.controlSize(.regular)
								.onChange(of: isBuddyMode) { oldValue, newValue in
									if oldValue && !newValue && !buddySelectedPlayerIDs.isEmpty {
										// Buddy mode turned OFF - execute batch copy/send
										executeBuddyCopy()
									} else if !newValue {
										// Clear selection when turning OFF without selection
										buddySelectedPlayerIDs.removeAll()
									}
								}

								Toggle(isOn: $isEditCopyrightMode) {
									Image(systemName: isEditCopyrightMode ? "c.circle.fill" : "c.circle")
								}
								.toggleStyle(.button)
								.tint(isEditCopyrightMode ? .blue : .gray)
								.controlSize(.regular)

							// Add new player button
								Button {
									if !placeholderPlayersSorted.isEmpty {
										// Always start with the lowest numbered "Add Subject"
										editingPlayer = placeholderPlayersSorted[0]
									}
								} label: {
									Image(systemName: "person.badge.plus")
								}
								.buttonStyle(.bordered)
								.tint(.orange)
								.controlSize(.regular)
								.disabled(csvManager.players.isEmpty)

								// Merge CSVs button (icon only)
								Button {
									showingMergeCSVs = true
								} label: {
									Image(systemName: "arrow.triangle.merge")
										.font(horizontalSizeClass == .compact ? .caption : .callout)
								}
								.buttonStyle(.bordered)
								.controlSize(.regular)
								.help("Merge work from multiple photographers")

								// Create photographer copy button (only show if working with original CSV)
								if let currentCSV = appState.detectedCSVFile,
								   !appState.isAnyPhotographerCSV(currentCSV) {
									Button {
										if let photographerCSV = appState.createPhotographerCSVCopy(from: currentCSV) {
											csvManager.loadCSV(from: photographerCSV)
											appState.selectCSVFile(photographerCSV)
										}
									} label: {
										Label("Create My Copy", systemImage: "doc.badge.plus")
											.font(horizontalSizeClass == .compact ? .caption : .callout)
									}
									.buttonStyle(.bordered)
									.controlSize(.regular)
									.help("Create a photographer-specific copy for offline work")
								}
						}
						
						Spacer()
					}
					.padding(.horizontal, horizontalSizeClass == .compact ? 12 : 20)
					.padding(.vertical, 8)
			}
		}
	}
}

// MARK: - CSV Groups Filter Bar View
struct CSVGroupsFilterBarView: View {
	@ObservedObject var csvManager: CSVManager
	@Binding var selectedGroups: [String: Bool]
	@Binding var showingGroupFilter: Bool
	let geometry: GeometryProxy
	let viewWidth: CGFloat
	let horizontalSizeClass: UserInterfaceSizeClass?
	
	var body: some View {
		HStack {
			// Groups label
			Text("Groups:")
				.font(.system(size: DesignSystem.FontSizes.callout, weight: .medium))
				.foregroundColor(.secondary)
			
			// Group filter functionality
			if horizontalSizeClass == .regular {
				GroupFilterChips(
					selectedGroups: $selectedGroups,
					groups: csvManager.uniqueGroups,
					csvManager: csvManager
				)
			} else {
				Button {
					showingGroupFilter = true
				} label: {
					Label("Filter Groups", systemImage: "line.3.horizontal.decrease.circle")
						.font(.system(size: DesignSystem.FontSizes.callout))
				}
				.buttonStyle(.bordered)
				.controlSize(.regular)
				.popover(isPresented: $showingGroupFilter) {
					GroupFilterView(
						selectedGroups: $selectedGroups,
						groups: csvManager.uniqueGroups,
						csvManager: csvManager
					)
				}
			}
			
			Spacer()
		}
		.padding(.horizontal, DesignSystem.adaptivePadding(for: viewWidth))
		.padding(.vertical, DesignSystem.microSpacing)
		.background(Color(NSColor.controlBackgroundColor).opacity(0.3))
	}
}

// MARK: - CSV Players List View
struct CSVPlayersListView: View {
	@ObservedObject var csvManager: CSVManager
	let filteredPlayers: [Player]
	@Binding var selectedPlayerID: UUID?
	let buddySelectedPlayerIDs: Set<UUID>
	let isBuddyMode: Bool
	@Binding var editingPlayer: Player?
	let handlePlayerTap: (Player) -> Void

	var body: some View {
		ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(spacing: 4) {
					ForEach(filteredPlayers) { player in
						// Use roster display name when in roster mode
						DensePlayerRow(
                            player: player,
							displayName: csvManager.isRosterMode ? csvManager.columnMappings.getDisplayName(from: player) : player.fullName,
                            isSelected: selectedPlayerID == player.id,
                            isBuddySelected: (isBuddyMode && buddySelectedPlayerIDs.contains(player.id)),
                            hasChanges: !player.originalData.isEmpty,
							onToggleDone: {
								if player.isPhotographed { csvManager.markAsNotPhotographed(id: player.id) }
								else { csvManager.markAsPhotographed(id: player.id) }
								// Note: isSearchFocused would need to be passed in if needed
							},
							onEdit: {
								editingPlayer = player
							},
							onTap: {
								handlePlayerTap(player)
							}
						)
						.id(player.id)
					}
				}
				.padding(.horizontal, DesignSystem.adaptivePadding(for: 400)) // Approximate width
				.padding(.vertical, 8)
				.padding(.bottom, 100) // Extra space for keyboard/fab
			}
			.onChange(of: selectedPlayerID) { oldValue, newValue in
				if let newPlayerID = newValue {
					// Scroll to the selected player with animation
					withAnimation(.easeInOut(duration: 0.5)) {
						proxy.scrollTo(newPlayerID, anchor: .center)
					}
				}
			}
		}
	}
}

// MARK: - CSV Stats Bar View
struct CSVStatsBarView: View {
	@ObservedObject var csvManager: CSVManager
	let geometry: GeometryProxy
	let viewWidth: CGFloat
	let filteredPlayers: [Player]
	let realPlayers: [Player]
	let notPhotographedCount: Int
	let buddySelectedPlayerIDs: [UUID]
	let isBuddyMode: Bool
	let isEditCopyrightMode: Bool

	private var isNarrowLayout: Bool {
		geometry.size.width < 600
	}

	var body: some View {
				ModernCard {
					let doneCount = csvManager.players.filter(\.isPhotographed).count
					let totalCount = max(realPlayers.count, 1)
					let percent = Int((Double(doneCount) / Double(totalCount)) * 100)
					
					if isNarrowLayout {
						// Compact vertical stats for narrow layout
						VStack(spacing: DesignSystem.microSpacing) {
							HStack {
								HStack(spacing: DesignSystem.microSpacing) {
									Image(systemName: "list.bullet")
										.font(.system(size: DesignSystem.IconSizes.narrowSmall))
										.foregroundColor(.accentColor)
									Text("\(filteredPlayers.count)")
										.font(.system(size: DesignSystem.FontSizes.caption).weight(.semibold))
								}
								
								Spacer()
								
								if isBuddyMode {
									HStack(spacing: DesignSystem.microSpacing) {
										Image(systemName: "checkmark.circle")
											.font(.system(size: DesignSystem.IconSizes.narrowSmall))
											.foregroundColor(.orange)
										Text("\(buddySelectedPlayerIDs.count)")
											.font(.system(size: DesignSystem.FontSizes.caption).weight(.semibold))
									}
								} else {
									HStack(spacing: DesignSystem.microSpacing) {
										Image(systemName: "circle")
											.font(.system(size: DesignSystem.IconSizes.narrowSmall))
											.foregroundColor(.secondary)
										Text("\(notPhotographedCount)")
											.font(.system(size: DesignSystem.FontSizes.caption).weight(.semibold))
									}
								}
								
								Spacer()
								
								HStack(spacing: DesignSystem.microSpacing) {
									Image(systemName: "checkmark.circle.fill")
										.font(.system(size: DesignSystem.IconSizes.narrowSmall))
										.foregroundColor(.green)
									Text("\(doneCount)")
										.font(.system(size: DesignSystem.FontSizes.caption).weight(.semibold))
								}
								
								Spacer()
								
								if isBuddyMode {
									Text("Buddy")
										.font(.system(size: DesignSystem.FontSizes.caption2))
										.foregroundColor(.orange)
										.fontWeight(.semibold)
								} else if isEditCopyrightMode {
									Text("Copyright")
										.font(.system(size: DesignSystem.FontSizes.caption2))
										.foregroundColor(.blue)
										.fontWeight(.semibold)
								} else {
									Text("\(percent)%")
										.font(.system(size: DesignSystem.FontSizes.caption2))
										.foregroundColor(.secondary)
										.fontWeight(.semibold)
								}
							}
							
							let total = max(realPlayers.count, 1)
							let done = realPlayers.filter(\.isPhotographed).count
							ProgressView(value: Double(done), total: Double(total))
								.tint(.accentColor)
								.controlSize(.mini)
								.animation(.easeInOut(duration: 0.25), value: done)
						}
						.padding(.vertical, DesignSystem.microPadding)
					} else {
				// Full stats for wider layouts - simplified placeholder
				Text("Stats bar for wide layout - needs full implementation")
						.font(.caption)
					.foregroundColor(.red)
			}
			}
			.padding(.horizontal, DesignSystem.adaptivePadding(for: viewWidth))
    }
}

// MARK: - Player Card
struct PlayerCard: View {
	let player: Player
	let isSelected: Bool
	let isBuddySelected: Bool
	let isBuddyMode: Bool
	let onTap: () -> Void
	let onEdit: () -> Void
	let onToggleDone: () -> Void
	@Environment(\.horizontalSizeClass) var horizontalSizeClass
	@State private var cardWidth: CGFloat = 0
	
	private var isNarrowLayout: Bool {
		DesignSystem.isNarrowLayout(width: cardWidth)
	}

	var body: some View {
		ModernCard {
			HStack(spacing: isNarrowLayout ? DesignSystem.microSpacing : (horizontalSizeClass == .compact ? 8 : 12)) {
				// Leading toggle button to mark done/undone
				if !isBuddyMode {
					Button(action: onToggleDone) {
						Image(systemName: player.isPhotographed ? "checkmark.circle.fill" : "circle")
							.foregroundColor(player.isPhotographed ? .green : .secondary)
							.font(.system(size: isNarrowLayout ? DesignSystem.IconSizes.narrowLarge : DesignSystem.IconSizes.large))
					}
					.buttonStyle(.plain)
					.keyboardShortcut(.space, modifiers: [])
				} else {
					// In buddy mode, show selection indicator
					Image(systemName: isBuddySelected ? "checkmark.circle.fill" : "circle")
						.foregroundColor(isBuddySelected ? .orange : .secondary)
						.font(.system(size: isNarrowLayout ? DesignSystem.IconSizes.narrowLarge : DesignSystem.IconSizes.large))
				}

				// Player info
				VStack(alignment: .leading, spacing: isNarrowLayout ? 2 : 4) {
					// Show original data info if any fields have been changed
					if !player.originalData.isEmpty {
						Text("Changed From Original Data:")
							.font(.system(size: DesignSystem.FontSizes.caption2))
							.foregroundColor(.secondary)
							.opacity(0.8)
					}
					
					VStack(alignment: .leading, spacing: 1) {
						Text(player.fullName)
							.font(.system(size: isNarrowLayout ? DesignSystem.FontSizes.body : 
								(horizontalSizeClass == .compact ? DesignSystem.FontSizes.callout : DesignSystem.FontSizes.body)))
							.fontWeight(.semibold)
							.foregroundColor(player.isPhotographed ? .secondary : .primary)
							.opacity(player.isPhotographed ? 0.8 : 1)
							.strikethrough(player.isPhotographed)
							.lineLimit(isNarrowLayout ? 1 : 2)
						
						// Show original name if it was changed
						let originalFirstName = player.getOriginalValue(for: "Student firstname")
						let originalLastName = player.getOriginalValue(for: "Student lastname")
						
						if let origFirst = originalFirstName, let origLast = originalLastName {
							Text("was: \(origFirst) \(origLast)")
								.font(.system(size: DesignSystem.FontSizes.caption2))
								.foregroundColor(.secondary)
								.opacity(0.7)
								.lineLimit(1)
						} else if let origFirst = originalFirstName {
							Text("was: \(origFirst) \(player.lastName)")
								.font(.system(size: DesignSystem.FontSizes.caption2))
								.foregroundColor(.secondary)
								.opacity(0.7)
								.lineLimit(1)
						} else if let origLast = originalLastName {
							Text("was: \(player.firstName) \(origLast)")
								.font(.system(size: DesignSystem.FontSizes.caption2))
								.foregroundColor(.secondary)
								.opacity(0.7)
								.lineLimit(1)
						}
					}

					if isNarrowLayout {
						// Compact info for narrow layout
						VStack(alignment: .leading, spacing: 1) {
							HStack(spacing: DesignSystem.microSpacing) {
								if !player.group.isEmpty && player.group != "No Group" {
									Text(player.group)
										.font(.system(size: DesignSystem.FontSizes.caption2))
										.foregroundColor(.secondary)
										.lineLimit(1)
										.truncationMode(.tail)
								}
							
								if player.hasPhoto {
									Image(systemName: "photo.fill")
										.font(.system(size: DesignSystem.IconSizes.narrowSmall))
										.foregroundColor(.blue)
								}
								
								if isBuddyMode && isBuddySelected {
									Text("✓")
										.font(.system(size: DesignSystem.FontSizes.caption2))
										.fontWeight(.bold)
										.foregroundColor(.orange)
								}
							}
						
						// Barcode under group for narrow layout
						if !player.barcode.isEmpty {
							HStack(spacing: DesignSystem.microSpacing) {
								Image(systemName: "barcode.viewfinder")
									.font(.system(size: DesignSystem.IconSizes.narrowSmall))
									.foregroundColor(.secondary)
								Text(player.barcode)
									.font(.system(size: DesignSystem.FontSizes.caption))
									.foregroundColor(.secondary)
									.lineLimit(1)
									.truncationMode(.middle)
							}
						}
							
							// Show original group if it was changed
							if let originalGroup = player.getOriginalValue(for: "Group"),
							   originalGroup != "No Group" && !originalGroup.isEmpty {
								Text("was: \(originalGroup)")
									.font(.system(size: DesignSystem.FontSizes.caption2))
									.foregroundColor(.secondary)
									.opacity(0.7)
									.lineLimit(1)
							}
						}
					} else {
						// Full info for wider layouts
						VStack(alignment: .leading, spacing: 2) {
							HStack(spacing: 10) {
							if !player.group.isEmpty && player.group != "No Group" {
								Label(player.group, systemImage: "person.3")
									.font(.system(size: DesignSystem.FontSizes.caption))
									.foregroundColor(.secondary)
							}
								if player.hasPhoto {
									Label("Has Photo", systemImage: "photo")
										.font(.system(size: DesignSystem.FontSizes.caption))
										.foregroundColor(.blue)
								}
								if isBuddyMode && isBuddySelected {
									Text("Selected")
										.font(.system(size: DesignSystem.FontSizes.caption2))
										.fontWeight(.semibold)
										.foregroundColor(.orange)
								}
							}
						.labelStyle(TitleOnlyLabelStyle())
						
						// Barcode under group for wide layout
						if !player.barcode.isEmpty {
							HStack(spacing: 6) {
								Image(systemName: "barcode.viewfinder")
									.font(.system(size: DesignSystem.IconSizes.small))
									.foregroundColor(.secondary)
								Text(player.barcode)
									.font(.system(size: DesignSystem.FontSizes.callout))
									.foregroundColor(.secondary)
									.lineLimit(1)
									.truncationMode(.middle)
							}
						}
						
						// Show original group if it was changed (full layout)
							if let originalGroup = player.getOriginalValue(for: "Group"),
							   originalGroup != "No Group" && !originalGroup.isEmpty {
								Text("was: \(originalGroup)")
									.font(.system(size: DesignSystem.FontSizes.caption2))
									.foregroundColor(.secondary)
									.opacity(0.7)
							}
						}
					}
				}

				Spacer()
				
				// Edit button - more compact for narrow layout
				if !isBuddyMode {
					Button(action: onEdit) {
						if isNarrowLayout {
							Image(systemName: "pencil")
								.font(.system(size: DesignSystem.IconSizes.narrowSmall))
								.foregroundColor(.secondary)
						} else {
							Text("Edit")
								.font(.system(size: DesignSystem.FontSizes.caption))
						}
					}
					.buttonStyle(.bordered)
					.controlSize(isNarrowLayout ? .mini : .small)
				}
			}
			.padding(DesignSystem.adaptivePadding(for: cardWidth))
			.frame(maxWidth: .infinity)
			.contentShape(Rectangle()) // Makes entire area clickable
			.onTapGesture(perform: onTap)
			.background(isSelected ? Color.accentColor.opacity(0.10) :
					   isBuddySelected ? Color.orange.opacity(0.10) : Color.clear)
			.clipShape(RoundedRectangle(
				cornerRadius: isNarrowLayout ? DesignSystem.compactCornerRadius : DesignSystem.cornerRadius, 
				style: .continuous
			))
			.overlay(
				RoundedRectangle(
					cornerRadius: isNarrowLayout ? DesignSystem.compactCornerRadius : DesignSystem.cornerRadius, 
					style: .continuous
				)
				.strokeBorder(isSelected ? Color.accentColor.opacity(0.35) :
							 isBuddySelected ? Color.orange.opacity(0.35) : .clear, lineWidth: 1)
			)
			.opacity(player.isPhotographed ? 0.8 : 1)
		}
		.background(
			GeometryReader { geometry in
				Color.clear
					.onAppear { cardWidth = geometry.size.width }
					.onChange(of: geometry.size.width) { _, newWidth in
						cardWidth = newWidth
					}
			}
		)
	}
}

// MARK: - Group Filter View
struct GroupFilterView: View {
	@Binding var selectedGroups: [String: Bool]
	let groups: [String]
	let csvManager: CSVManager
	@Environment(\.dismiss) private var dismiss
	@State private var newGroupName = ""
	@State private var showingNewGroupField = false

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Filter by Group")
				.font(.headline)

			VStack(alignment: .leading, spacing: 8) {
				ForEach(groups, id: \.self) { group in
					Toggle(isOn: Binding(
						get: { selectedGroups[group] ?? true },
						set: { selectedGroups[group] = $0 }
					)) {
						Text(group)
					}
					.toggleStyle(.checkbox)
				}
				
				// Add new group section
				if showingNewGroupField {
					HStack(spacing: 6) {
						TextField("New group name", text: $newGroupName)
							.textFieldStyle(.roundedBorder)
							.onSubmit {
								addNewGroup()
							}
						Button("Add") {
							addNewGroup()
						}
						.buttonStyle(.bordered)
						.controlSize(.small)
						Button("Cancel") {
							showingNewGroupField = false
							newGroupName = ""
						}
						.buttonStyle(.bordered)
						.controlSize(.small)
					}
				} else {
					Button("+ Add New Group") {
						showingNewGroupField = true
					}
					.buttonStyle(.borderless)
					.foregroundColor(.accentColor)
				}
			}

			Divider()

			HStack(spacing: 8) {
				Button("Select All") {
					for group in groups {
						selectedGroups[group] = true
					}
				}
				.buttonStyle(.bordered)

				Button("Select None") {
					for group in groups {
						selectedGroups[group] = false
					}
				}
				.buttonStyle(.bordered)

				Spacer()

				Button("Done") {
					dismiss()
				}
				.buttonStyle(.borderedProminent)
			}
		}
		.padding()
		.frame(width: 300)
	}
	
	private func addNewGroup() {
		let trimmedName = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedName.isEmpty else { return }
		
		csvManager.addNewGroup(trimmedName)
		selectedGroups[trimmedName] = true
		showingNewGroupField = false
		newGroupName = ""
	}
}

// MARK: - Group Filter Chips
struct GroupFilterChips: View {
	@Binding var selectedGroups: [String: Bool]
	let groups: [String]
	let csvManager: CSVManager

	var body: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 6) {
				// "All" chip
				GroupFilterChip(
					title: "All",
					isSelected: selectedGroups.values.allSatisfy { $0 },
					action: {
						let allSelected = selectedGroups.values.allSatisfy { $0 }
						for group in groups {
							selectedGroups[group] = !allSelected
						}
					}
				)

				// Individual group chips
				ForEach(groups, id: \.self) { group in
					GroupFilterChip(
						title: group,
						isSelected: selectedGroups[group] ?? true,
						action: {
							selectedGroups[group] = !(selectedGroups[group] ?? true)
						}
					)
				}

				// Add new group button
				Button(action: {}) {
					Image(systemName: "plus")
						.font(.caption)
						.foregroundColor(.accentColor)
						.frame(width: 28, height: 28)
						.background(Color.accentColor.opacity(0.1))
						.clipShape(Capsule())
				}
				.buttonStyle(.plain)
				.help("Add new group")
			}
			.padding(.horizontal, 4)
		}
		.frame(height: 40)
	}
}

struct GroupFilterChip: View {
	let title: String
	let isSelected: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Text(title)
				.font(.caption)
				.padding(.horizontal, 8)
				.padding(.vertical, 4)
				.background(
					isSelected
						? Color.accentColor
						: Color.secondary.opacity(0.1)
				)
				.foregroundColor(
					isSelected
						? .white
						: .primary
				)
				.clipShape(Capsule())
		}
		.buttonStyle(.plain)
	}
}

// MARK: - Toast View
struct ToastView: View {
	let message: String
	let type: ToastType
	let action: (() -> Void)?

	var body: some View {
		HStack(spacing: 12) {
			// Icon
			Image(systemName: iconName)
				.foregroundColor(iconColor)
				.font(.system(size: 16))

			// Message
			Text(message)
				.font(.body)
				.foregroundColor(.primary)
				.lineLimit(2)

			Spacer()

			// Action button (if provided)
			if let action = action {
				Button("View", action: action)
					.buttonStyle(.bordered)
					.controlSize(.small)
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
		.background(Color(.windowBackgroundColor))
		.clipShape(RoundedRectangle(cornerRadius: 8))
		.shadow(radius: 8)
		.frame(maxWidth: 400)
	}

	private var iconName: String {
		switch type {
		case .success: return "checkmark.circle.fill"
		case .error: return "exclamationmark.triangle.fill"
		case .info: return "info.circle.fill"
		}
	}

	private var iconColor: Color {
		switch type {
		case .success: return .green
		case .error: return .red
		case .info: return .blue
		}
	}
}

// MARK: - Edit Player Sheet
struct EditPlayerSheet: View {
	@Environment(\.dismiss) private var dismiss
	@State var player: Player
	let csvHeaders: [String]
	let availableGroups: [String]
	let placeholderPlayers: [Player]
	let csvManager: CSVManager
	let onSave: (Player) -> Void
	let onNavigateIndexChange: (Int) -> Void
	let onAdvanceToNextFrom: (Int) -> Void

	@State private var firstName = ""
	@State private var lastName = ""
	@State private var selectedGroup = ""
	@State private var barcode = ""
	@State private var accessCode = ""
	@State private var showingMoreFields = false
	@State private var columnValues: [String: String] = [:]
	@State private var hasExistingPhoto = false
	@State private var isPhotographedToggle = false
	@State private var currentIndex = 0
	@State private var newGroupName = ""
	@State private var showingNewGroupField = false

	// Validation state
	@State private var validationError = ""
	@State private var isValid = true
	
	private var isPlaceholderPlayer: Bool {
		player.firstName == "Add" && player.lastName.hasPrefix("Subject")
	}

	private var photoHeader: String? { csvHeaders.first(where: { $0 == "Photo" }) }
	private var referenceHeader: String? { csvHeaders.first(where: { $0 == "Reference" }) }
	
	private var barcodeHeader: String? {
		// Use the same priority-based logic as CSV parsing
		if let index = CSVService.findHeaderIndexWithPriority(in: csvHeaders, prioritizedCandidates: HeaderAliases.barcodeExact) {
			return csvHeaders[index]
		}
		
		// Fallback to contains logic
		if let index = CSVService.findHeaderIndex(in: csvHeaders, containsAny: HeaderAliases.barcodeContains) {
			return csvHeaders[index]
		}
		return nil
	}
	
	private var accessCodeHeader: String? {
		// Look for access code headers in priority order
		let accessCodeCandidates = ["Access Code", "Access Code (1)", "Access Code (2)", "AccessCode", "Access_Code"]
		return csvHeaders.first { header in
			accessCodeCandidates.contains(header)
		}
	}

	var body: some View {
		VStack(spacing: 0) {
			// Compact Header
			headerView
			
			// Main Content
			compactEditView
			
			// Footer with actions
			footerView
		}
		.background(Color(NSColor.windowBackgroundColor))
		.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
		.shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 8)
		.frame(width: 320, height: showingMoreFields ? 800 : 600)
		.onAppear {
			currentIndex = placeholderPlayers.firstIndex(where: { $0.id == player.id }) ?? 0
			loadFields(from: player)
			validateInput()
		}
		.background(
			Group {
				if isPlaceholderPlayer {
					ArrowKeyHandler(isEnabled: true, onLeft: { navigate(delta: -1) }, onRight: { navigate(delta: 1) })
				} else {
					Color.clear
				}
			}
		)
	}
	
	private var headerView: some View {
		VStack(spacing: 0) {
			VStack(spacing: 12) {
				// Title and close button
				HStack(spacing: 8) {
					Image(systemName: "person.crop.rectangle.fill")
						.font(.system(size: 16, weight: .medium))
						.foregroundColor(.accentColor)
					
					Text(isPlaceholderPlayer ? "Add New Player" : "Edit Player")
						.font(.system(size: 18, weight: .bold))
						.foregroundColor(.primary)
					
					Spacer()
					
					Button { dismiss() } label: {
						Image(systemName: "xmark.circle.fill")
							.font(.system(size: 20))
							.foregroundColor(.secondary)
					}
					.buttonStyle(.plain)
					.keyboardShortcut(.escape)
				}
				
				// Player navigation for placeholders - stacked for narrow layout
				if isPlaceholderPlayer {
					HStack(spacing: 8) {
						Button { navigate(delta: -1) } label: {
							Image(systemName: "chevron.left")
								.font(.system(size: 14, weight: .medium))
								.foregroundColor(canGoBackward ? .accentColor : .secondary)
								.frame(width: 32, height: 32)
								.background(canGoBackward ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05))
								.clipShape(Circle())
						}
						.buttonStyle(.plain)
						.disabled(!canGoBackward)
						
						VStack(spacing: 2) {
							Text("\(currentIndex + 1) of \(placeholderPlayers.count)")
								.font(.system(size: 13, weight: .semibold))
								.foregroundColor(.primary)
							Text("Subject")
								.font(.system(size: 11, weight: .medium))
								.foregroundColor(.secondary)
						}
						.frame(maxWidth: .infinity)
						
						Button { navigate(delta: 1) } label: {
							Image(systemName: "chevron.right")
								.font(.system(size: 14, weight: .medium))
								.foregroundColor(canGoForward ? .accentColor : .secondary)
								.frame(width: 32, height: 32)
								.background(canGoForward ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05))
								.clipShape(Circle())
						}
						.buttonStyle(.plain)
						.disabled(!canGoForward)
					}
					.padding(.horizontal, 8)
				}
			}
			.padding(.horizontal, 20)
			.padding(.vertical, 16)
			
			// Validation error banner - more compact for narrow layout
			if !validationError.isEmpty {
				VStack(spacing: 4) {
					HStack(spacing: 6) {
						Image(systemName: "exclamationmark.triangle.fill")
							.font(.system(size: 12))
							.foregroundColor(.orange)
						Text(validationError)
							.font(.system(size: 13, weight: .medium))
							.foregroundColor(.primary)
							.multilineTextAlignment(.leading)
						Spacer(minLength: 0)
					}
				}
				.padding(.horizontal, 20)
				.padding(.vertical, 10)
				.background(Color.orange.opacity(0.1))
			}
			
			Divider()
		}
	}
	
	private var compactEditView: some View {
		ScrollView {
			VStack(spacing: 16) {
				// Essential Fields in a compact grid
				essentialFieldsGrid
				
				// Collapsible Additional Fields
				additionalFieldsSection
			}
			.padding(.horizontal, 20)
			.padding(.vertical, 16)
		}
	}
	
	private var essentialFieldsGrid: some View {
		VStack(spacing: 24) {
			// Section: Player Information
			VStack(alignment: .leading, spacing: 12) {
				SectionHeader(title: "Player Information", icon: "person.fill")
				
				// Name fields stacked vertically for narrow layout
				VStack(spacing: 16) {
					ModernField(
						title: "First Name",
						text: $firstName,
						originalValue: player.getOriginalValue(for: "Student firstname") ?? player.getOriginalValue(for: "First Name") ?? player.getOriginalValue(for: "Firstname"),
						isRequired: true,
						onChange: { validateInput() }
					)
					
					ModernField(
						title: "Last Name", 
						text: $lastName,
						originalValue: player.getOriginalValue(for: "Student lastname") ?? player.getOriginalValue(for: "Last Name") ?? player.getOriginalValue(for: "Lastname"),
						isRequired: true,
						onChange: { validateInput() }
					)
				}
			}
			
			// Section: Group Assignment
			VStack(alignment: .leading, spacing: 12) {
				SectionHeader(title: "Group Assignment", icon: "person.3.fill")
				
				NarrowGroupSelectionField(
					selectedGroup: $selectedGroup,
					availableGroups: csvManager.uniqueGroups.filter { !$0.isEmpty },
					originalGroup: player.getOriginalValue(for: "Group") ?? player.getOriginalValue(for: "Team") ?? player.getOriginalValue(for: "Class"),
					showingNewGroupField: $showingNewGroupField,
					newGroupName: $newGroupName,
					onAddNewGroup: addNewGroup
				)
			}
			
			// Section: Identification
			VStack(alignment: .leading, spacing: 12) {
				SectionHeader(title: "Identification", icon: "barcode")
				
				VStack(spacing: 16) {
					ModernField(
						title: "Barcode",
						text: $barcode,
						originalValue: barcodeHeader != nil ? player.getOriginalValue(for: barcodeHeader!) : nil,
						isRequired: true,
						isBarcode: true,
						onChange: { validateInput() }
					)
					
					// Access Code field (if header exists)
					if accessCodeHeader != nil {
						ModernField(
							title: "Access Code",
							text: $accessCode,
							originalValue: player.getOriginalValue(for: accessCodeHeader!),
							onChange: { validateInput() }
						)
					}
				}
			}
		}
	}
	
	private var additionalFieldsSection: some View {
		VStack(alignment: .leading, spacing: 16) {
			// Advanced Options Toggle
			Button(action: { 
				withAnimation(.easeInOut(duration: 0.3)) {
					showingMoreFields.toggle()
				}
			}) {
				HStack(spacing: 12) {
					Image(systemName: "gearshape.fill")
						.font(.system(size: 14, weight: .medium))
						.foregroundColor(.secondary)
					
					Text("Advanced Options")
						.font(.system(size: 15, weight: .medium))
						.foregroundColor(.primary)
					
					Text("(\(additionalFieldsCount) items)")
						.font(.system(size: 13))
						.foregroundColor(.secondary)
					
					Spacer()
					
					Image(systemName: showingMoreFields ? "chevron.up" : "chevron.down")
						.font(.system(size: 12, weight: .semibold))
						.foregroundColor(.secondary)
				}
				.padding(.vertical, 8)
			}
			.buttonStyle(.plain)
			
			if showingMoreFields {
				VStack(spacing: 20) {
					// Photo Status Section
					VStack(alignment: .leading, spacing: 12) {
						SectionHeader(title: "Photo Status", icon: "camera.fill")
						
						HStack(spacing: 20) {
							Toggle("Has Photo", isOn: $hasExistingPhoto)
								.font(.system(size: 14))
								.toggleStyle(.switch)
							
							Toggle("Photographed", isOn: $isPhotographedToggle)
								.font(.system(size: 14))
								.toggleStyle(.switch)
						}
					}
					
					// Additional CSV Fields (only show important ones) - Single column for narrow layout
					if !importantAdditionalHeaders.isEmpty {
						VStack(alignment: .leading, spacing: 12) {
							SectionHeader(title: "Additional Information", icon: "doc.text.fill")
							
							VStack(spacing: 16) {
								ForEach(importantAdditionalHeaders, id: \.self) { header in
									ModernField(
										title: header,
										text: Binding(
											get: { columnValues[header] ?? "" },
											set: { columnValues[header] = $0 }
										),
										originalValue: player.getOriginalValue(for: header)
									)
								}
							}
						}
					}
					
					// Show remaining fields in a collapsed section if there are many - Single column
					if !lessImportantHeaders.isEmpty {
						DisclosureGroup("Other Fields (\(lessImportantHeaders.count))") {
							VStack(spacing: 16) {
								ForEach(lessImportantHeaders, id: \.self) { header in
									ModernField(
										title: header,
										text: Binding(
											get: { columnValues[header] ?? "" },
											set: { columnValues[header] = $0 }
										),
										originalValue: player.getOriginalValue(for: header)
									)
								}
							}
							.padding(.top, 12)
						}
						.font(.system(size: 14, weight: .medium))
						.foregroundColor(.secondary)
					}
				}
				.padding(20)
				.background(Color(NSColor.controlBackgroundColor).opacity(0.5))
				.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
			}
		}
	}
	
	private var footerView: some View {
		VStack(spacing: 0) {
			Divider()
			
			VStack(spacing: 12) {
				// Save button - full width for narrow layout
				Button { saveChanges() } label: {
					HStack(spacing: 8) {
						if isValid {
							Image(systemName: "checkmark")
								.font(.system(size: 14, weight: .medium))
						} else {
							Image(systemName: "exclamationmark.triangle")
								.font(.system(size: 14, weight: .medium))
						}
						Text(isPlaceholderPlayer ? "Add Player" : "Save Changes")
							.font(.system(size: 15, weight: .semibold))
					}
					.frame(maxWidth: .infinity)
				}
				.buttonStyle(.borderedProminent)
				.controlSize(.regular)
				.keyboardShortcut(.return)
				.disabled(!isValid)
				
				// Cancel button - secondary
				Button { dismiss() } label: {
					HStack(spacing: 6) {
						Image(systemName: "xmark")
							.font(.system(size: 13, weight: .medium))
						Text("Cancel")
							.font(.system(size: 14, weight: .medium))
					}
					.frame(maxWidth: .infinity)
				}
				.buttonStyle(.bordered)
				.controlSize(.regular)
				.keyboardShortcut(.escape)
			}
			.padding(.horizontal, 20)
			.padding(.vertical, 16)
		}
		.background(Color(NSColor.windowBackgroundColor))
	}
	
	private var additionalHeaders: [String] {
		let excludeHeaders = ["Student firstname", "Student lastname", "Group", "Reference", "Photo"] + (barcodeHeader != nil ? [barcodeHeader!] : []) + (accessCodeHeader != nil ? [accessCodeHeader!] : [])
		return csvHeaders.filter { !excludeHeaders.contains($0) }
	}
	
	private var importantAdditionalHeaders: [String] {
		// Show commonly used/important fields first
		let importantKeywords = ["parent", "email", "phone", "address", "grade", "teacher", "class", "age", "birth"]
		return additionalHeaders.filter { header in
			importantKeywords.contains { keyword in
				header.lowercased().contains(keyword)
			}
		}
	}
	
	private var lessImportantHeaders: [String] {
		return additionalHeaders.filter { !importantAdditionalHeaders.contains($0) }
	}
	
	private var additionalFieldsCount: Int {
		additionalHeaders.count + 2 // +2 for Photo Status toggles
	}
	
	private func addNewGroup() {
		let trimmed = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }
		csvManager.addNewGroup(trimmed)
		selectedGroup = trimmed
		showingNewGroupField = false
		newGroupName = ""
	}



	private func saveChanges() {
		// Final validation before saving
		validateInput()
		if !isValid {
			return
		}

		// Capture placeholder number before we mutate the player
		let wasPlaceholder = (player.firstName == "Add" && player.lastName.hasPrefix("Subject"))
		let lastPlaceholderNumber = wasPlaceholder ? extractTrailingNumberFromEnd(player.lastName) : nil

		// Save player changes

		player.firstName = firstName
		player.lastName = lastName
		player.group = selectedGroup.isEmpty ? "No Group" : selectedGroup
		
		// Update both the player.barcode property and the correct column
		player.barcode = barcode
		if let barcodeHeader = barcodeHeader {
			player.allColumns[barcodeHeader] = barcode
		}

		// Write names and team using header aliases (supports 'Athlete First Name', 'Team', etc.)
		if let idx = CSVService.findHeaderIndex(in: csvHeaders, equalsAny: HeaderAliases.firstName) {
			let h = csvHeaders[idx]
			player.allColumns[h] = firstName
		}
		if let idx = CSVService.findHeaderIndex(in: csvHeaders, equalsAny: HeaderAliases.lastName) {
			let h = csvHeaders[idx]
			player.allColumns[h] = lastName
		}
		if let idx = CSVService.findHeaderIndex(in: csvHeaders, equalsAny: HeaderAliases.group) {
			let h = csvHeaders[idx]
			player.allColumns[h] = selectedGroup
		}
		if let barcodeHeader = barcodeHeader {
			player.allColumns[barcodeHeader] = barcode
		}
		
		// Update access code column
		if let accessCodeHeader = accessCodeHeader {
			player.allColumns[accessCodeHeader] = accessCode
		}

		// Update all column values from the full edit view, but ensure main fields use the current values
		for (header, value) in columnValues {
			// Don't let columnValues overwrite the main fields we just updated
			if CSVService.findHeaderIndex(in: [header], equalsAny: HeaderAliases.firstName) != nil {
				player.allColumns[header] = firstName
			} else if CSVService.findHeaderIndex(in: [header], equalsAny: HeaderAliases.lastName) != nil {
				player.allColumns[header] = lastName
			} else if CSVService.findHeaderIndex(in: [header], equalsAny: HeaderAliases.group) != nil {
				player.allColumns[header] = selectedGroup
			} else if header == barcodeHeader {
				// Use the current barcode instead of stale columnValues
				player.allColumns[header] = barcode
			} else if header == accessCodeHeader {
				// Use the current accessCode instead of stale columnValues
				player.allColumns[header] = accessCode
			} else {
				player.allColumns[header] = value
			}
		}
		
		// Save the updated player
		onSave(player)
		// Advance by number if we edited a placeholder → real subject
		if let n = lastPlaceholderNumber {
			onAdvanceToNextFrom(n)
		} else if !placeholderPlayers.isEmpty {
			// Fallback: advance index
			let nextIndex = min(currentIndex + 1, placeholderPlayers.count - 1)
			onNavigateIndexChange(nextIndex)
		}
		dismiss()
	}


	private func extractTrailingNumberFromEnd(_ text: String) -> Int {
		let digitsReversed = text.reversed().prefix { $0.isNumber }
		let digits = String(digitsReversed.reversed())
		return Int(digits) ?? Int.max
	}

	// MARK: - Navigation Helpers
	private var canGoBackward: Bool { currentIndex > 0 }
	private var canGoForward: Bool { currentIndex < max(placeholderPlayers.count - 1, 0) }

	private func loadFields(from source: Player) {
		firstName = source.firstName
		lastName = source.lastName
		selectedGroup = source.group == "No Group" ? "" : source.group
		
		// Get barcode from the correct column instead of using source.barcode
		if let barcodeHeader = barcodeHeader {
			barcode = source.allColumns[barcodeHeader] ?? ""
			// Debug: Using barcode from column '\(barcodeHeader)': '\(barcode)'
		} else {
			barcode = source.barcode
			// Debug: Using fallback barcode: '\(barcode)'
		}
		
		// Get access code from the correct column
		if let accessCodeHeader = accessCodeHeader {
			accessCode = source.allColumns[accessCodeHeader] ?? ""
		} else {
			accessCode = ""
		}
		
		columnValues = source.allColumns
		hasExistingPhoto = !(columnValues[photoHeader ?? ""]?.isEmpty ?? true)
		isPhotographedToggle = (columnValues[referenceHeader ?? ""]?.lowercased() == "yes")
		
		// Debug logging for barcode loading (commented out to reduce console noise)
		// if barcode.count > 10 {
		//     print("📊 LoadFields: Loading long barcode '\(barcode)' (length: \(barcode.count))")
		// }
	}

	private func commitSimpleEdits() {
		player.firstName = firstName
		player.lastName = lastName
		player.group = selectedGroup.isEmpty ? "No Group" : selectedGroup
		
		// Update both the player.barcode property and the correct column
		player.barcode = barcode
		if let barcodeHeader = barcodeHeader {
			player.allColumns[barcodeHeader] = barcode
		}
		// Write names/team using header aliases (handles 'Athlete First Name', 'Team', etc.)
		if let idx = CSVService.findHeaderIndex(in: csvHeaders, equalsAny: HeaderAliases.firstName) {
			let h = csvHeaders[idx]
			player.allColumns[h] = firstName
		}
		if let idx = CSVService.findHeaderIndex(in: csvHeaders, equalsAny: HeaderAliases.lastName) {
			let h = csvHeaders[idx]
			player.allColumns[h] = lastName
		}
		if let idx = CSVService.findHeaderIndex(in: csvHeaders, equalsAny: HeaderAliases.group) {
			let h = csvHeaders[idx]
			player.allColumns[h] = selectedGroup
		}
		if let barcodeHeader = barcodeHeader {
			player.allColumns[barcodeHeader] = barcode
		}
		
		// Update access code column
		if let accessCodeHeader = accessCodeHeader {
			player.allColumns[accessCodeHeader] = accessCode
		}
	}

	private func commitFullEdits() {
		if let ph = photoHeader { columnValues[ph] = hasExistingPhoto ? "1" : "" }
		if let rh = referenceHeader { columnValues[rh] = isPhotographedToggle ? "yes" : "" }
		
		// Update access code in columnValues
		if let accessCodeHeader = accessCodeHeader {
			columnValues[accessCodeHeader] = accessCode
		}
		
		player.allColumns = columnValues
		player.hasPhoto = hasExistingPhoto
		player.isPhotographed = isPhotographedToggle
		// Read back names/group using header aliases so we reflect the correct fields
		if let idx = CSVService.findHeaderIndex(in: csvHeaders, equalsAny: HeaderAliases.firstName) {
			let header = csvHeaders[idx]
			if let fn = columnValues[header] { player.firstName = fn }
		}
		if let idx = CSVService.findHeaderIndex(in: csvHeaders, equalsAny: HeaderAliases.lastName) {
			let header = csvHeaders[idx]
			if let ln = columnValues[header] { player.lastName = ln }
		}
		if let idx = CSVService.findHeaderIndex(in: csvHeaders, equalsAny: HeaderAliases.group) {
			let header = csvHeaders[idx]
			if let gr = columnValues[header] { player.group = gr.isEmpty ? "No Group" : gr }
		}
		if let bc = columnValues[csvHeaders.first(where: { $0.contains("Barcode") }) ?? ""] {
			player.barcode = bc
		}
	}

	// MARK: - Validation
	private func validateInput() {
		validationError = ""
		isValid = true

		// Check required fields for non-placeholder players
		if !isPlaceholderPlayer {
			if firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				validationError = "First name is required"
				isValid = false
				return
			}
			if lastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				validationError = "Last name is required"
				isValid = false
				return
			}
			// Only require a barcode if the CSV actually has a barcode column (standard CSV mode).
			// In roster mode (no barcode column), skip barcode requirement.
			if barcodeHeader != nil {
				if barcode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
					validationError = "Barcode is required"
					isValid = false
					return
				}
			}
		}

		// Check for duplicate barcodes (only if barcode is not empty)
		if !barcode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			let duplicateExists = csvManager.players.contains { existingPlayer in
				existingPlayer.id != player.id &&
				existingPlayer.barcode == barcode.trimmingCharacters(in: .whitespacesAndNewlines)
			}
			if duplicateExists {
				validationError = "Barcode already exists for another player"
				isValid = false
				return
			}
		}
	}

	private func navigate(delta: Int) {
		guard !placeholderPlayers.isEmpty else { return }
		let newIndex = min(max(currentIndex + delta, 0), placeholderPlayers.count - 1)
		guard newIndex != currentIndex else { return }
		if showingMoreFields {
			commitFullEdits()
		} else {
			commitSimpleEdits()
		}
		onSave(player)
		let nextPlayer = placeholderPlayers[newIndex]
		player = nextPlayer
		loadFields(from: nextPlayer)
		currentIndex = newIndex
		onNavigateIndexChange(newIndex)
	}
}

// MARK: - Stat Label
struct StatLabel: View {
	let title: String
	let value: String

	var body: some View {
		VStack(spacing: 2) {
			Text(value)
				.font(.system(size: DesignSystem.FontSizes.headline))
			Text(title)
				.font(.system(size: DesignSystem.FontSizes.caption))
				.foregroundColor(.secondary)
		}
		.frame(maxWidth: .infinity)
	}
}

// MARK: - Merge CSVs View
struct MergeCSVsView: View {
	let currentCSV: URL?
	@EnvironmentObject var appState: AppStateManager
	@Environment(\.dismiss) private var dismiss
	
	@State private var isProcessing = false
	@State private var mergeResult: MergeResult?
	@State private var errorMessage: String?
	@State private var detectedOriginal: URL?
	@State private var detectedCopies: [URL] = []
	
	// Visual conflict resolution state
	@State private var showingConflictResolution = false
	@State private var pendingConflicts: [MergeConflict] = []
	@State private var conflictBaseFile: URL?
	@State private var conflictOtherFile: URL?
	@State private var pendingMergeContext: PendingMergeContext?

	// Local toast state
	@State private var showToast = false
	@State private var toastMessage = ""
	
	// New selection-based merge states
	@State private var showingSelection = true
	@State private var selectedCSVs: Set<URL> = []
	@State private var masterCSV: URL?
	@State private var availableCSVs: [URL] = []

	// Persisted preferences for convenience
	@AppStorage("merge.lastMasterPath") private var lastMasterPath: String = ""
	@AppStorage("merge.lastSelectedPaths") private var lastSelectedPaths: String = ""
	@AppStorage("merge.confirmInPlace") private var confirmInPlace: Bool = true

	private func showToast(_ message: String) {
		toastMessage = message
		showToast = true
		DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
			showToast = false
		}
	}
	
	// MARK: - Conflict Resolution Handler
	private func handleConflictResolution(_ resolutions: [ConflictResolution]) {
		guard let context = pendingMergeContext else {
			print("⚠️ No pending merge context found")
			return
		}
		
		// Close conflict resolution view
		showingConflictResolution = false
		
		// Process the approved resolutions
		let approvedResolutions = resolutions.filter { $0.isApproved }
		print("📋 Processing \(approvedResolutions.count) approved conflict resolutions out of \(resolutions.count) total conflicts")
		
		// Apply the user's conflict resolution choices
		// For now, we'll just complete the merge as-is since the conflicts were already resolved during the merge
		// In a more advanced implementation, we could re-merge with user preferences
		
		// Generate conflict report for approved conflicts if any
		var conflictFile: URL? = nil
		if !approvedResolutions.isEmpty {
			do {
				let outputDirectory = context.masterFile.deletingLastPathComponent()
				conflictFile = outputDirectory.appendingPathComponent("merge_conflicts_\(context.timestamp).csv")
				try writeConflictReport(conflicts: approvedResolutions.map { $0.conflict }, to: conflictFile!)
				print("📋 Created conflict report: \(conflictFile!.lastPathComponent)")
			} catch {
				print("⚠️ Failed to create conflict report: \(error)")
			}
		}
		
		// Complete the merge
		let finalResult = MergeResult(
			outputFile: context.masterFile,
			conflictReportFile: conflictFile,
			totalRecords: context.totalRecords,
			conflicts: approvedResolutions.map { $0.conflict }
		)
		
		mergeResult = finalResult
		
		// Show success toast
		let conflictMessage = approvedResolutions.isEmpty ? "" : " — \(approvedResolutions.count) conflicts resolved"
		showToast("Merged \(context.selectedCSVs.count) files into master CSV\(conflictMessage)")
		
		// Refresh the CSV list and select the updated master file
		appState.refreshCSVFiles()
		appState.selectCSVFile(context.masterFile)
		
		// Clear pending state
		pendingMergeContext = nil
		pendingConflicts = []
		conflictBaseFile = nil
		conflictOtherFile = nil
	}
	
	var body: some View {
		VStack(spacing: 0) {
			// Header
			HStack {
				Text(showingSelection ? "Select CSVs to Combine" : "Merge CSV Files")
					.font(.title2)
					.fontWeight(.bold)
				
				Spacer()
				
				if showingSelection && !selectedCSVs.isEmpty {
					Button("Auto-Merge All") {
						showingSelection = false
						detectFilesToMerge()
					}
					.buttonStyle(.bordered)
					.controlSize(.small)
				}
				
				Button("Cancel") {
					dismiss()
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
			}
			.padding()
			.background(Color(NSColor.controlBackgroundColor))
			
			// Content
			ScrollView {
				VStack(alignment: .leading, spacing: 24) {
					if showingSelection {
						csvSelectionView
					} else {
						autoMergeView
					}
				}
				.padding()
			}
		}
		.frame(width: 600, height: 500)
		.onAppear {
			loadAvailableCSVs()
		}
		.overlay(alignment: .top) {
			if showToast {
				HStack(spacing: 8) {
					Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
					Text(toastMessage).font(.callout)
					Spacer()
				}
				.padding(10)
				.background(Color(.windowBackgroundColor))
				.clipShape(RoundedRectangle(cornerRadius: 8))
				.shadow(radius: 6)
				.padding(.top, 12)
			}
		}
		.sheet(isPresented: $showingConflictResolution) {
			if !pendingConflicts.isEmpty,
			   let baseFile = conflictBaseFile,
			   let otherFile = conflictOtherFile {
				ConflictResolutionView(
					conflicts: pendingConflicts,
					baseFile: baseFile,
					otherFile: otherFile,
					onComplete: handleConflictResolution
				)
			}
		}
	}
	
	// MARK: - CSV Selection View
	@ViewBuilder
	private var csvSelectionView: some View {
		// Instructions
		VStack(alignment: .leading, spacing: 8) {
			Text("Choose CSVs to Combine")
				.font(.headline)
			
			Text("Select which CSV files you want to combine and choose a master version. The selected files will be merged into the master file, and the merged files will be deleted.")
				.font(.body)
				.foregroundColor(.secondary)
		}
		
		// Master CSV Selection
		if !availableCSVs.isEmpty {
			VStack(alignment: .leading, spacing: 12) {
				Text("Master CSV (Base File)")
					.font(.headline)
				
				Text("This file will be updated with merged data. A backup will be created before merging.")
					.font(.caption)
					.foregroundColor(.secondary)
				
				LazyVGrid(columns: [GridItem(.flexible())], spacing: 8) {
					ForEach(availableCSVs, id: \.self) { csv in
						HStack {
							Button(action: {
								masterCSV = csv
							}) {
								HStack {
									Image(systemName: masterCSV == csv ? "checkmark.circle.fill" : "circle")
										.foregroundColor(masterCSV == csv ? .blue : .secondary)
									
									VStack(alignment: .leading, spacing: 2) {
										Text(csv.lastPathComponent)
											.font(.body)
											.lineLimit(1)
											.truncationMode(.middle)
										
										if appState.isAnyPhotographerCSV(csv) {
											Text("📸 Photographer Copy")
												.font(.caption2)
												.foregroundColor(.orange)
										} else {
											Text("📄 Original CSV")
												.font(.caption2)
												.foregroundColor(.blue)
										}
									}
									
									Spacer()
								}
								.padding()
								.background(masterCSV == csv ? Color.blue.opacity(0.1) : Color.clear)
								.clipShape(RoundedRectangle(cornerRadius: 8))
								.overlay(
									RoundedRectangle(cornerRadius: 8)
										.strokeBorder(masterCSV == csv ? Color.blue : Color.secondary.opacity(0.3), lineWidth: 1)
								)
							}
							.buttonStyle(.plain)
						}
					}
				}
			}
		}
		
		// CSV Selection
		if !availableCSVs.isEmpty {
			VStack(alignment: .leading, spacing: 12) {
				Text("Additional CSVs to Merge")
					.font(.headline)
				
				Text("Select additional CSV files to merge into the master CSV. These files will be deleted after merging.")
					.font(.caption)
					.foregroundColor(.secondary)
				
				LazyVGrid(columns: [GridItem(.flexible())], spacing: 8) {
					ForEach(availableCSVs.filter { $0 != masterCSV }, id: \.self) { csv in
						HStack {
							Button(action: {
								if selectedCSVs.contains(csv) {
									selectedCSVs.remove(csv)
								} else {
									selectedCSVs.insert(csv)
								}
							}) {
								HStack {
									Image(systemName: selectedCSVs.contains(csv) ? "checkmark.square.fill" : "square")
										.foregroundColor(selectedCSVs.contains(csv) ? .green : .secondary)
									
									VStack(alignment: .leading, spacing: 2) {
										Text(csv.lastPathComponent)
											.font(.body)
											.lineLimit(1)
											.truncationMode(.middle)
										
										if appState.isAnyPhotographerCSV(csv) {
											Text("📸 Photographer Copy")
												.font(.caption2)
												.foregroundColor(.orange)
										} else {
											Text("📄 Original CSV")
												.font(.caption2)
												.foregroundColor(.blue)
										}
									}
									
									Spacer()
								}
								.padding()
								.background(selectedCSVs.contains(csv) ? Color.green.opacity(0.1) : Color.clear)
								.clipShape(RoundedRectangle(cornerRadius: 8))
								.overlay(
									RoundedRectangle(cornerRadius: 8)
										.strokeBorder(selectedCSVs.contains(csv) ? Color.green : Color.secondary.opacity(0.3), lineWidth: 1)
								)
							}
							.buttonStyle(.plain)
						}
					}
				}
			}
		}
		
		// Action Buttons
		HStack {
			Button("Select All") {
				selectedCSVs = Set(availableCSVs.filter { $0 != masterCSV })
			}
			.buttonStyle(.bordered)
			.disabled(availableCSVs.isEmpty || masterCSV == nil)
			
			Button("Clear Selection") {
				selectedCSVs.removeAll()
			}
			.buttonStyle(.bordered)
			.disabled(selectedCSVs.isEmpty)
			
			Spacer()
			
			Menu {
				// Warning text
				if confirmInPlace {
					Text("Merging will overwrite the selected master file in place and delete merged files.")
				}
				Toggle("Always show this warning", isOn: $confirmInPlace)
				Divider()
				Button("Merge into Master CSV") {
					performSelectedMerge()
				}
				if let master = masterCSV {
					Button("Open Master in Finder") { NSWorkspace.shared.activateFileViewerSelecting([master]) }
				}
				if let conflict = mergeResult?.conflictReportFile {
					Button("View Conflict Report") { NSWorkspace.shared.selectFile(conflict.path, inFileViewerRootedAtPath: "") }
				}
			} label: {
				Text("Merge into Master CSV")
			}
			.buttonStyle(.borderedProminent)
			.disabled(masterCSV == nil || selectedCSVs.isEmpty || isProcessing)
			
			if isProcessing {
				ProgressView()
					.controlSize(.small)
					.padding(.leading, 8)
			}
		}
		
		// Results
		if let result = mergeResult {
			Divider()
			
			VStack(alignment: .leading, spacing: 12) {
				Text("Merge Complete!")
					.font(.headline)
					.foregroundColor(.green)
				
				VStack(alignment: .leading, spacing: 4) {
					Text("Merged \(selectedCSVs.count) files into master CSV")
					Text("Total records: \(result.totalRecords)")
					Text("Conflicts: \(result.conflicts.count)")
					Text("Updated: \(result.outputFile.lastPathComponent)")
				}
				.font(.body)
				
				HStack {
					Button("Open Master CSV") {
						NSWorkspace.shared.selectFile(result.outputFile.path, inFileViewerRootedAtPath: "")
					}
					.buttonStyle(.bordered)
					
					if !result.conflicts.isEmpty {
						Button("View Conflict Report") {
							if let conflictFile = result.conflictReportFile {
								NSWorkspace.shared.selectFile(conflictFile.path, inFileViewerRootedAtPath: "")
							}
						}
						.buttonStyle(.bordered)
					}
					
					Spacer()
					
					Button("Done") {
						dismiss()
					}
					.buttonStyle(.borderedProminent)
				}
			}
			.padding()
			.background(Color.green.opacity(0.1))
			.clipShape(RoundedRectangle(cornerRadius: 8))
		}
		
		// Error message
		if let error = errorMessage {
			Text(error)
				.foregroundColor(.red)
				.padding()
				.background(Color.red.opacity(0.1))
				.clipShape(RoundedRectangle(cornerRadius: 8))
		}
	}
	
	// MARK: - Auto Merge View
	@ViewBuilder
	private var autoMergeView: some View {
		// Instructions
		VStack(alignment: .leading, spacing: 8) {
			Text("Merge Back to Original CSV")
				.font(.headline)
			
			Text("Merges all photographer work back into the original CSV file. Photographer copies will be deleted after successful merge. A backup and conflict report will be created.")
				.font(.body)
				.foregroundColor(.secondary)
		}
		
		// Detected Files
		VStack(alignment: .leading, spacing: 16) {
			Text("Detected Files")
				.font(.headline)
			
			// Original CSV
			if let original = detectedOriginal {
				VStack(alignment: .leading, spacing: 8) {
					Text("Original CSV (merge target)")
						.font(.subheadline)
						.foregroundColor(.secondary)
					
					HStack {
						Image(systemName: "doc.text")
							.foregroundColor(.blue)
						Text(original.lastPathComponent)
							.lineLimit(1)
							.truncationMode(.middle)
						Spacer()
					}
					.padding()
					.background(Color.blue.opacity(0.1))
					.clipShape(RoundedRectangle(cornerRadius: 8))
				}
			}
			
			// Photographer Copies
			if !detectedCopies.isEmpty {
				VStack(alignment: .leading, spacing: 8) {
					Text("Photographer Copies (\(detectedCopies.count) found)")
						.font(.subheadline)
						.foregroundColor(.secondary)
					
					ForEach(detectedCopies, id: \.self) { copy in
						HStack {
							Image(systemName: "camera.fill")
								.foregroundColor(.orange)
							Text(copy.lastPathComponent)
								.lineLimit(1)
								.truncationMode(.middle)
							Spacer()
						}
						.padding()
						.background(Color.orange.opacity(0.1))
						.clipShape(RoundedRectangle(cornerRadius: 8))
					}
				}
			} else {
				VStack(alignment: .leading, spacing: 8) {
					Text("No photographer copies found")
						.font(.subheadline)
						.foregroundColor(.secondary)
					
					HStack {
						Image(systemName: "exclamationmark.triangle")
							.foregroundColor(.yellow)
						Text("No photographer CSV copies detected in this folder")
						Spacer()
					}
					.padding()
					.background(Color.yellow.opacity(0.1))
					.clipShape(RoundedRectangle(cornerRadius: 8))
				}
			}
		}
		
		// Merge Rules
		VStack(alignment: .leading, spacing: 8) {
			Text("What Happens During Merge")
				.font(.headline)
			
			VStack(alignment: .leading, spacing: 4) {
				Text("• Original CSV is backed up before merge")
				Text("• All photographer work is merged into original CSV")
				Text("• Photographer copies are deleted after successful merge")
				Text("• Conflict report is generated if needed")
				Text("• You'll be left with just the updated original CSV")
			}
			.font(.caption)
			.foregroundColor(.secondary)
		}
		
		// Merge button
		HStack {
			Spacer()
			
			Button("Merge Back to Original CSV") {
				performAutoMerge()
			}
			.buttonStyle(.borderedProminent)
			.disabled(detectedOriginal == nil || detectedCopies.isEmpty || isProcessing)
			
			if isProcessing {
				ProgressView()
					.controlSize(.small)
					.padding(.leading, 8)
			}
		}
		
		// Results
		if let result = mergeResult {
			Divider()
			
			VStack(alignment: .leading, spacing: 12) {
				Text("Merge Complete!")
					.font(.headline)
					.foregroundColor(.green)
				
				VStack(alignment: .leading, spacing: 4) {
					Text("Merged \(result.totalRecords) records from \(detectedCopies.count + 1) files")
					Text("Conflicts: \(result.conflicts.count)")
					Text("Output: \(result.outputFile.lastPathComponent)")
				}
				.font(.body)
				
				HStack {
					Button("Open Merged File") {
						NSWorkspace.shared.selectFile(result.outputFile.path, inFileViewerRootedAtPath: "")
					}
					.buttonStyle(.bordered)
					
					if !result.conflicts.isEmpty {
						Button("View Conflict Report") {
							if let conflictFile = result.conflictReportFile {
								NSWorkspace.shared.selectFile(conflictFile.path, inFileViewerRootedAtPath: "")
							}
						}
						.buttonStyle(.bordered)
					}
					
					Spacer()
					
					Button("Done") {
						dismiss()
					}
					.buttonStyle(.borderedProminent)
				}
			}
			.padding()
			.background(Color.green.opacity(0.1))
			.clipShape(RoundedRectangle(cornerRadius: 8))
		}
		
		// Error message
		if let error = errorMessage {
			Text(error)
				.foregroundColor(.red)
				.padding()
				.background(Color.red.opacity(0.1))
				.clipShape(RoundedRectangle(cornerRadius: 8))
		}
	}
	
	// MARK: - Helper Functions
	private func loadAvailableCSVs() {
		availableCSVs = appState.availableCSVFiles
		
		// Auto-select current CSV as master if available
		if let current = currentCSV, availableCSVs.contains(current) {
			masterCSV = current
		} else if !availableCSVs.isEmpty {
			// Default to first original CSV or first CSV if no original found
			let originalCSVs = availableCSVs.filter { !appState.isAnyPhotographerCSV($0) }
			masterCSV = originalCSVs.first ?? availableCSVs.first
		}
		// Restore persisted master/selection if present
		if let restoredMaster = URL(string: lastMasterPath), availableCSVs.contains(restoredMaster) {
			masterCSV = restoredMaster
		}
		let restoredSet: Set<URL> = Set(lastSelectedPaths.split(separator: "|").compactMap { URL(string: String($0)) }.filter { availableCSVs.contains($0) })
		if !restoredSet.isEmpty {
			selectedCSVs = restoredSet
		}
		
		print("📋 Loaded \(availableCSVs.count) available CSV files")
		print("🎯 Master CSV set to: \(masterCSV?.lastPathComponent ?? "none")")
	}
	
	private func performSelectedMerge() {
		guard let masterFile = masterCSV else {
			errorMessage = "No master CSV file selected"
			return
		}
		
		guard !selectedCSVs.isEmpty else {
			errorMessage = "No CSV files selected to merge"
			return
		}
		
		// Save preferences
		lastMasterPath = masterFile.absoluteString
		lastSelectedPaths = selectedCSVs.map { $0.absoluteString }.joined(separator: "|")

		print("🚀 Starting selected merge process (in-place)...")
		print("   Master file: \(masterFile.lastPathComponent)")
		print("   Selected files to merge: \(selectedCSVs.map { $0.lastPathComponent })")
		print("   Will overwrite master and delete merged files")
		
		isProcessing = true
		errorMessage = nil
		
		DispatchQueue.global(qos: .userInitiated).async {
			do {
				let outputDirectory = masterFile.deletingLastPathComponent()
				
				// Verify master file exists
				guard FileManager.default.fileExists(atPath: masterFile.path) else {
					throw NSError(domain: "MergeError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Master file does not exist: \(masterFile.path)"])
				}
				
				// Create timestamp for conflict report naming
				let formatter = DateFormatter()
				formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
				let timestamp = formatter.string(from: Date())
				
				// Start with the master as the base
				var currentResult = masterFile
				var allConflicts: [MergeConflict] = []
				var totalRecords = 0
				var filesToDelete: [URL] = []
				
				// Merge each selected CSV into the result
				for (index, selectedCSV) in Array(self.selectedCSVs).enumerated() {
					print("🔄 Merging \(selectedCSV.lastPathComponent) into master (\(index + 1)/\(self.selectedCSVs.count))")
					
					// Verify selected CSV exists
					guard FileManager.default.fileExists(atPath: selectedCSV.path) else {
						throw NSError(domain: "MergeError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Selected CSV does not exist: \(selectedCSV.path)"])
					}
					
					let result = try CSVMergeEngine.mergeCSVFiles(
						baseFile: currentResult,
						otherFile: selectedCSV,
						outputDirectory: outputDirectory
					)
					
					// Clean up intermediate result if it's not the master file
					if currentResult != masterFile && currentResult != result.outputFile {
						try? FileManager.default.removeItem(at: currentResult)
					}
					
					currentResult = result.outputFile
					allConflicts.append(contentsOf: result.conflicts)
					totalRecords = result.totalRecords
					
					// Mark this CSV for deletion after successful merge
					filesToDelete.append(selectedCSV)
				}
				
				// Replace the master file with the merged result (no backup desired)
				if currentResult != masterFile {
					try FileManager.default.removeItem(at: masterFile)
					try FileManager.default.moveItem(at: currentResult, to: masterFile)
					Logger.log("✅ Updated master CSV: \(masterFile.lastPathComponent)")
				}
				
				// Delete the merged CSV files
				for csvToDelete in filesToDelete {
					do {
						try FileManager.default.removeItem(at: csvToDelete)
						print("🗑️ Deleted merged CSV: \(csvToDelete.lastPathComponent)")
					} catch {
						print("⚠️ Failed to delete \(csvToDelete.lastPathComponent): \(error)")
					}
				}
				
				DispatchQueue.main.async {
					self.isProcessing = false
					
					// Check if there are conflicts to resolve
					if !allConflicts.isEmpty {
						// Store merge context for after conflict resolution
						self.pendingMergeContext = PendingMergeContext(
							masterFile: masterFile,
							selectedCSVs: Array(self.selectedCSVs),
							currentIndex: -1, // Completed all merges
							currentResult: masterFile,
							allConflicts: allConflicts,
							totalRecords: totalRecords,
							filesToDelete: filesToDelete,
							timestamp: timestamp
						)
						
						// Set up conflict resolution
						self.pendingConflicts = allConflicts
						self.conflictBaseFile = masterFile
						self.conflictOtherFile = self.selectedCSVs.first // Representative file
						self.showingConflictResolution = true
					} else {
						// No conflicts - complete the merge
						let finalResult = MergeResult(
							outputFile: masterFile,
							conflictReportFile: nil,
							totalRecords: totalRecords,
							conflicts: []
						)
						self.mergeResult = finalResult
						
						// Show success toast
						self.showToast("Merged \(self.selectedCSVs.count) files into master CSV successfully")
						
						// Refresh the CSV list to remove deleted files
						self.appState.refreshCSVFiles()
						
						// Select the updated master file
						self.appState.selectCSVFile(masterFile)
					}
				}
			} catch {
				DispatchQueue.main.async {
					self.isProcessing = false
					self.errorMessage = "Merge failed: \(error.localizedDescription)"
				}
			}
		}
	}
	
	private func detectFilesToMerge() {
		print("🔍 Starting auto-merge detection...")
		print("📁 Available CSV files: \(appState.availableCSVFiles.map { $0.lastPathComponent })")
		print("📄 Current CSV: \(currentCSV?.lastPathComponent ?? "none")")
		
		// Find the original CSV for the current context
		if let currentCSV = currentCSV {
			print("🔍 Checking if current CSV is photographer copy: \(currentCSV.lastPathComponent)")
			print("   isAnyPhotographerCSV result: \(appState.isAnyPhotographerCSV(currentCSV))")
			
			// If current CSV is a photographer copy, find its original
			if appState.isAnyPhotographerCSV(currentCSV) {
				detectedOriginal = appState.getOriginalCSV(from: currentCSV)
				print("   Detected original from photographer copy: \(detectedOriginal?.lastPathComponent ?? "none")")
			} else {
				// Current CSV is already the original
				detectedOriginal = currentCSV
				print("   Current CSV is already the original")
			}
		} else {
			// No current CSV, try to find any original CSV
			let originalCSVs = appState.getOriginalCSVs()
			print("🔍 No current CSV, looking for any original CSV")
			print("   Found original CSVs: \(originalCSVs.map { $0.lastPathComponent })")
			detectedOriginal = originalCSVs.first
		}
		
		// Find all photographer copies for this original
		if let original = detectedOriginal {
			print("🔍 Looking for photographer copies of: \(original.lastPathComponent)")
			print("   Original file exists: \(FileManager.default.fileExists(atPath: original.path))")
			print("   Original file path: \(original.path)")
			
			detectedCopies = appState.getPhotographerCopiesForOriginal(original)
			print("🔍 Auto-merge detected:")
			print("   Original: \(original.lastPathComponent)")
			print("   Copies: \(detectedCopies.map { $0.lastPathComponent })")
			
			// Check if all files exist
			for copy in detectedCopies {
				print("   Copy \(copy.lastPathComponent) exists: \(FileManager.default.fileExists(atPath: copy.path))")
			}
		} else {
			print("❌ No original CSV detected!")
		}
	}
	
	private func performAutoMerge() {
		guard let originalFile = detectedOriginal else {
			errorMessage = "No original CSV file detected"
			print("❌ performAutoMerge failed: No original CSV file detected")
			return
		}
		
		guard !detectedCopies.isEmpty else {
			errorMessage = "No photographer copies found to merge"
			print("❌ performAutoMerge failed: No photographer copies found to merge")
			return
		}
		
		print("🚀 Starting auto-merge process...")
		print("   Original file: \(originalFile.lastPathComponent)")
		print("   Original exists: \(FileManager.default.fileExists(atPath: originalFile.path))")
		print("   Photographer copies: \(detectedCopies.map { $0.lastPathComponent })")
		
		isProcessing = true
		errorMessage = nil
		
		DispatchQueue.global(qos: .userInitiated).async {
			do {
				let outputDirectory = originalFile.deletingLastPathComponent()
				print("📁 Output directory: \(outputDirectory.path)")
				
				// Verify original file exists before proceeding
				guard FileManager.default.fileExists(atPath: originalFile.path) else {
					throw NSError(domain: "MergeError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Original file does not exist: \(originalFile.path)"])
				}
				
				// No backup requested; keep a timestamp for conflict report naming
				let formatter = DateFormatter()
				formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
				let timestamp = formatter.string(from: Date())
				
				// Start with the original as the base
				var currentResult = originalFile
				var allConflicts: [MergeConflict] = []
				var totalRecords = 0
				
				// Merge each photographer copy into the result
				for (index, photographerCopy) in self.detectedCopies.enumerated() {
					print("🔄 Merging \(photographerCopy.lastPathComponent) (\(index + 1)/\(self.detectedCopies.count))")
					
					// Verify photographer copy exists
					guard FileManager.default.fileExists(atPath: photographerCopy.path) else {
						print("❌ Photographer copy does not exist: \(photographerCopy.path)")
						throw NSError(domain: "MergeError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Photographer copy does not exist: \(photographerCopy.path)"])
					}
					
					print("📂 Merging files:")
					print("   Base: \(currentResult.path)")
					print("   Other: \(photographerCopy.path)")
					
					let result = try CSVMergeEngine.mergeCSVFiles(
						baseFile: currentResult,
						otherFile: photographerCopy,
						outputDirectory: outputDirectory
					)
					
					// If this isn't the first merge, we need to replace the current result safely
					if currentResult != originalFile {
						// Only delete the previous temp result if it's different from the new result
						if currentResult != result.outputFile {
							try? FileManager.default.removeItem(at: currentResult)
						}
					}
					
					currentResult = result.outputFile
					allConflicts.append(contentsOf: result.conflicts)
					totalRecords = result.totalRecords
				}
				
				// Replace the original file with the merged result
				if currentResult != originalFile {
					try FileManager.default.removeItem(at: originalFile)
					try FileManager.default.moveItem(at: currentResult, to: originalFile)
					print("✅ Updated original CSV: \(originalFile.lastPathComponent)")
				}
				
				// Generate final conflict report if needed
				var finalConflictFile: URL? = nil
				if !allConflicts.isEmpty {
					finalConflictFile = outputDirectory.appendingPathComponent("merge_conflicts_\(timestamp).csv")
					try self.writeConflictReport(conflicts: allConflicts, to: finalConflictFile!)
					print("📋 Created conflict report: \(finalConflictFile!.lastPathComponent)")
				}
				
				// Delete photographer copies after successful merge
				for photographerCopy in self.detectedCopies {
					do {
						try FileManager.default.removeItem(at: photographerCopy)
						print("🗑️ Deleted photographer copy: \(photographerCopy.lastPathComponent)")
					} catch {
						print("⚠️ Failed to delete \(photographerCopy.lastPathComponent): \(error)")
					}
				}
				
				let finalResult = MergeResult(
					outputFile: originalFile, // Return the original file, now updated
					conflictReportFile: finalConflictFile,
					totalRecords: totalRecords,
					conflicts: allConflicts
				)

				DispatchQueue.main.async {
					self.isProcessing = false
					self.mergeResult = finalResult

					// Show success toast
					let message = "Auto-merged \(detectedCopies.count) photographer copies" + (finalResult.conflicts.isEmpty ? "" : " — conflicts saved")
					self.showToast(message)

					// Refresh the CSV list to remove deleted photographer copies
					self.appState.refreshCSVFiles()

					// Switch to the original merged CSV file (single photographer mode)
					// Temporarily bypass photographer copy creation by setting SingleUser mode
					let originalPhotographerID = self.appState.photographerID
					self.appState.photographerID = "SingleUser"

					// Add a small delay to ensure CSV files list is refreshed first
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
						print("🔄 Auto-switching to single photographer mode with merged file: \(originalFile.lastPathComponent)")
						self.appState.selectCSVFile(originalFile)

						// Restore the original photographer ID after selection
						self.appState.photographerID = originalPhotographerID

						// Auto-dismiss the merge interface to return to single photographer mode
						dismiss()
					}
				}
			} catch {
				DispatchQueue.main.async {
					self.isProcessing = false
					self.errorMessage = "Auto-merge failed: \(error.localizedDescription)"
				}
			}
		}
	}
	
	private func writeConflictReport(conflicts: [MergeConflict], to url: URL) throws {
		let headers = ["Record ID", "Field", "Base Value", "Other Value", "Resolution"]
		var csvContent = headers.map { "\"\($0)\"" }.joined(separator: ",") + "\n"
		
		for conflict in conflicts {
			let row = [
				conflict.recordID,
				conflict.field,
				conflict.baseValue,
				conflict.otherValue,
				conflict.resolution
			].map { "\"\($0)\"" }.joined(separator: ",")
			csvContent += row + "\n"
		}
		
		try csvContent.write(to: url, atomically: true, encoding: .utf8)
	}
}

// Legacy DualSetupView removed; use Settings instead

// MARK: - Merge Result
struct MergeResult {
	let outputFile: URL
	let conflictReportFile: URL?
	let totalRecords: Int
	let conflicts: [MergeConflict]
}

struct MergeConflict {
	let recordID: String
	let field: String
	let baseValue: String
	let otherValue: String
	let resolution: String
	
	// Additional data for visual conflict resolution
	let playerName: String? // For better identification
	let conflictType: ConflictType
	
	// Additional identifying fields for better context
	let firstName: String?
	let lastName: String?
	let group: String?
	let fullRecord: [String: String] // Complete record data for additional context
}

enum ConflictType {
	case fieldChange // Value changed between files
	case newRecord   // Record exists in one file but not the other
	case deleted     // Record was removed from one file
}

struct PendingMergeContext {
	let masterFile: URL
	let selectedCSVs: [URL]
	let currentIndex: Int
	let currentResult: URL
	let allConflicts: [MergeConflict]
	let totalRecords: Int
	let filesToDelete: [URL]
	let timestamp: String
}

struct ConflictResolution {
	let conflict: MergeConflict
	var userChoice: ResolutionChoice
	var isApproved: Bool = false
}

enum ResolutionChoice {
	case keepBase    // Keep the base (current) value
	case useOther    // Use the other file's value
	case userDecided // User manually chose
}

// MARK: - CSV Merge Engine
class CSVMergeEngine {
	struct MergedRecord {
		let barcode: String
		var fields: [String: String]
		var isPhotographed: Bool
		var photographedBy: String?
		var photographedAt: String?
		var lastEditedBy: String?
		var lastEditedAt: String?
	}
	
	private static func findBarcodeColumn(in headers: [String]) -> String? {
		// First try to find a column containing "barcode"
		if let barcodeColumn = headers.first(where: { $0.localizedCaseInsensitiveContains("barcode") }) {
			return barcodeColumn
		}
		
		// Then try "Child ID" (used by this app's CSV format)
		if let childIDColumn = headers.first(where: { $0 == "Child ID" }) {
			return childIDColumn
		}
		
		// Fallback to any column containing "id"
		return headers.first { $0.localizedCaseInsensitiveContains("id") }
	}
	
	static func mergeCSVFiles(baseFile: URL, otherFile: URL, outputDirectory: URL) throws -> MergeResult {
		// Parse both CSV files
		let baseParsed = try parseCSVFile(baseFile)
		let otherParsed = try parseCSVFile(otherFile)
		
		// Find the barcode column name (flexible detection like main parser)
		let barcodeColumnName = findBarcodeColumn(in: baseParsed.headers) ?? findBarcodeColumn(in: otherParsed.headers)
		guard let barcodeColumn = barcodeColumnName else {
			throw NSError(domain: "CSVMergeEngine", code: 2, userInfo: [NSLocalizedDescriptionKey: "No barcode column found in CSV files"])
		}
		
		print("🔍 Using barcode column: '\(barcodeColumn)'")
		
		// Preserve header order: base headers then any new headers from other
		var orderedHeaders: [String] = baseParsed.headers
		for h in otherParsed.headers where !orderedHeaders.contains(h) {
			orderedHeaders.append(h)
		}
		
		// Create merged records dictionary keyed by barcode
		var mergedRecords: [String: MergedRecord] = [:]
		var conflicts: [MergeConflict] = []
		var baseOrderBarcodes: [String] = []
		
		// Process base records first
		for record in baseParsed.records {
			if let barcode = record[barcodeColumn], !barcode.isEmpty {
				mergedRecords[barcode] = MergedRecord(
					barcode: barcode,
					fields: record,
					isPhotographed: (record["Reference"]?.lowercased() == "yes"),
					photographedBy: record["Photographed By"],
					photographedAt: record["Photographed At"],
					lastEditedBy: record["Last Edited By"],
					lastEditedAt: record["Last Edited At"]
				)
				baseOrderBarcodes.append(barcode)
			}
		}
		
		print("📊 Processed \(mergedRecords.count) base records")
		
		// Process other records and merge
		var otherRecordsProcessed = 0
		var newRecordsAdded = 0
		var recordsMerged = 0
		var extrasBarcodes: [String] = []
		
		for record in otherParsed.records {
			guard let barcode = record[barcodeColumn], !barcode.isEmpty else { continue }
			otherRecordsProcessed += 1
			
				if let existingRecord = mergedRecords[barcode] {
				// Merge existing record
				let (updatedRecord, recordConflicts) = mergeRecords(
					base: existingRecord,
					other: record,
					barcode: barcode
				)
				mergedRecords[barcode] = updatedRecord
				conflicts.append(contentsOf: recordConflicts)
				recordsMerged += 1
			} else {
				// Add new record from other file
				let playerName = extractPlayerName(from: record)
				mergedRecords[barcode] = MergedRecord(
					barcode: barcode,
					fields: record,
					isPhotographed: (record["Reference"]?.lowercased() == "yes"),
					photographedBy: record["Photographed By"],
					photographedAt: record["Photographed At"],
					lastEditedBy: record["Last Edited By"],
					lastEditedAt: record["Last Edited At"]
				)
				
				// Extract identifying fields for new record
				let identifying = extractIdentifyingFields(from: record)
				
				// Track as new record conflict for user review
				conflicts.append(MergeConflict(
					recordID: barcode,
					field: "NEW_RECORD",
					baseValue: "",
					otherValue: "New record added",
					resolution: "Added from other file",
					playerName: playerName,
					conflictType: .newRecord,
					firstName: identifying.firstName,
					lastName: identifying.lastName,
					group: identifying.group,
					fullRecord: record
				))
				
				newRecordsAdded += 1
				extrasBarcodes.append(barcode)
			}
		}
		
		print("📊 Other file processing: \(otherRecordsProcessed) records processed, \(recordsMerged) merged, \(newRecordsAdded) new records added")
		
		// Generate output filename
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
		let timestamp = formatter.string(from: Date())
		let uniqueSuffix = UUID().uuidString.prefix(8)
		let outputFile = outputDirectory.appendingPathComponent("merged_\(timestamp)_\(uniqueSuffix).csv")
		
		print("💾 Writing merged CSV to: \(outputFile.lastPathComponent)")
		print("📊 Final merged records count: \(mergedRecords.count)")
		print("📊 Total conflicts: \(conflicts.count)")
		
		// Build ordered merged list: base order first, then extras
		let orderedBarcodes = baseOrderBarcodes + extrasBarcodes
		let orderedMerged: [MergedRecord] = orderedBarcodes.compactMap { mergedRecords[$0] }
		
		// Write merged CSV preserving base delimiter and header order
		try writeMergedCSV(records: orderedMerged, headers: orderedHeaders, delimiter: baseParsed.delimiter, to: outputFile)
		print("✅ Successfully wrote merged CSV")
		
		// Note: Conflict report will be generated at the end of the full merge process
		
		return MergeResult(
			outputFile: outputFile,
			conflictReportFile: nil, // Will be set in the main merge function
			totalRecords: mergedRecords.count,
			conflicts: conflicts
		)
	}
	
	private static func parseCSVFile(_ url: URL) throws -> (headers: [String], records: [[String: String]], delimiter: String) {
		let content = try String(contentsOf: url, encoding: .utf8)
		let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
		
		guard !lines.isEmpty else {
			throw NSError(domain: "CSVMergeEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty CSV file"])
		}
		
		let delimiter = lines[0].contains(",") ? "," : ";"
		let headers = lines[0].components(separatedBy: delimiter).map {
			$0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
		}
		
		print("📋 CSV Headers in \(url.lastPathComponent): \(headers)")
		print("🔍 Looking for barcode column in: \(headers)")
		let barcodeColumn = headers.first { $0.localizedCaseInsensitiveContains("barcode") }
		print("🎯 Found barcode column: \(barcodeColumn ?? "NONE")")
		
		var records: [[String: String]] = []
		
		for line in lines.dropFirst() {
			let fields = line.components(separatedBy: delimiter).map {
				$0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
			}
			
			var record: [String: String] = [:]
			for (index, header) in headers.enumerated() {
				record[header] = index < fields.count ? fields[index] : ""
			}
			records.append(record)
		}
		
		return (headers: headers, records: records, delimiter: delimiter)
	}
	
	private static func mergeRecords(base: MergedRecord, other: [String: String], barcode: String) -> (MergedRecord, [MergeConflict]) {
		var merged = base
		var conflicts: [MergeConflict] = []
		
		// Extract player name for better conflict identification
		let playerName = extractPlayerName(from: base.fields) ?? extractPlayerName(from: other)
		
		// Extract additional identifying fields
		let baseIdentifying = extractIdentifyingFields(from: base.fields)
		let otherIdentifying = extractIdentifyingFields(from: other)
		
		// Use base fields if available, otherwise fall back to other
		let firstName = baseIdentifying.firstName ?? otherIdentifying.firstName
		let lastName = baseIdentifying.lastName ?? otherIdentifying.lastName
		let group = baseIdentifying.group ?? otherIdentifying.group
		
		// Merge photographed status (OR logic - if either is yes, result is yes)
		let otherIsPhotographed = (other["Reference"]?.lowercased() == "yes")
		if otherIsPhotographed && !merged.isPhotographed {
			merged.isPhotographed = true
			merged.fields["Reference"] = "yes"
			
			// Use the photographer metadata from the "yes" record
			if let photographedBy = other["Photographed By"], !photographedBy.isEmpty {
				merged.photographedBy = photographedBy
				merged.fields["Photographed By"] = photographedBy
			}
			if let photographedAt = other["Photographed At"], !photographedAt.isEmpty {
				merged.photographedAt = photographedAt
				merged.fields["Photographed At"] = photographedAt
			}
		}
		
		// Merge other fields using last-edit-wins logic
		for (field, otherValue) in other {
			guard !field.isEmpty && field != "Barcode" && field != "barcode" else { continue }
			
			let baseValue = merged.fields[field] ?? ""
			
			// Skip if values are the same
			if baseValue == otherValue { continue }
			
			// Handle special metadata fields
			if field == "Reference" {
				// Already handled above
				continue
			} else if field == "Photographed By" || field == "Photographed At" {
				// Already handled in photographed status logic
				continue
			} else if field == "Last Edited By" || field == "Last Edited At" {
				// Always take the most recent edit metadata
				merged.fields[field] = otherValue
				if field == "Last Edited By" {
					merged.lastEditedBy = otherValue
				} else {
					merged.lastEditedAt = otherValue
				}
				continue
			}
			
			// For regular fields, use timestamp-based resolution
			let shouldUseOther = shouldUseOtherValue(
				baseEditTime: merged.lastEditedAt,
				otherEditTime: other["Last Edited At"],
				baseValue: baseValue,
				otherValue: otherValue
			)
			
			if shouldUseOther {
				merged.fields[field] = otherValue
			} else if baseValue != otherValue {
				// Flag as conflict if values differ but we're keeping base
				conflicts.append(MergeConflict(
					recordID: barcode,
					field: field,
					baseValue: baseValue,
					otherValue: otherValue,
					resolution: "Kept base value (newer/same timestamp)",
					playerName: playerName,
					conflictType: .fieldChange,
					firstName: firstName,
					lastName: lastName,
					group: group,
					fullRecord: base.fields
				))
			}
		}
		
		return (merged, conflicts)
	}
	
	private static func extractPlayerName(from record: [String: String]) -> String? {
		// Try common name fields in order of preference
		let nameFields = ["Name", "Full Name", "Player Name", "FirstName LastName", "First Name Last Name"]
		
		for field in nameFields {
			if let name = record[field], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				return name.trimmingCharacters(in: .whitespacesAndNewlines)
			}
		}
		
		// Try combining first and last name if separate fields exist
		let firstName = record["First Name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		let lastName = record["Last Name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		
		if !firstName.isEmpty || !lastName.isEmpty {
			return "\(firstName) \(lastName)".trimmingCharacters(in: .whitespacesAndNewlines)
		}
		
		return nil
	}
	
	private static func extractIdentifyingFields(from record: [String: String]) -> (firstName: String?, lastName: String?, group: String?) {
		// Extract first name
		let firstNameFields = ["First Name", "FirstName", "Given Name"]
		var firstName: String?
		for field in firstNameFields {
			if let value = record[field], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				firstName = value.trimmingCharacters(in: .whitespacesAndNewlines)
				break
			}
		}
		
		// Extract last name
		let lastNameFields = ["Last Name", "LastName", "Surname", "Family Name"]
		var lastName: String?
		for field in lastNameFields {
			if let value = record[field], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				lastName = value.trimmingCharacters(in: .whitespacesAndNewlines)
				break
			}
		}
		
		// Extract group
		let groupFields = ["Group", "Team", "Class", "Category", "Division", "Squad"]
		var group: String?
		for field in groupFields {
			if let value = record[field], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				group = value.trimmingCharacters(in: .whitespacesAndNewlines)
				break
			}
		}
		
		return (firstName: firstName, lastName: lastName, group: group)
	}
	
	private static func shouldUseOtherValue(baseEditTime: String?, otherEditTime: String?, baseValue: String, otherValue: String) -> Bool {
		// If either value is empty, prefer the non-empty one
		if baseValue.isEmpty && !otherValue.isEmpty { return true }
		if !baseValue.isEmpty && otherValue.isEmpty { return false }
		
		// If we have timestamps, use the more recent one
		if let baseTime = baseEditTime, let otherTime = otherEditTime {
			let iso = ISO8601DateFormatter()
			let df = DateFormatter()
			df.locale = Locale(identifier: "en_US_POSIX")
			df.timeZone = .current
			df.dateFormat = "yyyy-MM-dd HH:mm:ss"
			func parse(_ s: String) -> Date? {
				return iso.date(from: s) ?? df.date(from: s)
			}
			if let baseDate = parse(baseTime), let otherDate = parse(otherTime) {
				return otherDate > baseDate
			}
		}
		
		// If no timestamps or can't parse, default to using the newer value (other)
		return true
	}
	
	private static func writeMergedCSV(records: [MergedRecord], headers: [String], delimiter: String, to url: URL) throws {
		var csvContent = headers.map { "\"\($0)\"" }.joined(separator: delimiter) + "\n"
		
		for record in records {
			let row = headers.map { header in
				let value = record.fields[header] ?? ""
				return "\"\(value)\""
			}.joined(separator: delimiter)
			csvContent += row + "\n"
		}
		
		try csvContent.write(to: url, atomically: true, encoding: .utf8)
	}
	
	private static func writeConflictReport(conflicts: [MergeConflict], to url: URL) throws {
		let headers = ["Record ID", "Field", "Base Value", "Other Value", "Resolution"]
		var csvContent = headers.map { "\"\($0)\"" }.joined(separator: ",") + "\n"
		
		for conflict in conflicts {
			let row = [
				conflict.recordID,
				conflict.field,
				conflict.baseValue,
				conflict.otherValue,
				conflict.resolution
			].map { "\"\($0)\"" }.joined(separator: ",")
			csvContent += row + "\n"
		}
		
		try csvContent.write(to: url, atomically: true, encoding: .utf8)
	}
}

// MARK: - CSVModeView Methods
extension CSVModeView {
	private func executeBuddyCopy() {
		let selectedPlayers = realPlayers.filter { buddySelectedPlayerIDs.contains($0.id) }
		let barcodes = selectedPlayers.map { $0.barcode }
		let combinedBarcode = barcodes.joined(separator: ",")
		let teamCounts = Dictionary(grouping: selectedPlayers.map { $0.group }, by: { $0 }).mapValues { $0.count }
		let mostCommonTeam = teamCounts.max(by: { $0.value < $1.value })?.key ?? ""
		let team = mostCommonTeam.trimmingCharacters(in: .whitespacesAndNewlines)
		let resolvedTeam = (team.isEmpty || team == "No Group") ? "Manual Sort" : team
		let namePart: String = "\(resolvedTeam)_Buddy_"
		let payload = "\(namePart)\t\(combinedBarcode)"

		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.setString(payload, forType: .string)

		AppleScriptExecutor.executeScript(named: "CSV Data")

		// Mark all selected players as photographed
		for playerID in buddySelectedPlayerIDs {
			csvManager.markAsPhotographed(id: playerID)
		}

		// Advance the joke and show banner
		appState.nextJoke()
		copiedBarcode = payload
		copiedPlayerName = selectedPlayers.map(\.fullName).prefix(3).joined(separator: ", ") + (selectedPlayers.count > 3 ? ", …" : "")
		showCopiedBanner = true
		DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
			showCopiedBanner = false
		}

		// Clear selection
		buddySelectedPlayerIDs.removeAll()
	}
	
	private func handlePlayerTap(_ player: Player) {
		if isBuddyMode {
			// Buddy mode: toggle selection
			if buddySelectedPlayerIDs.contains(player.id) {
				buddySelectedPlayerIDs.remove(player.id)
			} else {
				buddySelectedPlayerIDs.insert(player.id)
			}
		} else if isEditCopyrightMode {
			// Edit Copyright mode: copy barcode and run Edit Copyright script
			selectedPlayerID = player.id
			copiedBarcode = player.barcode
			copiedPlayerName = player.fullName

			let pasteboard = NSPasteboard.general
			pasteboard.clearContents()
			pasteboard.setString(player.barcode, forType: .string)

			// Show copied banner for 1 second
			showCopiedBanner = true
			DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
				showCopiedBanner = false
			}

			AppleScriptExecutor.executeScript(named: "Edit Copyright")
			} else {
			// Normal mode: single player copy/send
			selectedPlayerID = player.id
			
			let pasteboard = NSPasteboard.general
			pasteboard.clearContents()
			
				if csvManager.isRosterMode {
				// Roster mode: generate Manual-style output
				let rosterOutput = csvManager.generateRosterOutput(for: player)
				pasteboard.setString(rosterOutput, forType: .string)
				
				copiedBarcode = rosterOutput
				copiedPlayerName = csvManager.columnMappings.getDisplayName(from: player)
				
				// Use Manual Data script for roster mode
				AppleScriptExecutor.executeScript(named: "Manual Data")
				
				Logger.log("🎯 Roster mode: copied '\(rosterOutput)' for player '\(copiedPlayerName)'")
				} else {
				// Standard CSV mode: use barcode
					let rawTeam = player.group.trimmingCharacters(in: .whitespacesAndNewlines)
					let resolvedTeam = (rawTeam.isEmpty || rawTeam == "No Group") ? "Manual Sort" : rawTeam
					let newName = "\(resolvedTeam)_\(player.fullName)_"
					let payload = "\(newName)\t\(player.barcode)"
					pasteboard.setString(payload, forType: .string)
					
					copiedBarcode = player.barcode
					copiedPlayerName = player.fullName
					
					AppleScriptExecutor.executeScript(named: "CSV Data")
			}

			csvManager.markAsPhotographed(id: player.id)

			// Advance the joke when a name is clicked
			appState.nextJoke()

			showCopiedBanner = true
			DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
			showCopiedBanner = false
		}
	}
}
}

struct DensePlayerRow: View {
	let player: Player
	let displayName: String
	let isSelected: Bool
    let isBuddySelected: Bool
	let hasChanges: Bool
	let onToggleDone: () -> Void
	let onEdit: () -> Void
	let onTap: () -> Void

	@State private var isExpanded = false

	var body: some View {
		VStack(spacing: 0) {
			// Main row
			HStack(spacing: 8) {
				Button(action: onToggleDone) {
					Image(systemName: player.isPhotographed ? "checkmark.circle.fill" : "circle")
						.foregroundColor(player.isPhotographed ? .green : .secondary)
				}
				.buttonStyle(.plain)

				VStack(alignment: .leading, spacing: 2) {
					HStack(spacing: 6) {
						Text(displayName)
							.fontWeight(.semibold)
							.strikethrough(player.isPhotographed)
							.foregroundColor(player.isPhotographed ? .secondary : .primary)
							.lineLimit(1)
						if hasChanges {
							Button(action: { isExpanded.toggle() }) {
								HStack(spacing: 2) {
									Text("Changed")
										.font(.caption2)
									Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
										.font(.caption2)
								}
								.padding(.horizontal, 4)
								.padding(.vertical, 1)
								.background(Color.orange.opacity(0.15))
								.foregroundColor(.orange)
								.clipShape(RoundedRectangle(cornerRadius: 4))
							}
							.buttonStyle(.plain)
						}
					}
					VStack(alignment: .leading, spacing: 2) {
						HStack(spacing: 6) {
							if player.group != "No Group" && !player.group.isEmpty {
								Text(player.group).font(.caption2).foregroundColor(.secondary)
							}
							if player.hasPhoto {
								Image(systemName: "photo").font(.caption2).foregroundColor(.blue)
							}
						}
						// Barcode under group in list row
						if !player.barcode.isEmpty {
							HStack(spacing: 4) {
								Image(systemName: "barcode.viewfinder").font(.caption2).foregroundColor(.secondary)
								Text(player.barcode)
									.font(.caption)
									.foregroundColor(.secondary)
									.lineLimit(1)
									.truncationMode(.middle)
							}
						}
					}
				}

				Spacer()

				Button("Edit", action: onEdit).controlSize(.small)
			}
			.padding(8)

			// Expanded view showing original values
			if isExpanded && hasChanges {
				VStack(alignment: .leading, spacing: 4) {
					Text("Original values:")
						.font(.caption2)
						.foregroundColor(.secondary)
						.padding(.leading, 8)

					if let origFirst = player.getOriginalValue(for: "Student firstname"),
					   origFirst != player.firstName {
						Text("Name: \(origFirst) \(player.getOriginalValue(for: "Student lastname") ?? player.lastName)")
							.font(.caption)
							.foregroundColor(.orange)
							.padding(.leading, 16)
					}
					if let origGroup = player.getOriginalValue(for: "Group"),
					   origGroup != player.group {
						Text("Group: \(origGroup)")
							.font(.caption)
							.foregroundColor(.orange)
							.padding(.leading, 16)
					}
					if let origBarcode = player.getOriginalValue(for: player.barcodeColumnName()),
					   origBarcode != player.barcode {
						Text("Barcode: \(origBarcode)")
							.font(.caption)
							.foregroundColor(.orange)
							.padding(.leading, 16)
					}
				}
				.padding(.vertical, 4)
				.padding(.horizontal, 8)
				.background(Color.orange.opacity(0.05))
				.clipShape(RoundedRectangle(cornerRadius: 4))
				.padding(.horizontal, 8)
				.padding(.bottom, 8)
			}
		}
		.contentShape(Rectangle())
		.onTapGesture(perform: onTap)
        .background(
            isBuddySelected ? Color.accentColor.opacity(0.20) :
            (isSelected ? Color.accentColor.opacity(0.08) : .clear)
        )
		.overlay(
			RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isBuddySelected ? Color.accentColor.opacity(0.5) :
                    (isSelected ? Color.accentColor.opacity(0.25) : .clear),
                    lineWidth: 1
                )
		)
	}
}

struct ContactStyleRow<Content: View, Footer: View>: View {
	let isRemovable: Bool
	let title: String
	let content: () -> Content
	let footer: () -> Footer
	var onRemove: (() -> Void)? = nil

	init(isRemovable: Bool, title: String, @ViewBuilder content: @escaping () -> Content, @ViewBuilder footer: @escaping () -> Footer, onRemove: (() -> Void)? = nil) {
		self.isRemovable = isRemovable
		self.title = title
		self.content = content
		self.footer = footer
		self.onRemove = onRemove
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(alignment: .top, spacing: 12) {
				if isRemovable, let onRemove {
					Button(role: .destructive) { onRemove() } label: { Image(systemName: "minus.circle.fill").foregroundColor(.red) }
					.buttonStyle(.plain)
				}
				Text(title)
					.font(.subheadline.weight(.semibold))
					.foregroundColor(.accentColor)
					.frame(width: 110, alignment: .trailing)
				content()
			}
			.padding(.vertical, 4)
			.overlay(Divider().offset(x: 0, y: 12), alignment: .bottom)
			footer()
		}
	}
}

struct ContactAdditionalFieldsSection: View {
	let allHeaders: [String]
	@Binding var columnValues: [String:String]
	let player: Player
	@Binding var hasExistingPhoto: Bool
	@Binding var isPhotographedToggle: Bool
	@Binding var showingMoreFields: Bool
	
	private var additionalHeaders: [String] {
		allHeaders.filter { !["Student firstname", "Student lastname", "Group", "Barcode", "Barcode (1)", "Child ID", "Reference", "Photo"].contains($0) }
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			// Show More/Less Button
			HStack {
				Button(action: { showingMoreFields.toggle() }) {
					HStack(spacing: 6) {
						Image(systemName: showingMoreFields ? "chevron.down" : "chevron.right")
							.font(.caption.weight(.semibold))
						Text(showingMoreFields ? "Hide Additional Fields" : "Show Additional Fields (\(additionalHeaders.count + 1))")
							.font(.headline)
					}
				}
				.buttonStyle(.plain)
				.foregroundColor(.accentColor)
				
				Spacer()
			}
			.padding(.top, 4)
			
			if showingMoreFields {
				ForEach(additionalHeaders, id: \.self) { header in
					ContactStyleRow(isRemovable: false, title: header) {
						TextField("Enter \(header)", text: Binding(
							get: { columnValues[header] ?? "" },
							set: { columnValues[header] = $0 }
						))
						.textFieldStyle(.roundedBorder)
						.font(.callout)
					} footer: {
						if let originalValue = player.getOriginalValue(for: header), !originalValue.isEmpty {
							Text("Originally: \(originalValue)")
								.font(.caption2)
								.foregroundColor(.orange)
						}
					}
				}
				
				Divider().padding(.vertical, 4)
				
				ContactStyleRow(isRemovable: false, title: "App Status") {
					VStack(alignment: .leading, spacing: 8) {
						Toggle("Has Existing Photo", isOn: $hasExistingPhoto)
						Toggle("Photographed", isOn: $isPhotographedToggle)
					}
				} footer: { EmptyView() }
			}
		}
	}
}

// MARK: - Modern UI Components

struct SectionHeader: View {
	let title: String
	let icon: String
	
	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: icon)
				.font(.system(size: 14, weight: .medium))
				.foregroundColor(.accentColor)
			
			Text(title)
				.font(.system(size: 16, weight: .semibold))
				.foregroundColor(.primary)
			
			Spacer()
		}
	}
}

struct ModernField: View {
	let title: String
	@Binding var text: String
	let originalValue: String?
	var isRequired: Bool = false
	var isBarcode: Bool = false
	var onChange: (() -> Void)?
	
	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 4) {
				Text(title)
					.font(.system(size: 14, weight: .medium))
					.foregroundColor(.primary)
				
				if isRequired {
					Text("*")
						.font(.system(size: 14, weight: .bold))
						.foregroundColor(.red)
				}
			}
			
			TextField("Enter \(title.lowercased())", text: $text)
				.textFieldStyle(ModernTextFieldStyle())
				.font(.system(size: 15, weight: .regular, design: isBarcode ? .monospaced : .default))
				.disableAutocorrection(isBarcode)
				.onChange(of: text, initial: false) { oldValue, newValue in
					onChange?()
				}
			
			if let originalValue = originalValue, !originalValue.isEmpty {
				HStack(spacing: 4) {
					Image(systemName: "arrow.clockwise")
						.font(.system(size: 10))
						.foregroundColor(.orange)
					Text("Originally: \(originalValue)")
						.font(.system(size: 12))
						.foregroundColor(.orange)
				}
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

struct ModernTextFieldStyle: TextFieldStyle {
	func _body(configuration: TextField<Self._Label>) -> some View {
		configuration
			.padding(.horizontal, 12)
			.padding(.vertical, 10)
			.background(Color(NSColor.textBackgroundColor))
			.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
			.overlay(
				RoundedRectangle(cornerRadius: 8, style: .continuous)
					.strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
			)
	}
}

struct NarrowGroupSelectionField: View {
	@Binding var selectedGroup: String
	let availableGroups: [String]
	let originalGroup: String?
	@Binding var showingNewGroupField: Bool
	@Binding var newGroupName: String
	let onAddNewGroup: () -> Void
	
	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			// Group Picker - Full width for narrow layout
			VStack(alignment: .leading, spacing: 8) {
				HStack(spacing: 4) {
					Text("Group")
						.font(.system(size: 14, weight: .medium))
						.foregroundColor(.primary)
					
					Spacer()
					
					Button {
						showingNewGroupField.toggle()
					} label: {
						Image(systemName: "plus.circle.fill")
							.font(.system(size: 16))
							.foregroundColor(.accentColor)
					}
					.buttonStyle(.plain)
					.help("Add new group")
				}
				
				Picker("Select Group", selection: $selectedGroup) {
					Text("No Group").tag("")
					ForEach(availableGroups, id: \.self) { group in
						Text(group).tag(group)
					}
				}
				.pickerStyle(.menu)
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			
			// Original group indicator
			if let originalGroup = originalGroup, !originalGroup.isEmpty {
				HStack(spacing: 4) {
					Image(systemName: "arrow.clockwise")
						.font(.system(size: 10))
						.foregroundColor(.orange)
					Text("Originally: \(originalGroup)")
						.font(.system(size: 12))
						.foregroundColor(.orange)
				}
			}
			
			// New Group Field (if showing) - Stacked vertically for narrow layout
			if showingNewGroupField {
				VStack(alignment: .leading, spacing: 12) {
					HStack {
						Text("Create New Group")
							.font(.system(size: 14, weight: .medium))
							.foregroundColor(.primary)
						
						Spacer()
						
						Button {
							showingNewGroupField = false
							newGroupName = ""
						} label: {
							Image(systemName: "xmark.circle.fill")
								.font(.system(size: 16))
								.foregroundColor(.secondary)
						}
						.buttonStyle(.plain)
					}
					
					VStack(spacing: 8) {
						TextField("Enter group name", text: $newGroupName)
							.textFieldStyle(ModernTextFieldStyle())
							.onSubmit { onAddNewGroup() }
						
						Button("Add Group") { onAddNewGroup() }
							.buttonStyle(.borderedProminent)
							.controlSize(.regular)
							.frame(maxWidth: .infinity)
							.disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
					}
				}
				.padding(16)
				.background(Color.accentColor.opacity(0.05))
				.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
				.overlay(
					RoundedRectangle(cornerRadius: 12, style: .continuous)
						.strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
				)
			}
		}
	}
}

struct GroupSelectionField: View {
	@Binding var selectedGroup: String
	let availableGroups: [String]
	let originalGroup: String?
	@Binding var showingNewGroupField: Bool
	@Binding var newGroupName: String
	let onAddNewGroup: () -> Void
	
	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 12) {
				// Group Picker
				VStack(alignment: .leading, spacing: 8) {
					HStack(spacing: 4) {
						Text("Group")
							.font(.system(size: 14, weight: .medium))
							.foregroundColor(.primary)
					}
					
					HStack(spacing: 8) {
						Picker("Select Group", selection: $selectedGroup) {
							Text("No Group").tag("")
							ForEach(availableGroups, id: \.self) { group in
								Text(group).tag(group)
							}
						}
						.pickerStyle(.menu)
						.frame(maxWidth: .infinity, alignment: .leading)
						
						Button {
							showingNewGroupField.toggle()
						} label: {
							Image(systemName: "plus.circle.fill")
								.font(.system(size: 16))
								.foregroundColor(.accentColor)
						}
						.buttonStyle(.plain)
						.help("Add new group")
					}
				}
				.frame(maxWidth: .infinity)
			}
			
			// Original group indicator
			if let originalGroup = originalGroup, !originalGroup.isEmpty {
				HStack(spacing: 4) {
					Image(systemName: "arrow.clockwise")
						.font(.system(size: 10))
						.foregroundColor(.orange)
					Text("Originally: \(originalGroup)")
						.font(.system(size: 12))
						.foregroundColor(.orange)
				}
			}
			
			// New Group Field (if showing)
			if showingNewGroupField {
				VStack(alignment: .leading, spacing: 8) {
					HStack {
						Text("Create New Group")
							.font(.system(size: 14, weight: .medium))
							.foregroundColor(.primary)
						
						Spacer()
						
						Button {
							showingNewGroupField = false
							newGroupName = ""
						} label: {
							Image(systemName: "xmark.circle.fill")
								.font(.system(size: 16))
								.foregroundColor(.secondary)
						}
						.buttonStyle(.plain)
					}
					
					HStack(spacing: 12) {
						TextField("Enter group name", text: $newGroupName)
							.textFieldStyle(ModernTextFieldStyle())
							.onSubmit { onAddNewGroup() }
						
						Button("Add") { onAddNewGroup() }
							.buttonStyle(.borderedProminent)
							.controlSize(.regular)
							.disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
					}
				}
				.padding(16)
				.background(Color.accentColor.opacity(0.05))
				.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
				.overlay(
					RoundedRectangle(cornerRadius: 12, style: .continuous)
						.strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
				)
			}
		}
	}
}

struct CompactField: View {
	let title: String
	@Binding var text: String
	let originalValue: String?
	var isBarcode: Bool = false
	var onChange: (() -> Void)?
	
	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(title)
				.font(.system(size: 13, weight: .medium))
				.foregroundColor(.secondary)
			
			TextField(title, text: $text)
				.textFieldStyle(.roundedBorder)
				.font(.system(size: 14, weight: .regular, design: isBarcode ? .monospaced : .default))
				.disableAutocorrection(isBarcode)
				.onChange(of: text, initial: false) { oldValue, newValue in
					onChange?()
				}
			
			if let originalValue = originalValue, !originalValue.isEmpty {
				Text("Originally: \(originalValue)")
					.font(.system(size: 10))
					.foregroundColor(.orange)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

// MARK: - Visual Conflict Resolution Interface
struct ConflictResolutionView: View {
	@Environment(\.dismiss) private var dismiss
	@State private var conflictResolutions: [ConflictResolution]
	@State private var showingPreview = false
	
	let baseFile: URL
	let otherFile: URL
	let onComplete: ([ConflictResolution]) -> Void
	
	init(conflicts: [MergeConflict], baseFile: URL, otherFile: URL, onComplete: @escaping ([ConflictResolution]) -> Void) {
		self.baseFile = baseFile
		self.otherFile = otherFile
		self.onComplete = onComplete
		self._conflictResolutions = State(initialValue: conflicts.map { conflict in
			ConflictResolution(
				conflict: conflict,
				userChoice: conflict.resolution.contains("base") ? .keepBase : .useOther,
				isApproved: false
			)
		})
	}
	
	var body: some View {
		VStack(spacing: 0) {
			// Header
			headerView
			
			// Main Content
			if conflictResolutions.isEmpty {
				noConflictsView
			} else {
				conflictListView
			}
			
			// Footer
			footerView
		}
		.frame(width: 900, height: 600)
	}
	
	private var headerView: some View {
		VStack(spacing: 8) {
			HStack {
				Text("Resolve Merge Conflicts")
					.font(.title2)
					.fontWeight(.bold)
				
				Spacer()
				
				Button("Preview Changes") {
					showingPreview = true
				}
				.buttonStyle(.bordered)
				.disabled(conflictResolutions.filter(\.isApproved).isEmpty)
				
				Button("Cancel") {
					dismiss()
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
			}
			
			HStack {
				Text("Base: \(baseFile.lastPathComponent)")
					.font(.caption)
					.foregroundColor(.secondary)
				
				Spacer()
				
				Text("Other: \(otherFile.lastPathComponent)")
					.font(.caption)
					.foregroundColor(.secondary)
			}
			
			HStack {
				Text("\(conflictResolutions.count) conflicts found")
					.font(.caption)
					.foregroundColor(.secondary)
				
				Spacer()
				
				Text("\(conflictResolutions.filter(\.isApproved).count) approved")
					.font(.caption)
					.foregroundColor(.green)
			}
		}
		.padding()
		.background(Color(NSColor.controlBackgroundColor))
	}
	
	private var noConflictsView: some View {
		VStack(spacing: 16) {
			Image(systemName: "checkmark.circle.fill")
				.font(.system(size: 48))
				.foregroundColor(.green)
			
			Text("No Conflicts Found")
				.font(.title2)
				.fontWeight(.semibold)
			
			Text("All records can be merged automatically")
				.font(.body)
				.foregroundColor(.secondary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
	
	private var conflictListView: some View {
		ScrollView {
			LazyVStack(spacing: 12) {
				ForEach(Array(conflictResolutions.enumerated()), id: \.offset) { index, resolution in
					ConflictRowView(
						resolution: $conflictResolutions[index],
						onApprove: { conflictResolutions[index].isApproved = true },
						onReject: { conflictResolutions[index].isApproved = false }
					)
				}
			}
			.padding()
		}
	}
	
	private var footerView: some View {
		HStack {
			Button("Approve All") {
				for index in conflictResolutions.indices {
					conflictResolutions[index].isApproved = true
				}
			}
			.buttonStyle(.bordered)
			
			Button("Reject All") {
				for index in conflictResolutions.indices {
					conflictResolutions[index].isApproved = false
				}
			}
			.buttonStyle(.bordered)
			
			Spacer()
			
			Button("Apply Changes") {
				onComplete(conflictResolutions.filter(\.isApproved))
				dismiss()
			}
			.buttonStyle(.borderedProminent)
			.disabled(conflictResolutions.filter(\.isApproved).isEmpty)
		}
		.padding()
		.background(Color(NSColor.controlBackgroundColor))
	}
}

struct ConflictRowView: View {
	@Binding var resolution: ConflictResolution
	let onApprove: () -> Void
	let onReject: () -> Void
	
	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			// Header with player info
			HStack {
				VStack(alignment: .leading, spacing: 4) {
					// Primary identification
					if let playerName = resolution.conflict.playerName {
						Text(playerName)
							.font(.headline)
							.foregroundColor(.primary)
					} else if let firstName = resolution.conflict.firstName,
					          let lastName = resolution.conflict.lastName {
						Text("\(firstName) \(lastName)")
							.font(.headline)
							.foregroundColor(.primary)
					}
					
					// Additional context information
					HStack(spacing: 12) {
						if let firstName = resolution.conflict.firstName {
							Label(firstName, systemImage: "person")
								.font(.caption)
								.foregroundColor(.secondary)
						}
						
						if let lastName = resolution.conflict.lastName {
							Label(lastName, systemImage: "person.fill")
								.font(.caption)
								.foregroundColor(.secondary)
						}
						
						if let group = resolution.conflict.group {
							Label(group, systemImage: "person.3")
								.font(.caption)
								.foregroundColor(.blue)
						}
					}
					
					Text("ID: \(resolution.conflict.recordID)")
						.font(.caption)
						.foregroundColor(.secondary)
				}
				
				Spacer()
				
				// Conflict type badge
				conflictTypeBadge
				
				// Approval status
				approvalStatusView
			}
			
			// Field comparison
			fieldComparisonView
			
			// Additional context (if available)
			additionalContextView
			
			// Action buttons
			actionButtonsView
		}
		.padding()
		.background(resolution.isApproved ? Color.green.opacity(0.1) : Color(NSColor.controlBackgroundColor))
		.overlay(
			RoundedRectangle(cornerRadius: 8)
				.stroke(resolution.isApproved ? Color.green : Color.gray.opacity(0.3), lineWidth: 1)
		)
		.clipShape(RoundedRectangle(cornerRadius: 8))
	}
	
	private var conflictTypeBadge: some View {
		Text(conflictTypeText)
			.font(.caption2)
			.padding(.horizontal, 6)
			.padding(.vertical, 2)
			.background(conflictTypeColor.opacity(0.2))
			.foregroundColor(conflictTypeColor)
			.clipShape(Capsule())
	}
	
	private var conflictTypeText: String {
		switch resolution.conflict.conflictType {
		case .fieldChange: return "CHANGED"
		case .newRecord: return "NEW"
		case .deleted: return "DELETED"
		}
	}
	
	private var conflictTypeColor: Color {
		switch resolution.conflict.conflictType {
		case .fieldChange: return .orange
		case .newRecord: return .blue
		case .deleted: return .red
		}
	}
	
	private var approvalStatusView: some View {
		HStack(spacing: 4) {
			Image(systemName: resolution.isApproved ? "checkmark.circle.fill" : "circle")
				.foregroundColor(resolution.isApproved ? .green : .gray)
			Text(resolution.isApproved ? "Approved" : "Pending")
				.font(.caption)
				.foregroundColor(resolution.isApproved ? .green : .gray)
		}
	}
	
	private var fieldComparisonView: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Field: \(resolution.conflict.field)")
				.font(.subheadline)
				.fontWeight(.medium)
			
			HStack(spacing: 12) {
				// Base value
				VStack(alignment: .leading, spacing: 4) {
					Text("Current (Base)")
						.font(.caption)
						.foregroundColor(.secondary)
					
					Text(resolution.conflict.baseValue.isEmpty ? "(empty)" : resolution.conflict.baseValue)
						.font(.body)
						.padding(8)
						.frame(maxWidth: .infinity, alignment: .leading)
						.background(resolution.userChoice == .keepBase ? Color.green.opacity(0.2) : Color.gray.opacity(0.1))
						.overlay(
							RoundedRectangle(cornerRadius: 4)
								.stroke(resolution.userChoice == .keepBase ? Color.green : Color.clear, lineWidth: 2)
						)
						.clipShape(RoundedRectangle(cornerRadius: 4))
						.onTapGesture {
							resolution.userChoice = .keepBase
						}
				}
				
				// Arrow
				Image(systemName: "arrow.right")
					.foregroundColor(.secondary)
				
				// Other value
				VStack(alignment: .leading, spacing: 4) {
					Text("Incoming (Other)")
						.font(.caption)
						.foregroundColor(.secondary)
					
					Text(resolution.conflict.otherValue.isEmpty ? "(empty)" : resolution.conflict.otherValue)
						.font(.body)
						.padding(8)
						.frame(maxWidth: .infinity, alignment: .leading)
						.background(resolution.userChoice == .useOther ? Color.green.opacity(0.2) : Color.gray.opacity(0.1))
						.overlay(
							RoundedRectangle(cornerRadius: 4)
								.stroke(resolution.userChoice == .useOther ? Color.green : Color.clear, lineWidth: 2)
						)
						.clipShape(RoundedRectangle(cornerRadius: 4))
						.onTapGesture {
							resolution.userChoice = .useOther
						}
				}
			}
		}
	}
	
	private var actionButtonsView: some View {
		HStack {
			Button("Keep Current") {
				resolution.userChoice = .keepBase
			}
			.buttonStyle(.bordered)
			.controlSize(.small)
			.foregroundColor(resolution.userChoice == .keepBase ? .white : .primary)
			.background(resolution.userChoice == .keepBase ? Color.green : Color.clear)
			
			Button("Use Incoming") {
				resolution.userChoice = .useOther
			}
			.buttonStyle(.bordered)
			.controlSize(.small)
			.foregroundColor(resolution.userChoice == .useOther ? .white : .primary)
			.background(resolution.userChoice == .useOther ? Color.blue : Color.clear)
			
			Spacer()
			
			Button(resolution.isApproved ? "Approved ✓" : "Approve") {
				if resolution.isApproved {
					onReject()
				} else {
					onApprove()
				}
			}
			.buttonStyle(.borderedProminent)
			.controlSize(.small)
			.foregroundColor(.white)
			.background(resolution.isApproved ? Color.green : Color.blue)
		}
	}
	
	private var additionalContextView: some View {
		Group {
			if !contextualFields.isEmpty {
				VStack(alignment: .leading, spacing: 8) {
					Text("Additional Context")
						.font(.caption)
						.fontWeight(.semibold)
						.foregroundColor(.secondary)
					
					LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 2), spacing: 8) {
						ForEach(contextualFields, id: \.key) { field in
							VStack(alignment: .leading, spacing: 2) {
								Text(field.key)
									.font(.caption2)
									.foregroundColor(.secondary)
								Text(field.value)
									.font(.caption)
									.foregroundColor(.primary)
									.lineLimit(1)
							}
						}
					}
				}
				.padding(.top, 8)
				.padding(.horizontal, 8)
				.background(Color.secondary.opacity(0.05))
				.clipShape(RoundedRectangle(cornerRadius: 6))
			}
		}
	}
	
	private var contextualFields: [(key: String, value: String)] {
		let record = resolution.conflict.fullRecord
		let importantFields = ["Email", "Phone", "Address", "School", "Year", "Grade", "Position", "Jersey", "Number", "Notes", "Comments"]
		
		return importantFields.compactMap { field in
			if let value = record[field], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				return (key: field, value: value.trimmingCharacters(in: .whitespacesAndNewlines))
			}
			return nil
		}
	}
}

// MARK: - Column Mapping UI for Roster Mode
struct ColumnMappingView: View {
	@ObservedObject var csvManager: CSVManager
	@Environment(\.dismiss) private var dismiss
	
	var body: some View {
		VStack(spacing: 0) {
			// Header
			HStack {
				Text("Map CSV Columns")
					.font(.title2)
					.fontWeight(.bold)
				
				Spacer()
				
				Button("Cancel") {
					dismiss()
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
						Text("Roster Mode Configuration")
							.font(.headline)
						
						Text("Map your CSV columns to the correct fields. This enables roster-style output like 'Team_PlayerName_' instead of barcode scanning.")
							.font(.body)
							.foregroundColor(.secondary)
					}
					
					// Column mappings
					VStack(alignment: .leading, spacing: 16) {
						Text("Column Mapping")
							.font(.headline)
						
						// Name options
						VStack(alignment: .leading, spacing: 12) {
							Text("Player Name")
								.font(.subheadline)
								.fontWeight(.medium)
							
							// Option 1: Separate first/last name
							VStack(alignment: .leading, spacing: 8) {
								HStack {
									Text("First Name:")
										.frame(width: 100, alignment: .leading)
									Picker("First Name", selection: $csvManager.columnMappings.firstName) {
										Text("None").tag(String?.none)
										ForEach(csvManager.csvHeaders, id: \.self) { header in
											Text(header).tag(header as String?)
										}
									}
									.frame(maxWidth: .infinity)
								}
								
								HStack {
									Text("Last Name:")
										.frame(width: 100, alignment: .leading)
									Picker("Last Name", selection: $csvManager.columnMappings.lastName) {
										Text("None").tag(String?.none)
										ForEach(csvManager.csvHeaders, id: \.self) { header in
											Text(header).tag(header as String?)
										}
									}
									.frame(maxWidth: .infinity)
								}
							}
							
							Text("OR")
								.font(.caption)
								.foregroundColor(.secondary)
								.padding(.vertical, 4)
							
							// Option 2: Combined name field
							HStack {
								Text("Full Name:")
									.frame(width: 100, alignment: .leading)
								Picker("Full Name", selection: $csvManager.columnMappings.fullName) {
									Text("None").tag(String?.none)
									ForEach(csvManager.csvHeaders, id: \.self) { header in
										Text(header).tag(header as String?)
									}
								}
								.frame(maxWidth: .infinity)
							}
						}
						.padding()
						.background(Color(NSColor.controlBackgroundColor).opacity(0.5))
						.clipShape(RoundedRectangle(cornerRadius: 8))
						
						// Team mapping
						VStack(alignment: .leading, spacing: 8) {
							Text("Team/Group")
								.font(.subheadline)
								.fontWeight(.medium)
							
							HStack {
								Text("Team:")
									.frame(width: 100, alignment: .leading)
								Picker("Team", selection: $csvManager.columnMappings.team) {
									Text("None").tag(String?.none)
									ForEach(csvManager.csvHeaders, id: \.self) { header in
										Text(header).tag(header as String?)
									}
								}
								.frame(maxWidth: .infinity)
							}
						}
						.padding()
						.background(Color(NSColor.controlBackgroundColor).opacity(0.5))
						.clipShape(RoundedRectangle(cornerRadius: 8))
						
						// Preview
						if csvManager.columnMappings.isValid && !csvManager.players.isEmpty {
							VStack(alignment: .leading, spacing: 8) {
								Text("Preview Output")
									.font(.subheadline)
									.fontWeight(.medium)
								
								if let samplePlayer = csvManager.players.first {
									let previewOutput = csvManager.generateRosterOutput(for: samplePlayer)
									Text(previewOutput)
										.font(.system(.body, design: .monospaced))
										.padding()
										.background(Color.accentColor.opacity(0.1))
										.clipShape(RoundedRectangle(cornerRadius: 6))
								}
							}
						}
						
						// Validation message
						if !csvManager.columnMappings.isValid {
							HStack(spacing: 8) {
								Image(systemName: "exclamationmark.triangle.fill")
									.foregroundColor(.orange)
								Text("Please map both a name field and a team field to enable roster mode.")
									.font(.caption)
									.foregroundColor(.orange)
							}
						}
					}
					
					// Action buttons
					HStack {
						Spacer()
						
						Button("Save Configuration") {
							dismiss()
						}
						.buttonStyle(.borderedProminent)
						.disabled(!csvManager.columnMappings.isValid)
					}
				}
				.padding()
			}
		}
		.frame(width: 500, height: 600)
	}
}



