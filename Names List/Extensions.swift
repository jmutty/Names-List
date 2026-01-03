import Foundation

// MARK: - String Extensions
extension String {
	func trim() -> String {
		self.trimmingCharacters(in: .whitespacesAndNewlines)
	}
}

// MARK: - AppleScript Execution
struct AppleScriptExecutor {
	static func executeScript(named scriptName: String) {
		guard let realHomeDirectory = getRealHomeDirectory() else {
			Logger.error("Could not determine the user's home directory.")
			return
		}
		let scriptsDirectory = realHomeDirectory.appendingPathComponent("Library/Scripts/Capture One Scripts")
		let scriptURL = scriptsDirectory.appendingPathComponent(scriptName).appendingPathExtension("scpt")

		guard FileManager.default.fileExists(atPath: scriptURL.path) else {
			Logger.warn("AppleScript not found at: \(scriptURL.path)")
			return
		}

		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
		process.arguments = [scriptURL.path]

		do {
			try process.run()
			Logger.log("Executed AppleScript: \(scriptName)")
		} catch {
			Logger.error("Failed to execute AppleScript '\(scriptName)': \(error.localizedDescription)")
		}
	}

	private static func getRealHomeDirectory() -> URL? {
		let pw = getpwuid(getuid())
		if let home = pw?.pointee.pw_dir {
			let homePath = FileManager.default.string(withFileSystemRepresentation: home, length: Int(strlen(home)))
			return URL(fileURLWithPath: homePath)
		}
		return nil
	}

	// Attempt to convert legacy XLS to CSV using Numbers via AppleScript
	static func convertXLSToCSVUsingNumbers(xlsURL: URL, outputURL: URL) -> Bool {
		let script = """
		tell application \"Numbers\"
			activate
			set doc to open POSIX file \"\(xlsURL.path)\"
			tell doc
				export to POSIX file \"\(outputURL.path)\" as CSV
				close saving no
			end tell
		end tell
		"""
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
		process.arguments = ["-e", script]
		do {
			try process.run()
			process.waitUntilExit()
			return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: outputURL.path)
		} catch {
			Logger.error("Failed to run Numbers conversion: \(error)")
			return false
		}
	}
}


