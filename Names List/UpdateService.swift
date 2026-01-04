import Foundation
import AppKit

struct GitHubRelease: Codable {
    let tagName: String
    let assets: [GitHubAsset]
    let htmlUrl: String
    let body: String
    
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
        case htmlUrl = "html_url"
        case body
    }
}

struct GitHubAsset: Codable {
    let url: String
    let browserDownloadUrl: String
    let name: String
    
    enum CodingKeys: String, CodingKey {
        case url
        case browserDownloadUrl = "browser_download_url"
        case name
    }
}

class UpdateService: NSObject, ObservableObject, URLSessionTaskDelegate {
    static let shared = UpdateService()
    
    @Published var isUpdateAvailable = false
    @Published var latestRelease: GitHubRelease?
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var updateError: String?
    
    private let fileManager = FileManager.default
    
    struct Config {
        static let repoOwner = "jmutty"
        static let repoName = "Names-List"
    }
    
    func checkForUpdates() {
        let urlString = "https://api.github.com/repos/\(Config.repoOwner)/\(Config.repoName)/releases/latest"
        guard let url = URL(string: urlString) else { return }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(Secrets.GitHub.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            guard let data = data, error == nil else {
                let errorMessage = error?.localizedDescription ?? "Unknown error"
                print("Update check failed: \(errorMessage)")
                DispatchQueue.main.async {
                    self.updateError = "Check failed: \(errorMessage)"
                }
                return
            }
            
            do {
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                DispatchQueue.main.async {
                    self.compareVersions(release: release)
                }
            } catch {
                // Debug: Print the raw response
                if let responseString = String(data: data, encoding: .utf8) {
                    print("GitHub API Response: \(responseString)")
                }
                print("Failed to decode release info: \(error)")
                DispatchQueue.main.async {
                    self.updateError = "Failed to parse release info. Check console for details."
                }
            }
        }
        task.resume()
    }
    
    private func compareVersions(release: GitHubRelease) {
        guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return }
        
        // Remove 'v' prefix if present for comparison
        let cleanTag = release.tagName.replacingOccurrences(of: "v", with: "")
        let cleanCurrent = currentVersion.replacingOccurrences(of: "v", with: "")
        
        if cleanTag.compare(cleanCurrent, options: .numeric) == .orderedDescending {
            self.latestRelease = release
            self.isUpdateAvailable = true
        }
    }
    
    func downloadAndInstall() {
        guard let release = latestRelease,
              let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            print("No suitable asset found for update")
            return
        }
        
        guard let url = URL(string: asset.url) else {
             self.updateError = "Invalid download URL"
             return
        }
        
        isDownloading = true
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(Secrets.GitHub.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        
        let task = session.downloadTask(with: request) { [weak self] localUrl, response, error in
            guard let self = self else { return }
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📥 Download Status: \(httpResponse.statusCode)")
            }
            
            guard let localUrl = localUrl, error == nil else {
                let errorMsg = error?.localizedDescription ?? "Unknown download error"
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.updateError = "Download failed: \(errorMsg)"
                    print("Download failed: \(errorMsg)")
                }
                return
            }
            
            // Move to temporary location with correct name
            let tempDir = self.fileManager.temporaryDirectory
            let zipTarget = tempDir.appendingPathComponent(asset.name)
            
            do {
                if self.fileManager.fileExists(atPath: zipTarget.path) {
                    try self.fileManager.removeItem(at: zipTarget)
                }
                try self.fileManager.moveItem(at: localUrl, to: zipTarget)
                
                print("✅ Downloaded to: \(zipTarget.path)")
                // Now install it
                self.installUpdate(zipPath: zipTarget.path)
            } catch {
                print("File handling error: \(error)")
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.updateError = "File system error: \(error.localizedDescription)"
                }
            }
        }
        task.resume()
    }
    
    // MARK: - URLSessionTaskDelegate
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // When redirected (e.g. to S3), we MUST STRIP the Authorization header
        var newRequest = request
        newRequest.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(newRequest)
    }
    
    private func installUpdate(zipPath: String) {
        let appBundlePath = Bundle.main.bundlePath
        let appName = (appBundlePath as NSString).lastPathComponent
        let appParentDir = (appBundlePath as NSString).deletingLastPathComponent
        let unzipDir = (zipPath as NSString).deletingLastPathComponent
        
        let script = """
        sleep 3
        
        cd "\(unzipDir)"
        if /usr/bin/unzip -o "\(zipPath)" > /dev/null 2>&1; then
            rm -rf "\(appBundlePath)" > /dev/null 2>&1
            
            if mv "\(appName)" "\(appParentDir)/" > /dev/null 2>&1; then
                xattr -cr "\(appBundlePath)" > /dev/null 2>&1
                open "\(appBundlePath)" > /dev/null 2>&1
            fi
        fi
        """
        
        let process = Process()
        process.launchPath = "/bin/sh"
        process.arguments = ["-c", script]
        
        do {
            try process.run()
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        } catch {
            print("Failed to run update script: \(error)")
            DispatchQueue.main.async {
                self.isDownloading = false
                self.updateError = "Script execution failed: \(error.localizedDescription)"
            }
        }
    }
}
