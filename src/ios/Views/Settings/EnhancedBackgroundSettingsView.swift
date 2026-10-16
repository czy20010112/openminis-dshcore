import AVFoundation
import SwiftUI

struct EnhancedBackgroundSettingsView: View {
    @ObservedObject private var keepAlive = BackgroundKeepAliveManager.shared
    // [T-background-boost] The preset store. A preset writes the individual switches
    // below it, so this view has to observe it to stay in sync when the interruption
    // banner's one-tap action changes the preset from outside the screen.
    @ObservedObject private var boost = BackgroundBoost.shared
    @ObservedObject private var deepLink = DeepLinkCoordinator.shared
    // Owns the preview synthesizer and routes its audio-session intent through
    // AudioSessionCoordinator (a SwiftUI struct can't be an AVSpeechSynthesizer
    // delegate, so the lifecycle lives in this reference-type helper).
    // [T-audio-session-preview]
    @StateObject private var previewPlayer = SpeechPreviewPlayer()
    /// [T-settings-focus-highlight] Focus directives consumed once from the
    /// deep-link coordinator (parsing lives in DeepLinkCoordinator). Each row
    /// asks `DeepLinkCoordinator.shouldFocus(_:current:in:)` whether to show its
    /// yellow border; because it reads the live toggle value the border clears
    /// reactively once the row reaches the expected state.
    @State private var focus: [String: Bool?] = [:]

    private func shouldFocus(_ key: String, current: Bool) -> Bool {
        DeepLinkCoordinator.shouldFocus(key, current: current, in: focus)
    }

    var body: some View {
        List {
            // [T-background-boost] The whole keep-alive configuration, chosen in
            // advance. Sits at the top of the page because it is the only group that
            // can make every row below it moot: a preset sets those switches for you.
            // Reachable proactively (Settings -> Permissions -> Background, and
            // minis://settings/background) and from the interruption banner's
            // one-tap action, which is what stopped this screen being reachable only
            // AFTER a task had already been killed.
            Section {
                Picker("Mode", selection: $boost.mode) {
                    ForEach(BackgroundBoostMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .focusHighlight(shouldFocus("backgroundBoostRecommended",
                                            current: boost.mode == BackgroundBoostMode.recommended))

                if boost.mode != .off {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(boost.mode.summary)
                            .font(AppFont.sw(13, weight: .regular, category: .body))
                            .foregroundColor(.secondary)
                        Text(boost.mode.risk)
                            .font(AppFont.sw(12, weight: .regular, category: .ui))
                            .foregroundColor(.orange)
                    }
                }

                Toggle("Re-apply on Launch", isOn: $boost.armOnLaunch)

                if boost.mode != BackgroundBoostMode.recommended {
                    Button("Use Recommended (\(BackgroundBoostMode.recommended.title))") {
                        boost.applyRecommended(reason: "settingsButton")
                    }
                }

                NavigationLink {
                    BackgroundBoostStatusView()
                } label: {
                    Label("Check Current Effect", systemImage: "waveform.path.ecg")
                }
            } header: {
                Text("Background Boost")
            } footer: {
                Text("Sets every background switch on this page in one step and re-applies the preset at every launch, so the configuration is in force before a task is ever interrupted. iOS shows no permission prompt for background audio or for Live Activities; location is the only leg that asks, and picking a preset that uses it asks for you. \"Custom\" writes nothing and leaves the switches exactly as they are. Open \"Check Current Effect\" to see what is configured, what is running right now, and what the installed build actually declares.")
            }

            Section {
                Toggle("Enhanced Background Execution", isOn: $keepAlive.enhancedBackgroundEnabled)
                    .focusHighlight(shouldFocus("enhancedBackgroundExecution", current: keepAlive.enhancedBackgroundEnabled))
            } footer: {
                Text("Keeps agent tasks running when the app is in the background. Shows progress via Live Activity on the Lock Screen and Dynamic Island. Also turns on Background Speak so text-to-speech narration keeps playing.")
            }

            // [T-ipad16-liveactivity-restore-crash] Hidden on devices where
            // Live Activities don't exist (iPad < iPadOS 17, iOS-on-Mac,
            // failed runtime probe) — the switch would do nothing there, and
            // GH#82 showed this device class is exactly where ActivityKit
            // must never be touched.
            if AgentLiveActivityManager.isLiveActivitySupported {
                Section {
                    Toggle("Live Activity", isOn: $keepAlive.liveActivityEnabled)
                        .focusHighlight(shouldFocus("liveActivityEnabled", current: keepAlive.liveActivityEnabled))
                } footer: {
                    // [T-keepalive-survival-tier] Nudge: without a keep-alive
                    // leg the app suspends ~30s after backgrounding and the
                    // Live Activity freezes; the location heartbeat is what
                    // keeps it refreshing.
                    Text("Show agent task progress on the Lock Screen and in the Dynamic Island. Turning this off also removes the currently displayed Live Activity. Tip: enable Location Tracking below so the Live Activity keeps refreshing while the app stays in the background — without it, updates pause about 30 seconds after you leave the app.")
                }
            }

            Section {
                Toggle("Task Notifications", isOn: $keepAlive.backgroundNotificationsEnabled)
            } footer: {
                Text("Show local notifications when agent tasks start and complete, including tasks triggered by Shortcuts.")
            }

            // [T-ios-live-activity-privacy-mode] Sits right after the two
            // surfaces it governs (Live Activity above, Task Notifications
            // directly above), since it redacts both.
            Section {
                // Display name only — the persisted key stays
                // `liveActivityPrivacyMode` so existing installs keep their setting.
                Toggle("Task Status Privacy", isOn: $keepAlive.liveActivityPrivacyMode)
            } footer: {
                Text("Hide session content on the Lock Screen, in the Dynamic Island and in notifications. Only the number of completed tasks and the elapsed time are shown — no session titles, tool status or reply content.")
            }

            Section {
                Toggle("Background Speak", isOn: $keepAlive.backgroundSpeakEnabled)
                    .focusHighlight(shouldFocus("backgroundSpeakEnabled", current: keepAlive.backgroundSpeakEnabled))
            } footer: {
                Text("Enables background audio playback for text-to-speech narration and music/audio playback while the app is in the background.")
            }

            // MARK: - Speech Settings

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Rate")
                        Spacer()
                        Text(String(format: "%.2f", keepAlive.speechRate))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $keepAlive.speechRate,
                        in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate,
                        step: 0.05
                    )
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Pitch")
                        Spacer()
                        Text(String(format: "%.1f", keepAlive.speechPitch))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $keepAlive.speechPitch, in: 0.5...2.0, step: 0.1)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Volume")
                        Spacer()
                        Text(String(format: "%.1f", keepAlive.speechVolume))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $keepAlive.speechVolume, in: 0.0...1.0, step: 0.1)
                }
            } header: {
                Text("Speech")
            }

            Section {
                voicePicker(label: "English Voice", language: "en", selection: $keepAlive.speechVoiceEn)
                voicePicker(label: "中文语音", language: "zh", selection: $keepAlive.speechVoiceZh)
            } header: {
                Text("Voice")
            } footer: {
                Text("Choose a specific voice for each language. Download more voices in Settings > Accessibility > Spoken Content > Voices.")
            }

            Section {
                Button("Reset to Defaults") {
                    keepAlive.resetSpeechSettings()
                }

                Button("Preview") {
                    previewSpeech()
                }
            }

            // MARK: - Other Settings

            Section {
                Toggle("Location Tracking", isOn: $keepAlive.locationTrackingEnabled)
                    .focusHighlight(shouldFocus("locationTrackingEnabled", current: keepAlive.locationTrackingEnabled))
                    .onChange(of: keepAlive.locationTrackingEnabled) { enabled in
                        if enabled && keepAlive.locationAuthStatus == .notDetermined {
                            keepAlive.requestLocationPermission()
                        }
                    }
            } footer: {
                Text("Lets the agent keep working in the background and keeps the task Live Activity refreshing in real time. Uses coarse, low-accuracy location only as a background heartbeat — it does not track or store your precise location.")
            }

            Section {
                // [T-keepalive-survival-tier] Shows the app's background
                // SURVIVAL CAPABILITY tier, not whether a task is running:
                // ~30s system grace by default, long-lived when the location
                // heartbeat and/or background audio leg is enabled.
                HStack {
                    Text("Keep-Alive")
                    Spacer()
                    switch keepAlive.survivalTier {
                    case .short:
                        Text("Short-Lived (~30s)")
                            .foregroundColor(.secondary)
                    case .extended(let location, let audio):
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.green)
                                .frame(width: 8, height: 8)
                            Text(extendedTierLabel(location: location, audio: audio))
                                .foregroundColor(.green)
                        }
                    }
                }

                HStack {
                    Text("Location Permission")
                    Spacer()
                    Text(locationStatusText)
                        .foregroundColor(locationStatusColor)
                }
            } header: {
                Text("Status")
            } footer: {
                Text("How long the app can keep working after moving to the background. Without any keep-alive mechanism, iOS suspends apps after roughly 30 seconds; enabling Location Tracking (and granting location permission) or Background Speak extends this for the duration of a task.")
            }
        }
        .navigationTitle("Background")
        .navigationBarTitleDisplayMode(.inline)
        // [T-background-boost] If the user changes a switch by hand, re-derive the
        // preset from the switches: the Mode row keeps telling the truth, and the
        // saved preset cannot re-impose itself over that change on the next launch.
        // Inference only ever returns a preset whose legs match the switches exactly,
        // so the apply this triggers is a no-op.
        .onChange(of: keepAlive.enhancedBackgroundEnabled) { _ in
            boost.syncModeFromCurrentConfiguration()
        }
        .onChange(of: keepAlive.backgroundSpeakEnabled) { _ in
            boost.syncModeFromCurrentConfiguration()
        }
        .onChange(of: keepAlive.locationTrackingEnabled) { _ in
            boost.syncModeFromCurrentConfiguration()
        }
        .onChange(of: keepAlive.liveActivityEnabled) { _ in
            boost.syncModeFromCurrentConfiguration()
        }
        .onAppear {
            // [T-settings-focus-highlight] One-shot consume of the parsed focus
            // directives (parsing + decision live in DeepLinkCoordinator). Held
            // locally so a later plain navigation doesn't re-arm the borders.
            let consumed = deepLink.consumeFocus()
            if !consumed.isEmpty { focus = consumed }
            // [T-ios-scene-create-watchdog-corelocation] This screen shows the
            // location-permission row, and the status is no longer read in the
            // manager's init (that IPC is what tripped the scene-create
            // watchdog). Refresh it here so the row is accurate even if this
            // view is somehow reached before setup() ran, and so it reflects a
            // permission the user changed in Settings.app while we were away.
            keepAlive.refreshLocationAuthStatus()
        }
    }

    // MARK: - Voice Picker

    @ViewBuilder
    private func voicePicker(label: String, language: String, selection: Binding<String>) -> some View {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .sorted { $0.name < $1.name }

        Picker(label, selection: selection) {
            Text("System Default").tag("")
            ForEach(voices, id: \.identifier) { voice in
                Text(voiceDisplayName(voice)).tag(voice.identifier)
            }
        }
    }

    private func voiceDisplayName(_ voice: AVSpeechSynthesisVoice) -> String {
        // Same verbatim-Text caveat as locationStatusText: this is interpolated
        // into a String, so localize here rather than relying on Text lookup.
        let quality: String
        switch voice.quality {
        case .enhanced: quality = AppLocalized("Enhanced", comment: "Speech voice quality")
        case .premium: quality = AppLocalized("Premium", comment: "Speech voice quality")
        default: quality = ""
        }
        let suffix = quality.isEmpty ? "" : " (\(quality))"
        return "\(voice.name)\(suffix)"
    }

    // MARK: - Preview

    private func previewSpeech() {
        let text = keepAlive.speechVoiceZh.isEmpty && keepAlive.speechVoiceEn.isEmpty
            ? "Hello, this is a speech preview."
            : {
                // If a Chinese voice is set but not English, preview in Chinese
                if !keepAlive.speechVoiceZh.isEmpty && keepAlive.speechVoiceEn.isEmpty {
                    return "你好，这是语音预览。"
                }
                return "Hello, this is a speech preview."
            }()
        let utterance = AVSpeechUtterance(string: text)
        let lang = text.range(of: "\\p{Han}", options: .regularExpression) != nil ? "zh-CN" : "en-US"
        utterance.voice = keepAlive.voiceForLanguage(lang)
        utterance.rate = keepAlive.speechRate
        utterance.pitchMultiplier = keepAlive.speechPitch
        utterance.volume = keepAlive.speechVolume
        // Audio-session intent is declared through AudioSessionCoordinator inside
        // the player (begin on speak, end on didFinish/didCancel), matching the
        // real read-replies path instead of poking AVAudioSession directly.
        previewPlayer.speak(utterance)
    }

    // MARK: - Location Status

    /// [T-keepalive-survival-tier] Label for the extended tier naming the
    /// enabled keep-alive legs.
    private func extendedTierLabel(location: Bool, audio: Bool) -> String {
        switch (location, audio) {
        case (true, true): return AppLocalized("Extended (Location + Audio)", comment: "Keep-alive tier")
        case (true, false): return AppLocalized("Extended (Location)", comment: "Keep-alive tier")
        default: return AppLocalized("Extended (Audio)", comment: "Keep-alive tier")
        }
    }

    /// Localized location-permission status. These are consumed as
    /// `Text(locationStatusText)` — a String variable, which selects SwiftUI's
    /// VERBATIM initializer and performs no catalog lookup. So the localization
    /// has to happen here via `String(localized:)`; returning bare literals kept
    /// this row English in every language.
    private var locationStatusText: String {
        switch keepAlive.locationAuthStatus {
        case .notDetermined: return AppLocalized("Not Requested", comment: "Location permission status")
        case .restricted: return AppLocalized("Restricted", comment: "Location permission status")
        case .denied: return AppLocalized("Denied", comment: "Location permission status")
        case .authorizedWhenInUse: return AppLocalized("When In Use", comment: "Location permission status")
        case .authorizedAlways: return AppLocalized("Always", comment: "Location permission status")
        @unknown default: return AppLocalized("Unknown", comment: "Location permission status")
        }
    }

    private var locationStatusColor: Color {
        switch keepAlive.locationAuthStatus {
        case .authorizedAlways: return .green
        case .authorizedWhenInUse: return .orange
        case .denied, .restricted: return .red
        default: return .secondary
        }
    }
}

// MARK: - Focus highlight

private extension View {
    /// [T-settings-focus-highlight] Draw a yellow rounded-rect border around a
    /// row recommended by a `?focus=…` deep-link. The border fades out once
    /// `focused` flips to false (i.e. the user interacted with the row).
    @ViewBuilder
    func focusHighlight(_ focused: Bool) -> some View {
        self
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.yellow, lineWidth: 2)
                    // Expand the border outward so it isn't cramped against the
                    // row text — more breathing room above/below in particular.
                    .padding(.horizontal, -10)
                    .padding(.vertical, -12)
                    .opacity(focused ? 1 : 0)
                    .allowsHitTesting(false)
            )
            .animation(.easeInOut(duration: 0.3), value: focused)
    }
}

/// Owns the settings "speech preview" synthesizer and balances its
/// AudioSessionCoordinator `.replyTTS` intent. A SwiftUI `View` struct can't be
/// an `AVSpeechSynthesizerDelegate`, so the begin/end lifecycle lives here.
/// [T-audio-session-preview]
@MainActor
final class SpeechPreviewPlayer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    /// Whether we currently hold a `.replyTTS` intent — guards against a double
    /// `end` (re-tap fires didCancel for the old utterance after we've already
    /// begun a fresh intent) and against `end` without a matching `begin`.
    private var holdingIntent = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ utterance: AVSpeechUtterance) {
        // Stop any in-progress preview first. This fires didCancel synchronously
        // on some OS versions, which would `end` the intent we're about to hold;
        // releasing it here first keeps begin/end balanced regardless of ordering.
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        releaseIntent()
        AudioSessionCoordinator.shared.begin(.replyTTS)
        holdingIntent = true
        synthesizer.speak(utterance)
    }

    private func releaseIntent() {
        guard holdingIntent else { return }
        holdingIntent = false
        AudioSessionCoordinator.shared.end(.replyTTS)
    }

    // AVSpeechSynthesizer delivers delegate callbacks on the main thread; hop to
    // the MainActor to touch the (@MainActor) coordinator + our state.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated { releaseIntent() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated { releaseIntent() }
    }
}

// MARK: - Background Boost Status

/// [T-background-boost-status] "Current Effect" — what the Background Boost
/// configuration is doing RIGHT NOW, read live from the running process.
///
/// Three groups, deliberately separated so the kinds of fact cannot be confused:
///   1. Configuration   — what the user asked for.
///   2. Now             — what is actually happening (audio engine, timers, grants).
///   3. Installed Build — what the signed bundle on this device declares
///                        (Info.plist + embedded PlugIns). This is the group that
///                        answers "is my build missing something the official one
///                        ships?" without anyone having to unpack an IPA.
struct BackgroundBoostStatusView: View {
    @ObservedObject private var boost = BackgroundBoost.shared
    /// Observed only so the panel re-renders when a leg is toggled elsewhere (and so
    /// the survival-tier row below reads a live value).
    @ObservedObject private var keepAlive = BackgroundKeepAliveManager.shared

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            content(boost.snapshot(), now: context.date)
        }
        .navigationTitle("Current Effect")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(_ s: BackgroundBoostSnapshot, now: Date) -> some View {
        List {
            Section {
                statusRow(AppLocalized("Mode", comment: "Boost status row"), value: s.mode.title)
                statusRow(AppLocalized("In effect", comment: "Boost status row"),
                          value: s.effective
                              ? AppLocalized("Yes", comment: "Boost status value")
                              : AppLocalized("No", comment: "Boost status value"),
                          tint: s.effective ? .green : .red)
                statusRow(AppLocalized("Survival tier", comment: "Boost status row"),
                          value: survivalTierText,
                          tint: s.effective ? .green : .secondary)
                statusRow(AppLocalized("Applied at", comment: "Boost status row"),
                          value: s.appliedAt.map { Self.clock($0) } ?? AppLocalized("not yet", comment: "Boost status value"))
                statusRow(AppLocalized("Re-apply on launch", comment: "Boost status row"),
                          value: yesNo(s.armOnLaunch))
            } header: {
                Text("Configuration")
            } footer: {
                Text("An effective configuration is one that can actually hold the process open. The master switch alone is not enough: the audio leg is what does the keeping-alive, and its live state is in the next group.")
            }

            Section {
                statusRow(AppLocalized("Keep-alive needed now", comment: "Boost status row"),
                          value: s.keepAliveActive
                              ? AppLocalized("Yes - a task is running", comment: "Boost status value")
                              : AppLocalized("No - idle", comment: "Boost status value"),
                          tint: s.keepAliveActive ? .orange : .secondary)
                statusRow(AppLocalized("Background audio", comment: "Boost status row"),
                          value: s.silentAudioPlaying
                              ? AppLocalized("Playing (silent)", comment: "Boost status value")
                              : AppLocalized("Stopped", comment: "Boost status value"),
                          tint: s.silentAudioPlaying ? .green : .secondary)
                statusRow(AppLocalized("Audio session", comment: "Boost status row"),
                          value: s.audioSessionActive
                              ? AppLocalized("Active", comment: "Boost status value")
                              : AppLocalized("Inactive", comment: "Boost status value"),
                          tint: s.audioSessionActive ? .green : .secondary)
                statusRow(AppLocalized("Location heartbeat", comment: "Boost status row"),
                          value: locationValue(s),
                          tint: s.backgroundLocationArmed ? .green : .secondary)
                statusRow(AppLocalized("Live Activity switch", comment: "Boost status row"),
                          value: yesNo(s.liveActivitySwitchOn))
                statusRow(AppLocalized("Live Activity", comment: "Boost status row"),
                          value: liveActivityValue(s),
                          tint: s.liveActivityRunning ? .green : .secondary)
                statusRow(AppLocalized("Running tasks", comment: "Boost status row"),
                          value: "\(s.activeSessions)")
                statusRow(AppLocalized("Background task grants", comment: "Boost status row"),
                          value: "\(s.liveBackgroundGrants)")
            } header: {
                Text("Now")
            } footer: {
                Text("Keep-alive is only needed while a task runs; an idle app is allowed to suspend. Silent audio is the mechanism that holds the process open, so \"Playing (silent)\" while a task runs is the healthy state.")
            }

            Section {
                statusRow(AppLocalized("App state", comment: "Boost status row"),
                          value: s.appIsInBackground
                              ? AppLocalized("Background", comment: "Boost status value")
                              : AppLocalized("Foreground", comment: "Boost status value"))
                statusRow(AppLocalized("In background for", comment: "Boost status row"),
                          value: s.backgroundEnteredAt.map { Self.duration(now.timeIntervalSince($0)) }
                              ?? AppLocalized("not in background", comment: "Boost status value"))
                statusRow(AppLocalized("Last background entry", comment: "Boost status row"),
                          value: Self.stamp(s.lastBackgroundSuspendAt))
                statusRow(AppLocalized("Last foreground return", comment: "Boost status row"),
                          value: Self.stamp(s.lastForegroundResumeAt))
                statusRow(AppLocalized("Last interruption recorded", comment: "Boost status row"),
                          value: Self.stamp(s.lastInterruptionAt))
                statusRow(AppLocalized("Readable remaining", comment: "Boost status row"),
                          value: remainingValue(s))
            } header: {
                Text("Timeline")
            } footer: {
                Text("Measured: the background duration, the suspend/resume stamps and the task counts all come from real notifications. \"Readable remaining\" is iOS's own finite background-task clock (UIApplication.backgroundTimeRemaining); it reads as unlimited once a keep-alive leg is holding the process open, or while the app is in the foreground. iOS does not publish how long a keep-alive leg will survive, so no such figure exists here and none is invented. The timestamp rows stay at \"not yet\" until this process has backgrounded and returned once.")
            }

            Section {
                statusRow(AppLocalized("UIBackgroundModes", comment: "Boost status row"),
                          value: s.backgroundModes.isEmpty
                              ? AppLocalized("(none declared)", comment: "Boost status value")
                              : s.backgroundModes.joined(separator: ", "))
                statusRow(AppLocalized("NSSupportsLiveActivities", comment: "Boost status row"),
                          value: yesNo(s.liveActivitiesKey))
                statusRow(AppLocalized("Live Activity frequent updates", comment: "Boost status row"),
                          value: yesNo(s.frequentUpdatesKey))
                statusRow(AppLocalized("Live Activity extension", comment: "Boost status row"),
                          value: s.liveActivityExtensionEmbedded
                              ? AppLocalized("embedded", comment: "Boost status value")
                              : AppLocalized("not embedded", comment: "Boost status value"),
                          tint: s.liveActivityExtensionEmbedded ? .green : .red)
                statusRow(AppLocalized("Live Activity support", comment: "Boost status row"),
                          value: liveActivitySupportValue(s),
                          tint: s.liveActivitySupported && s.liveActivityExtensionEmbedded ? .green : .secondary)
            } header: {
                Text("Installed Build")
            } footer: {
                Text("Read from the Info.plist and the embedded PlugIns of the app bundle installed on this device, not from the source tree. UIBackgroundModes is a declaration rather than a permission: iOS never asks for audio, and Live Activities never ask for anything, so there is no prompt that a differently-signed build could have skipped. \"not embedded\" means this build ships no widget extension, so Live Activities cannot appear in it at all; and on an iOS 15 device the feature does not exist regardless, because ActivityKit arrived in iOS 16.1.")
            }
        }
    }

    // MARK: - Row helpers

    private func statusRow(_ label: String, value: String, tint: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 12)
            Text(value)
                .foregroundColor(tint)
                .multilineTextAlignment(.trailing)
        }
    }

    private func yesNo(_ value: Bool) -> String {
        value
            ? AppLocalized("Yes", comment: "Boost status value")
            : AppLocalized("No", comment: "Boost status value")
    }

    private var survivalTierText: String {
        switch keepAlive.survivalTier {
        case .short:
            return AppLocalized("Short-lived (about 30 seconds)", comment: "Boost status value")
        case .extended(let location, let audio):
            if location && audio {
                return AppLocalized("Extended (location + audio)", comment: "Boost status value")
            }
            if location {
                return AppLocalized("Extended (location)", comment: "Boost status value")
            }
            return AppLocalized("Extended (audio)", comment: "Boost status value")
        }
    }

    private func locationValue(_ s: BackgroundBoostSnapshot) -> String {
        guard s.locationLegOn else { return AppLocalized("Off", comment: "Boost status value") }
        var parts = [AppLocalized("On", comment: "Boost status value"), locationAuthText(s.locationAuth)]
        if s.backgroundLocationArmed {
            parts.append(AppLocalized("armed", comment: "Boost status value"))
        } else {
            parts.append(AppLocalized("not armed yet", comment: "Boost status value"))
        }
        return parts.joined(separator: " / ")
    }

    private func locationAuthText(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return AppLocalized("Not Requested", comment: "Location permission status")
        case .restricted: return AppLocalized("Restricted", comment: "Location permission status")
        case .denied: return AppLocalized("Denied", comment: "Location permission status")
        case .authorizedWhenInUse: return AppLocalized("When In Use", comment: "Location permission status")
        case .authorizedAlways: return AppLocalized("Always", comment: "Location permission status")
        @unknown default: return AppLocalized("Unknown", comment: "Location permission status")
        }
    }

    private func liveActivityValue(_ s: BackgroundBoostSnapshot) -> String {
        if s.liveActivityRunning { return AppLocalized("Running", comment: "Boost status value") }
        if !s.liveActivitySupported { return AppLocalized("Not supported on this device", comment: "Boost status value") }
        if !s.liveActivitiesKey { return AppLocalized("Unavailable - this build does not declare Live Activities", comment: "Boost status value") }
        if !s.liveActivitySwitchOn { return AppLocalized("Switched off", comment: "Boost status value") }
        return AppLocalized("Idle - nothing on screen", comment: "Boost status value")
    }

    private func liveActivitySupportValue(_ s: BackgroundBoostSnapshot) -> String {
        if !s.liveActivitySupported {
            return AppLocalized("No - this OS or device does not support it", comment: "Boost status value")
        }
        if !s.liveActivityExtensionEmbedded {
            return AppLocalized("No - this build ships no widget extension", comment: "Boost status value")
        }
        return AppLocalized("Yes", comment: "Boost status value")
    }

    private func remainingValue(_ s: BackgroundBoostSnapshot) -> String {
        if s.backgroundTimeRemaining > 100_000 {
            return AppLocalized("Unlimited (a keep-alive leg is active, or the app is in the foreground)",
                                comment: "Boost status value")
        }
        return String(format: "%.0f s", s.backgroundTimeRemaining)
    }

    // MARK: - Formatting

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    private static func stamp(_ date: Date?) -> String {
        guard let date = date else { return AppLocalized("not yet", comment: "Boost status value") }
        return clockFormatter.string(from: date)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let hours = minutes / 60
        if hours == 0 { return "\(minutes)m \(total % 60)s" }
        return "\(hours)h \(minutes % 60)m"
    }
}
