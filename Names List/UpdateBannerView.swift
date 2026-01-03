import SwiftUI

struct UpdateBannerView: View {
    @ObservedObject var updateService = UpdateService.shared
    
    var body: some View {
        if updateService.isUpdateAvailable {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.white)
                    .font(.title2)
                
                VStack(alignment: .leading) {
                    Text("New Version Available: \(updateService.latestRelease?.tagName ?? "")")
                        .font(.headline)
                        .foregroundColor(.white)
                    if let body = updateService.latestRelease?.body {
                        Text(body.prefix(100))
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                if updateService.isDownloading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                    Text("Downloading & Restarting...")
                        .font(.subheadline)
                        .foregroundColor(.white)
                } else {
                    Button(action: {
                        updateService.downloadAndInstall()
                    }) {
                        Text("Update & Restart")
                            .fontWeight(.bold)
                            .foregroundColor(DesignSystem.Colors.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white)
                            .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding()
            .background(DesignSystem.Colors.primary)
            .cornerRadius(10)
            .shadow(radius: 4)
            .padding()
            .transition(.move(edge: .top))
        }
    }
}
