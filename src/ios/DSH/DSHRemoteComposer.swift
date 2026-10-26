import SwiftUI
import UIKit

/// The writable composer for a remote harness Session (`POST /mobile/v1/dsh/submissions`).
///
/// ## Why this is a file of its own instead of the local input bar
///
/// The local composer cannot be instantiated: `AIChatView.inputBar` and its
/// `inputBottomRow` are `private`, and that row reads ~30 `AIChatViewModel`
/// properties (`vm.attachments`, `vm.editingMessageIndex`, `vm.isProcessing`,
/// the slash/mention menus, `speechManager`, `voiceVM` …). Reusing it would mean
/// lifting the whole composer out of `AIChatView` — far past the 150-line budget
/// for this change, and it would put the local session path (which must not
/// change here) at risk. So this is the thin shell instead.
///
/// What is *reused*, and therefore cannot drift from the local bar:
///
///   * the editor — `PastableTextView`, the same `UIViewRepresentable` the local
///     composer mounts: same font (`AppFont.ui(FontSettings.shared.scaledChatInput(16.5))`),
///     same placeholder label plumbing, same return-key / caret handling;
///   * the colours — `ChatColors.inputBg` / `inputIconBg` / `inputIconBorder` /
///     `secondaryText` / `sendButton` / `sendButtonDisabled`;
///   * the context ring — `DSHContextRing`, drawn in the same 34pt slot;
///   * the speech engine — `SpeechRecognitionManager.shared`;
///   * the surface — the same 20pt continuous rounded rectangle: Liquid Glass on
///     iOS 26, the flat fill + both hand-rolled shadows below (the `CardSurface`
///     pattern in `DSHStatusPanelView`, whose `#if compiler(>=6.2)` branch is
///     what keeps this file byte-identical across the iOS 15 and iOS 26 trees —
///     the iOS 15 line builds with Xcode 16, where `glassEffect` does not exist,
///     so `#available` alone would not compile there).
///
/// What is re-declared below, with every number copied verbatim from the local
/// bar: the `＋ / ring / mic / ↑` order, the 12pt row spacing, the 16/12/10/16
/// paddings, the 34pt control circles with 18pt glyphs, the 34pt send/stop
/// glyph, and the 8pt outer padding.
///
/// ## Behaviour
///
/// * `Send` calls `onSend()` only when the trimmed draft is non-empty and no
///   turn is in flight; `canSend` mirrors the local rule exactly.
/// * While a turn runs (or a submission is still in flight) the same slot turns
///   into the red STOP that calls `onStop()` — the local `sendButton`'s
///   processing branch, unchanged.
/// * A failed send is the parent's business (it restores the draft and paints
///   the red line); this view never clears the binding itself.
struct DSHRemoteComposer: View {
    @Binding var text: String
    /// What the ring shows. nil draws the empty ring (the honest "nothing
    /// measured yet"), which is what the local composer does too.
    var contextReading: DSHContextReading?
    /// A turn is running on the host (`DSHRemoteTranscriptWriter.isRunning`).
    var isRunning: Bool
    /// A submission is in flight, or a stop was requested and has not settled.
    /// Folded into the STOP state so the send key can never fire twice.
    var isSending: Bool
    /// `Message DSH`, not the local `Message <soul> (@ to mention files)`:
    /// a remote Session has no file mentions, and the brand in this mode is DSH.
    var placeholder: String = "Message DSH"
    var onSend: () -> Void
    var onStop: () -> Void
    /// Measured height, for the message list's bottom inset. The local bar is
    /// reported the same way (`inputBarHeight`), because the list is the only
    /// view that knows how much of the bottom it must keep clear.
    var onHeightChange: (CGFloat) -> Void = { _ in }
    /// Mirrors the editor's focus into the parent so the list can keep its
    /// "keyboard raised → scroll to bottom" behaviour.
    var onFocusChange: (Bool) -> Void = { _ in }

    /// The local composer keeps this in `@State` and hands `$inputFocused` to
    /// `PastableTextView`; the same binding shape is required here.
    @State private var focused = false
    @State private var hasSelection = false
    @State private var isScrollable = false
    @State private var atScrollBottom = true

    // Dictation. `shared` on purpose: one engine for the process, exactly like
    // the local composer, and the two composers are never on screen together.
    @StateObject private var speech = SpeechRecognitionManager.shared
    /// How much of `speech.recognizedText` has already been appended, so the
    /// live transcript grows the draft instead of replacing it (the local
    /// `lastRecognizedLength` mechanism).
    @State private var recognizedLength = 0
    /// One-line, self-clearing hint. Used for the `＋` slot: a remote Session's
    /// submissions are text-only, so the affordance has to say so rather than
    /// open a picker whose attachments would then be dropped on the floor.
    @State private var notice: String?

    private static let iconSize: CGFloat = 34

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Local rule (`AIChatView.canSend`): non-empty after trimming. No
    /// attachment or provider-readiness term exists for a remote Session.
    private var canSend: Bool { !trimmed.isEmpty }

    /// The button is STOP whenever the host is mid-turn or a submission has not
    /// settled — the contract's "流式中禁止重复发送".
    private var busy: Bool { isRunning || isSending }

    var body: some View {
        surface.dshMeasureHeight(reportHeight)
    }

    /// The local health probe's rule: a 0pt report is a transient layout frame,
    /// not a real height. Passing it on would collapse the list's bottom inset
    /// for a frame and jolt the transcript.
    private func reportHeight(_ height: CGFloat) {
        guard height > 0 else { return }
        onHeightChange(height)
    }

    private var surface: some View {
        VStack(spacing: 5) {
            if let notice {
                Text(notice)
                    .font(AppFont.sw(11, weight: .regular, category: .ui))
                    .foregroundStyle(ChatColors.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .transition(.opacity)
            }

            PastableTextView(
                text: $text,
                isFocused: Binding(
                    get: { focused },
                    set: { value in
                        focused = value
                        onFocusChange(value)
                    }
                ),
                hasSelection: $hasSelection,
                isScrollable: $isScrollable,
                isAtScrollBottom: $atScrollBottom,
                placeholder: placeholder,
                onPasteImage: { _ in showAttachmentsUnavailable() },
                onPasteFile: { _ in showAttachmentsUnavailable() },
                onReturnKey: { sendIfPossible() },
                onArrowUp: { false },
                onArrowDown: { false },
                onTab: { false },
                onCaretChange: { _ in },
                onSelectionReplace: { _, _ in },
                desiredCaret: nil,
                maxHeightOverride: nil
            )
            // The local composer wraps the field in `composerBody`: fixedSize
            // vertically (grow with content up to the text view's own cap) plus
            // these exact paddings.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            controlRow
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        // Same gesture as the local bar: tapping anywhere on the capsule focuses
        // the editor (the text view itself is not the whole surface).
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { focusEditor() }
        // Automation hook for the screenshot/UI runs: the remote composer is the
        // only surface on this screen that is not a stock Minis view, so it gets
        // its own identifier instead of being found by glyph.
        .accessibilityIdentifier("dshComposer")
        .modifier(DSHRemoteComposerSurface())
        // Outer padding copied from the local bar, which is what makes the two
        // surfaces sit at the same distance from the screen edges.
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onReceive(speech.$recognizedText) { value in
            appendDictation(value)
        }
        .onChange(of: speech.state) { state in
            // Leaving recording ends one dictation segment; the next one starts
            // from an empty recognizedText, so the watermark restarts with it.
            if state == .idle { recognizedLength = 0 }
        }
    }

    // MARK: - Control row

    /// `＋ / [spacer] / ring / mic / send↑` — the local order since
    /// [T-ring-mic-order]: the ring sits BEFORE the mic so a mis-tap next to the
    /// send/stop slot starts dictation instead of cancelling a turn.
    private var controlRow: some View {
        HStack(spacing: 12) {
            attachmentButton
            Spacer(minLength: 0)
            contextRing
            micButton
            sendOrStopButton
        }
    }

    /// The `＋` slot. Visually identical to the local attachment button; the
    /// remote bridge has no attachment channel yet, so it states that in one
    /// line instead of opening a picker that would silently drop the file.
    private var attachmentButton: some View {
        Button { showAttachmentsUnavailable() } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(ChatColors.secondaryText)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .background(ChatColors.inputIconBg)
                .clipShape(Circle())
                .overlay(Circle().stroke(ChatColors.inputIconBorder, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Add attachment", comment: "VoiceOver label for the attachment button"))
        .accessibilityHint(Text("Not available for remote sessions"))
    }

    /// The context ring, in the same 34pt slot the local bar uses. It is an
    /// INDICATOR here, not a button: the local ring opens a per-component
    /// breakdown that only exists for a request this app assembled itself, and a
    /// remote turn is assembled on the computer — the sheet would open empty. The
    /// fill level (from the Session's `contextPressure`) is still the honest
    /// figure, so it is drawn and announced.
    private var contextRing: some View {
        DSHContextRing(fraction: contextReading?.fraction ?? 0, diameter: 22, lineWidth: 2)
            .frame(width: Self.iconSize, height: Self.iconSize)
            .contentShape(Circle())
            .accessibilityElement()
            .accessibilityLabel(Text("Context"))
            .accessibilityValue(Text(contextRingValue))
    }

    private var contextRingValue: String {
        guard let reading = contextReading, reading.hasWindow else {
            return AppLocalized("Nothing measured yet")
        }
        return String(format: AppLocalized("%lld%% used"), reading.percent)
    }

    /// Mic. Same 34pt circle and 18pt glyph as the local button, but a plain
    /// tap: the local one hands off to the inline voice panel, which is bound to
    /// the local view model. Here dictation writes straight into the draft.
    private var micButton: some View {
        Button { toggleDictation() } label: {
            Image(systemName: "mic")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(speech.state == .recording ? ChatColors.sendButton : ChatColors.secondaryText)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .background(ChatColors.inputIconBg)
                .clipShape(Circle())
                .overlay(Circle().stroke(ChatColors.inputIconBorder, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Voice input", comment: "Mic button starts dictation"))
        .accessibilityValue(Text(speech.state == .recording
                                ? AppLocalized("Recording")
                                : AppLocalized("Off")))
    }

    /// `arrow.up.circle.fill` at 34pt, the exact glyph and size of the local
    /// send button; `stop.circle.fill` in red while busy, as local.
    @ViewBuilder
    private var sendOrStopButton: some View {
        if busy {
            Button { onStop() } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Stop generating", comment: "VoiceOver label for the stop button"))
            .accessibilityHint(Text("Stops the reply that is being generated", comment: "VoiceOver hint for the stop button"))
            .accessibilityIdentifier("dshComposerStop")
        } else {
            Button { sendIfPossible() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(canSend ? ChatColors.sendButton : ChatColors.sendButtonDisabled)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(Text("Send", comment: "VoiceOver label for the send button"))
        }
    }

    // MARK: - Actions

    private func focusEditor() {
        guard !busy else { return }
        focused = true
    }

    private func sendIfPossible() {
        guard canSend, !busy else { return }
        // The system return key ends dictation the way the local composer does
        // before handing the text off; otherwise the next segment would append
        // itself to a draft that has already been sent.
        if speech.state == .recording { speech.stopRecording() }
        recognizedLength = 0
        onSend()
    }

    private func toggleDictation() {
        if speech.state == .recording {
            speech.stopRecording()
            return
        }
        recognizedLength = 0
        do {
            try speech.startRecording()
            focused = true
        } catch {
            showNotice(AppLocalized("Microphone is not available."))
        }
    }

    /// Appends only the new tail of the live transcript, so words already in the
    /// draft are not duplicated (`AIChatView`'s `lastRecognizedLength` rule).
    private func appendDictation(_ value: String) {
        guard speech.state == .recording else { return }
        let count = value.count
        guard count > recognizedLength else { return }
        text += String(value.dropFirst(recognizedLength))
        recognizedLength = count
    }

    private func showAttachmentsUnavailable() {
        showNotice(AppLocalized("Attachments aren't supported for remote sessions yet."))
    }

    /// One line, then gone. A dialog here would be the "弹窗堆叠" the brief
    /// explicitly rules out.
    private func showNotice(_ message: String) {
        withAnimation(.easeInOut(duration: 0.16)) { notice = message }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation(.easeInOut(duration: 0.2)) {
                if notice == message { notice = nil }
            }
        }
    }
}

// MARK: - Height reporting

/// The composer's height, as a preference rather than a live `GeometryReader` in
/// the layout — the same mechanism the local composer's `inputBarHeight` uses
/// (a `GeometryReader` in `.background` writes a preference; the shape of the
/// view never depends on it, so there is no layout feedback loop).
///
/// Declared here instead of calling the repo's `compatOnGeometryChange`
/// (`Shared/iOS15Compat.swift`) because that shim exists only in the iOS 15 tree,
/// and this file has to stay byte-identical across both trees with **no
/// conditional compilation**. `onGeometryChange` is not an option either: it is
/// iOS 16+, and the iOS 15 line's deployment target is 15.0 while it is built
/// with the same Xcode 26 toolchain — so a `#if compiler(>=6.2)` gate is TRUE
/// there and the call fails to typecheck (Mac mini: "'onGeometryChange(for:of:
/// action:)' is only available in iOS 16.0 or newer"). A compiler-version gate
/// cannot express "which deployment target am I", so the code simply does not
/// use the newer API at all.
private struct DSHComposerHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat? { nil }
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

private extension View {
    /// Reports this view's height on every change, starting with the first
    /// layout pass.
    func dshMeasureHeight(_ action: @escaping (CGFloat) -> Void) -> some View {
        self.background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: DSHComposerHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        )
        .onPreferenceChange(DSHComposerHeightPreferenceKey.self) { value in
            if let value { action(value) }
        }
    }
}

// MARK: - Surface

/// The composer capsule: Liquid Glass on iOS 26, the local composer's flat fill
/// plus BOTH of its hand-rolled shadows below.
///
/// Mirrors `AIChatView.ComposerSurface` (the visual source of truth for this
/// row) and `DSHStatusPanelView.CardSurface` (the cross-tree pattern). The
/// `compiler` branch is mandatory: the iOS 15 line builds against the iOS 18
/// SDK, where `glassEffect` does not exist at all, so `#available` alone would
/// fail to compile there and this file could not stay byte-identical across the
/// two trees.
private struct DSHRemoteComposerSurface: ViewModifier {
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .clipShape(shape)
        } else {
            flat(content)
        }
        #else
        flat(content)
        #endif
    }

    /// Pre-iOS-26 look, values copied verbatim from `ComposerSurface`: the flat
    /// fill, the clip, and both shadows (the top one only tints in dark mode,
    /// which is what lifts the bar off the transcript there).
    @ViewBuilder
    private func flat(_ content: Content) -> some View {
        content
            .background(shape.fill(ChatColors.inputBg))
            .clipShape(shape)
            .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 2)
            .shadow(color: Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.5) : UIColor(white: 0, alpha: 0) }), radius: 8, x: 0, y: -4)
    }
}
