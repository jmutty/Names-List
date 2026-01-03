import Foundation
import SwiftUI

// MARK: - Logger
struct Logger {
	private static var isEnabled: Bool {
		if let env = ProcessInfo.processInfo.environment["NAMESLIST_LOGGING"], env == "1" { return true }
		return UserDefaults.standard.bool(forKey: "NAMESLIST_LOGGING")
	}

	static func setEnabled(_ enabled: Bool) {
		UserDefaults.standard.set(enabled, forKey: "NAMESLIST_LOGGING")
	}

	static func log(_ message: @autoclosure () -> String) {
		guard isEnabled else { return }
		print("ℹ️ " + message())
	}

	static func warn(_ message: @autoclosure () -> String) {
		guard isEnabled else { return }
		print("⚠️ " + message())
	}

	static func error(_ message: @autoclosure () -> String) {
		print("❌ " + message())
	}
}

// MARK: - Header Aliases
struct HeaderAliases {
	static let firstName: [String] = [
		"Student firstname",
		"First Name",
		"Firstname",
		"First",
		"Athlete First Name",
		"Athlete First",
		"Athlete FirstName",
		"Given Name"
	]
	static let lastName: [String] = [
		"Student lastname",
		"Last Name",
		"Lastname",
		"Last",
		"Athlete Last Name",
		"Athlete Last",
		"Athlete LastName",
		"Surname",
		"Family Name"
	]
	static let group: [String] = ["Group", "Team", "Class", "Homeroom"]
	static let photo: [String] = ["Photo", "Has Photo"]
	static let reference: [String] = [
		"Reference",
		"Photographed",
		"Photograph",
		"Captured",
		"Taken",
		"Shot",
		"Complete",
		"Completed",
		"Done"
	]
	static let barcodeExact: [String] = ["Barcode", "Barcode (1)", "Child ID", "Student ID", "ID"]
	static let barcodeContains: [String] = ["barcode", "id"]
}

// MARK: - CSV Service
struct CSVService {
	/// Parse common boolean-ish values used in CSVs
	static func parseBoolean(_ raw: String) -> Bool {
		let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		if v.isEmpty { return false }
		if ["yes", "y", "true", "t", "1", "done", "x", "✓", "✔", "photographed", "photo", "captured", "taken", "shot", "complete", "completed"].contains(v) {
			return true
		}
		if let n = Int(v) { return n != 0 }
		return false
	}

	static func splitRespectingQuotes(_ line: String, by delimiter: String) -> [String] {
		var result: [String] = []
		var current = ""
		var inQuotes = false
		for ch in line {
			if ch == "\"" {
				inQuotes.toggle()
				current.append(ch)
			} else if String(ch) == delimiter && !inQuotes {
				result.append(current)
				current = ""
			} else {
				current.append(ch)
			}
		}
		result.append(current)
		return result
	}

	static func cleanHeader(_ raw: String) -> String {
		raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
	}

	static func findHeaderIndex(in headers: [String], equalsAny candidates: [String]) -> Int? {
		return headers.firstIndex { h in candidates.contains { c in h.caseInsensitiveCompare(c) == .orderedSame } }
	}
	
	static func findHeaderIndexWithPriority(in headers: [String], prioritizedCandidates: [String]) -> Int? {
		// Check each candidate in priority order, not CSV order
		for candidate in prioritizedCandidates {
			if let index = headers.firstIndex(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
				return index
			}
		}
		return nil
	}

	static func findHeaderIndex(in headers: [String], containsAny substrings: [String]) -> Int? {
		return headers.firstIndex { h in
			let lower = h.lowercased()
			return substrings.contains { lower.contains($0.lowercased()) }
		}
	}
}


// MARK: - Barcode Generator
struct BarcodeGenerator {
    /// Generates a unique 15-digit numeric barcode (no leading zeros) not present in `existing`.
    static func generateUnique15Digit(existing: Set<String>) -> String {
        let lower: UInt64 = 100_000_000_000_000
        let upper: UInt64 = 999_999_999_999_999
        var code = ""
        repeat {
            code = String(UInt64.random(in: lower...upper))
        } while existing.contains(code)
        return code
    }
}



