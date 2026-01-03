//
//  ContentView.swift
//  Names List
//
//  Created by 207 Photo on 8/3/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppStateManager()
    @State private var showingFolderPicker = false
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    
    var body: some View {
        Group {
            if !appState.isJobFolderSelected {
                FolderSelectionView(showingPicker: $showingFolderPicker)
            } else {
                MainAppView()
                    .environmentObject(appState)
            }
        }
        // Removed legacy photographer setup sheet; all configuration is in Settings now
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    appState.selectJobFolder(url)
                    // First-run guided help after selecting folder
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        appState.checkPhotographerSetup()
                    }
                }
            case .failure(let error):
                Logger.error("Error selecting folder: \(error)")
            }
        }
    }
}

struct MainAppView: View {
    @EnvironmentObject var appState: AppStateManager
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @State private var showingSettings = false
    @State private var windowWidth: CGFloat = DesignSystem.narrowWindowWidth
    
    private var isNarrowLayout: Bool {
        DesignSystem.isNarrowLayout(width: windowWidth)
    }
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                UpdateBannerView()
                
                // Header with folder info and mode switcher
                VStack(spacing: isNarrowLayout ? DesignSystem.narrowSpacing : DesignSystem.spacing) {
                    if let jobFolder = appState.jobFolderURL {
                        FolderHeaderView(
                            folderName: jobFolder.lastPathComponent,
                            onChangeTapped: {
                                appState.isJobFolderSelected = false
                            },
                            onSettingsTapped: {
                                showingSettings = true
                            }
                        )
                        .environmentObject(appState)
                        .frame(height: isNarrowLayout ? 36 : (horizontalSizeClass == .compact ? 40 : 44))
                        .padding(.horizontal, DesignSystem.adaptivePadding(for: windowWidth))
                        .padding(.top, isNarrowLayout ? DesignSystem.microSpacing : (horizontalSizeClass == .compact ? 8 : 12))
                    }
                
                    // Mode switcher
                    ModernCard {
                        HStack(spacing: isNarrowLayout ? DesignSystem.microSpacing : (horizontalSizeClass == .compact ? 8 : 12)) {
                            ForEach(AppMode.allCases, id: \.self) { mode in
                                Button(action: { appState.currentMode = mode }) {
								HStack(spacing: isNarrowLayout ? 2 : (horizontalSizeClass == .compact ? 4 : 6)) {
									Image(systemName: mode == .csv ? "list.clipboard" : "person.badge.plus")
										.font(.system(size: isNarrowLayout ? DesignSystem.IconSizes.narrowSmall : DesignSystem.IconSizes.medium))
                                        
                                        if !isNarrowLayout && horizontalSizeClass != .compact {
                                            Text(mode.rawValue)
                                                .font(.system(size: DesignSystem.FontSizes.callout))
                                                .fontWeight(.semibold)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, isNarrowLayout ? DesignSystem.microSpacing : (horizontalSizeClass == .compact ? 6 : 8))
                                    .background(
                                        Group {
                                            if appState.currentMode == mode {
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
                                    .foregroundColor(appState.currentMode == mode ? .white : .primary)
                                    .clipShape(RoundedRectangle(
                                        cornerRadius: isNarrowLayout ? DesignSystem.compactCornerRadius : 8,
                                        style: .continuous
                                    ))
                                }
                                .buttonStyle(.plain)
                                .help(mode.rawValue)
                            }
                        }
                        .padding(DesignSystem.adaptivePadding(for: windowWidth))
                    }
                    .padding(.horizontal, DesignSystem.adaptivePadding(for: windowWidth))
                }
                
                // Mode content
                Group {
                    switch appState.currentMode {
                    case .csv:
                        CSVModeView()
                    case .manual:
                        ManualModeView()
                    }
                }
                .environmentObject(appState)
            }
            .onAppear {
                UpdateService.shared.checkForUpdates()
                windowWidth = geometry.size.width
            }
            .onChange(of: geometry.size.width) { _, newWidth in
                windowWidth = newWidth
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(appState)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NamesList.OpenSettings"))) { _ in
            showingSettings = true
        }
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @EnvironmentObject var appState: AppStateManager
    @State private var photographerID = ""
    @Environment(\.dismiss) private var dismiss
    @State private var loggingEnabled = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Collaboration Mode (per-job)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Collaboration Mode")
                            .font(.headline)
                        Picker("Collaboration Mode", selection: Binding(
                            get: { appState.collaborationMode },
                            set: { mode in appState.setCollaborationMode(mode) }
                        )) {
                            Text("Solo").tag(CollaborationMode.solo)
                            Text("Team").tag(CollaborationMode.team)
                        }
                        .pickerStyle(.segmented)
                        Text(appState.collaborationMode == .solo ? "Work directly on the original photo lists." : "Creates and uses individual photo lists per photographer to avoid conflicts.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Photographer ID Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Photographer Identity")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Photographer ID")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            HStack {
                                TextField("Enter photographer ID", text: $photographerID)
                                    .textFieldStyle(.roundedBorder)
                                
                                Button("Update") {
                                    appState.setPhotographerID(photographerID)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(photographerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            
                            Text("Current ID: \(appState.photographerID)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Text("This ID is used to track which photos you take and prevent conflicts when working with multiple photographers.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                Divider()

                // My CSV Copy Management
                VStack(alignment: .leading, spacing: 12) {
                    Text("My CSV Copy")
                        .font(.headline)

                    if let current = appState.detectedCSVFile {
                        let isCopy = appState.isAnyPhotographerCSV(current)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Current File: \(current.lastPathComponent)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(isCopy ? "Using your photographer copy" : "Using original list")
                                .font(.caption2)
                                .foregroundColor(isCopy ? .green : .orange)
                        }

                        HStack(spacing: 8) {
                            Button("Use My Copy") {
                                if let copy = appState.createPhotographerCSVCopy(from: current) {
                                    appState.selectCSVFile(copy)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(appState.collaborationMode != .team || appState.photographerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            Button("Create Team Copies") {
                                let team = appState.parseTeamIDs(appState.teamPhotographerIDsStorage)
                                _ = appState.createPhotographerCSVCopies(for: [appState.photographerID] + team)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(appState.collaborationMode != .team)
                        }
                    } else {
                        Text("No CSV selected yet")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                // Debug Logging
                VStack(alignment: .leading, spacing: 8) {
                    Text("Debug Logging")
                        .font(.headline)
                    Toggle("Enable verbose logging", isOn: Binding(
                        get: { loggingEnabled },
                        set: { newValue in
                            loggingEnabled = newValue
                            Logger.setEnabled(newValue)
                        }
                    ))
                    .toggleStyle(.switch)
                    .help("When enabled, diagnostic messages will appear in the console.")
                }

                    Divider()

                    // Team Members (only relevant when in Team mode)
                    if appState.collaborationMode == .team {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Team Members")
                                .font(.headline)
                            TeamMemberManagementView()
                                .environmentObject(appState)
                        }
                    }
                    
                    Divider()
                    
                    // Team Photography Tips
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Team Photography Tips")
                            .font(.headline)
                        
                        Text("When working with multiple photographers:")
                            .font(.subheadline)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("• Each photographer should have a unique ID")
                            Text("• Photo lists track who photographed each subject")
                            Text("• Manual mode can split photo numbers to prevent conflicts")
                            Text("• Use the Merge feature to combine work from multiple photographers")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
        }
        .frame(width: 500, height: 400)
        .onAppear {
            photographerID = appState.photographerID
            loggingEnabled = UserDefaults.standard.bool(forKey: "NAMESLIST_LOGGING")
        }
    }
}

// MARK: - Team Member Management View
struct TeamMemberManagementView: View {
    @EnvironmentObject var appState: AppStateManager
    @State private var teamIDs: [String] = [""]
    @State private var showingAddMember = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Team Members")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
                
                Button("Add Member") {
                    teamIDs.append("")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            
            // Show existing team members
            let existingTeamIDs = appState.parseTeamIDs(appState.teamPhotographerIDsStorage)
            if !existingTeamIDs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(existingTeamIDs, id: \.self) { memberID in
                        HStack {
                            Text(memberID)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            
                            Spacer()
                            
                            Button("Remove") {
                                var current = appState.parseTeamIDs(appState.teamPhotographerIDsStorage)
                                current.removeAll { $0 == memberID }
                                appState.storeTeamIDs(current)
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.mini)
                            .foregroundColor(.red)
                        }
                    }
                }
            }
            
            // Add new team members
            if teamIDs.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) || teamIDs.count > 1 {
                VStack(spacing: 6) {
                    ForEach(teamIDs.indices, id: \.self) { idx in
                        HStack {
                            TextField("Photographer ID", text: Binding(
                                get: { teamIDs[idx] },
                                set: { teamIDs[idx] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            
                            Button("Remove") {
                                if teamIDs.count > 1 {
                                    teamIDs.remove(at: idx)
                                } else {
                                    teamIDs[idx] = ""
                                }
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.mini)
                            .foregroundColor(.red)
                        }
                    }
                    
                    Button("Save Team Members") {
                        let newIDs = teamIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        if !newIDs.isEmpty {
                            let existing = appState.parseTeamIDs(appState.teamPhotographerIDsStorage)
                            appState.storeTeamIDs(existing + newIDs)
                            
                            // Create CSV copies for new team members
                            let created = appState.createPhotographerCSVCopies(for: newIDs)
                            if !created.isEmpty {
                                Logger.log("Created photo lists for new team members: \(created.map { $0.lastPathComponent })")
                            }
                            
                            // Reset the input fields
                            teamIDs = [""]
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(teamIDs.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            // Initialize with existing team IDs if any
            let existing = appState.parseTeamIDs(appState.teamPhotographerIDsStorage)
            if !existing.isEmpty && teamIDs == [""] {
                teamIDs = [""]
            }
        }
    }
}

// MARK: - Smart Detection Card
struct SmartDetectionCard: View {
    let detection: (shouldUseTeamMode: Bool, detectedPhotographers: [String], confidence: Float)
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "brain.head.profile")
                    .foregroundColor(.blue)
                    .font(.title2)
                
                Text("Smart Detection")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Text("\(Int(detection.confidence * 100))% confident")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(Capsule())
            }
            
            if detection.shouldUseTeamMode {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Team Photography Detected")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.blue)
                    
                    Text("Found photo lists for: \(detection.detectedPhotographers.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("💡 Consider enabling Team Mode to work with your colleagues.")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Solo Photography Detected")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.green)
                    
                    Text("Only original photo lists found - looks like you're working alone.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("💡 Solo Mode will work great for your workflow.")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(detection.shouldUseTeamMode ? Color.blue.opacity(0.3) : Color.green.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Photographer Setup View
struct PhotographerSetupView: View {
    @EnvironmentObject var appState: AppStateManager
    @State private var photographerID = ""
    @State private var smartDetection: (shouldUseTeamMode: Bool, detectedPhotographers: [String], confidence: Float) = (false, [], 0.0)
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 32) {
            // Header
            VStack(spacing: 16) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.accentColor)
                
                Text("Who's Taking Photos?")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("This ID helps organize your photos and prevents conflicts when working with others.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            // Smart Detection Section
            if smartDetection.confidence > 0.5 {
                SmartDetectionCard(detection: smartDetection)
            }
            
            // Input Section
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your Photographer ID")
                        .font(.headline)
                    
                    TextField("Enter your ID (e.g., 'A', 'John', 'Photographer1')", text: $photographerID)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                        .padding(.vertical, 4)
                    
                    Text("Use a short, unique identifier like your initials or name.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(20)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            
            // Action Buttons
            VStack(spacing: 12) {
                Button("Continue") {
                    let trimmedID = photographerID.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedID.isEmpty {
                        appState.setPhotographerID(trimmedID)
                    } else {
                        // Set a default ID if user didn't enter one
                        appState.setPhotographerID("Photographer")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                
                Button("I'll Set This Up Later") {
                    appState.setPhotographerID("TempUser")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            
            // Footer
            Text("You can change this anytime in Settings")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(40)
        .frame(width: 450)
        .onAppear {
            // Pre-fill with existing photographer ID if available
            photographerID = appState.photographerID == "SingleUser" || appState.photographerID == "TempUser" ? "" : appState.photographerID
            
            // Run smart detection
            smartDetection = appState.detectPhotographerMode()
        }
    }
}

#Preview {
    ContentView()
}
