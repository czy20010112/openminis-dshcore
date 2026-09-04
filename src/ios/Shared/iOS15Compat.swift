//
//  iOS15Compat.swift
//  MinisApp
//
//  Compatibility layer for iOS 15.x deployment.
//  Provides polyfills, shims, and backported UI primitives.
//

import SwiftUI
import Combine

// MARK: - Task.sleep Helper

extension Task where Success == Never, Failure == Never {
    /// Backward-compatible sleep helper for iOS 15.
    public static func sleep(seconds: Double) async throws {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

// MARK: - Compat AnyShape

public struct AnyCompatShape: Shape {
    private let _path: (CGRect) -> Path

    public init<S: Shape>(_ shape: S) {
        _path = { rect in shape.path(in: rect) }
    }

    public func path(in rect: CGRect) -> Path {
        _path(rect)
    }
}

// MARK: - Compat LabeledContent

public struct LabeledContent<Label: View, Content: View>: View {
    private let label: Label
    private let content: Content

    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.content = content()
    }

    public var body: some View {
        HStack {
            label
            Spacer()
            content
                .foregroundStyle(.secondary)
        }
    }
}

extension LabeledContent where Label == Text, Content == Text {
    public init(_ titleKey: LocalizedStringKey, value: String) {
        self.init(content: { Text(value) }, label: { Text(titleKey) })
    }

    public init<S: StringProtocol>(_ title: S, value: S) {
        self.init(content: { Text(String(value)) }, label: { Text(String(title)) })
    }
}

extension LabeledContent where Label == Text {
    public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        self.init(content: content, label: { Text(String(title)) })
    }

    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(content: content, label: { Text(titleKey) })
    }
}

// MARK: - Compat UIHostingConfiguration

import UIKit

public struct UIHostingConfiguration<Content: View, Background: View>: UIContentConfiguration {
    public var content: Content
    public var background: Background?

    public init(@ViewBuilder content: () -> Content) where Background == EmptyView {
        self.content = content()
        self.background = nil
    }

    public func minSize(width: CGFloat? = nil, height: CGFloat? = nil) -> Self { self }
    public func margins(_ edges: Edge.Set = .all, _ insets: EdgeInsets) -> Self { self }
    public func margins(_ edges: Edge.Set = .all, _ length: CGFloat) -> Self { self }

    public func makeContentView() -> UIView & UIContentView {
        HostingContentView(configuration: self)
    }

    public func updated(for state: UIConfigurationState) -> Self { self }
}

private class HostingContentView<Content: View, Background: View>: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet {
            update()
        }
    }

    private var host: UIHostingController<Content>?

    init(configuration: UIHostingConfiguration<Content, Background>) {
        self.configuration = configuration
        super.init(frame: .zero)
        backgroundColor = .clear
        let h = UIHostingController(rootView: configuration.content)
        h.view.backgroundColor = .clear
        h.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(h.view)
        NSLayoutConstraint.activate([
            h.view.topAnchor.constraint(equalTo: topAnchor),
            h.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            h.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            h.view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        self.host = h
    }

    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        if let config = configuration as? UIHostingConfiguration<Content, Background> {
            host?.rootView = config.content
        }
    }
}

// MARK: - Additional View Modifiers

struct CompatGeometryPreferenceKey<T: Equatable>: PreferenceKey {
    static var defaultValue: T? { nil }
    static func reduce(value: inout T?, nextValue: () -> T?) {
        if let next = nextValue() { value = next }
    }
}

extension View {
    @ViewBuilder
    public func compatListRowSeparatorLeadingZero() -> some View {
        if #available(iOS 16.0, *) {
            self.alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        } else {
            self
        }
    }

    @ViewBuilder
    public func compatScrollIndicators() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollIndicators(.visible)
        } else {
            self
        }
    }

    public func compatOnGeometryChange<T: Equatable>(for type: T.Type, of transform: @escaping (GeometryProxy) -> T, action: @escaping (T) -> Void) -> some View {
        self.background(
            GeometryReader { geo in
                Color.clear.preference(key: CompatGeometryPreferenceKey<T>.self, value: transform(geo))
            }
        )
        .onPreferenceChange(CompatGeometryPreferenceKey<T>.self) { val in
            if let val = val { action(val) }
        }
    }
}

// MARK: - Locale Helpers

extension Locale {
    public var compatLangCode: String? {
        self.languageCode
    }
}

/// Backward-compatible asymmetric rounded rectangle shape that works on iOS 15+.
public struct CompatUnevenRoundedRectangle: Shape {
    public var topLeadingRadius: CGFloat
    public var bottomLeadingRadius: CGFloat
    public var bottomTrailingRadius: CGFloat
    public var topTrailingRadius: CGFloat
    public var style: RoundedCornerStyle

    public init(
        topLeadingRadius: CGFloat = 0,
        bottomLeadingRadius: CGFloat = 0,
        bottomTrailingRadius: CGFloat = 0,
        topTrailingRadius: CGFloat = 0,
        style: RoundedCornerStyle = .continuous
    ) {
        self.topLeadingRadius = topLeadingRadius
        self.bottomLeadingRadius = bottomLeadingRadius
        self.bottomTrailingRadius = bottomTrailingRadius
        self.topTrailingRadius = topTrailingRadius
        self.style = style
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let x = rect.minX
        let y = rect.minY

        let tl = max(0, min(min(topLeadingRadius, h / 2), w / 2))
        let tr = max(0, min(min(topTrailingRadius, h / 2), w / 2))
        let br = max(0, min(min(bottomTrailingRadius, h / 2), w / 2))
        let bl = max(0, min(min(bottomLeadingRadius, h / 2), w / 2))

        path.move(to: CGPoint(x: x + tl, y: y))
        path.addLine(to: CGPoint(x: x + w - tr, y: y))
        if tr > 0 {
            path.addArc(center: CGPoint(x: x + w - tr, y: y + tr), radius: tr,
                        startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        }
        path.addLine(to: CGPoint(x: x + w, y: y + h - br))
        if br > 0 {
            path.addArc(center: CGPoint(x: x + w - br, y: y + h - br), radius: br,
                        startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        }
        path.addLine(to: CGPoint(x: x + bl, y: y + h))
        if bl > 0 {
            path.addArc(center: CGPoint(x: x + bl, y: y + h - bl), radius: bl,
                        startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        }
        path.addLine(to: CGPoint(x: x, y: y + tl))
        if tl > 0 {
            path.addArc(center: CGPoint(x: x + tl, y: y + tl), radius: tl,
                        startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Compat NavigationStack

/// A navigation container that uses NavigationStack on iOS 16+ and NavigationView with .stack style on iOS 15.
public struct CompatNavigationStack<Content: View>: View {
    @ViewBuilder private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack {
                content()
            }
        } else {
            NavigationView {
                content()
            }
            .navigationViewStyle(.stack)
        }
    }
}

// MARK: - View Modifiers Polyfill

public enum CompatDetent: Hashable {
    case medium
    case large
    case height(CGFloat)
    case fraction(CGFloat)
}

public enum CompatDragIndicator {
    case automatic
    case visible
    case hidden
}

extension View {
    /// Safe scrollContentBackground(.hidden) for iOS 15
    @ViewBuilder
    public func compatScrollContentBackgroundHidden() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    /// Safe scrollDismissesKeyboard(.interactively) for iOS 15
    @ViewBuilder
    public func compatScrollDismissesKeyboardInteractively() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }

    /// Safe presentationDragIndicator for iOS 15
    @ViewBuilder
    public func compatDragIndicator(_ visibility: CompatDragIndicator) -> some View {
        if #available(iOS 16.0, *) {
            switch visibility {
            case .automatic: self.presentationDragIndicator(.automatic)
            case .visible: self.presentationDragIndicator(.visible)
            case .hidden: self.presentationDragIndicator(.hidden)
            }
        } else {
            self
        }
    }

    /// Safe presentationDetents for iOS 15
    @ViewBuilder
    public func compatDetents(_ detents: [CompatDetent]) -> some View {
        if #available(iOS 16.0, *) {
            let nativeDetents: Set<PresentationDetent> = Set(detents.map { d in
                switch d {
                case .medium: return PresentationDetent.medium
                case .large: return PresentationDetent.large
                case .height(let h): return PresentationDetent.height(h)
                case .fraction(let f): return PresentationDetent.fraction(f)
                }
            })
            self.presentationDetents(nativeDetents)
        } else {
            self
        }
    }
}

// MARK: - Compat Photo Picker (iOS 14+)

import Photos
import PhotosUI
import UniformTypeIdentifiers

public struct CompatPickedMedia: Identifiable {
    public let id = UUID()
    public let isVideo: Bool
    public let data: Data?
    public let fileURL: URL?
    public let fileExtension: String?
    public let creationDate: Date?

    public init(
        isVideo: Bool,
        data: Data?,
        fileURL: URL?,
        fileExtension: String?,
        creationDate: Date?
    ) {
        self.isVideo = isVideo
        self.data = data
        self.fileURL = fileURL
        self.fileExtension = fileExtension
        self.creationDate = creationDate
    }
}

public struct CompatPhotoPicker: UIViewControllerRepresentable {
    public var maxSelectionCount: Int = 1
    public var filter: PHPickerFilter = .images
    public var onComplete: ([CompatPickedMedia]) -> Void

    public init(
        maxSelectionCount: Int = 1,
        filter: PHPickerFilter = .images,
        onComplete: @escaping ([CompatPickedMedia]) -> Void
    ) {
        self.maxSelectionCount = maxSelectionCount
        self.filter = filter
        self.onComplete = onComplete
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = maxSelectionCount
        config.filter = filter
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    public func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    public class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: CompatPhotoPicker

        init(_ parent: CompatPhotoPicker) {
            self.parent = parent
        }

        public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else {
                parent.onComplete([])
                return
            }

            Task {
                var loaded: [CompatPickedMedia] = []
                for result in results {
                    let provider = result.itemProvider
                    let isVideo = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                    var assetDate: Date?
                    if let aid = result.assetIdentifier,
                       let asset = PHAsset.fetchAssets(withLocalIdentifiers: [aid], options: nil).firstObject {
                        assetDate = asset.creationDate
                    }

                    if isVideo {
                        let fileURL: URL? = await withCheckedContinuation { continuation in
                            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                                guard let url = url else {
                                    continuation.resume(returning: nil)
                                    return
                                }
                                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + url.lastPathComponent)
                                try? FileManager.default.copyItem(at: url, to: tempURL)
                                continuation.resume(returning: tempURL)
                            }
                        }
                        if let fileURL = fileURL {
                            loaded.append(CompatPickedMedia(
                                isVideo: true,
                                data: nil,
                                fileURL: fileURL,
                                fileExtension: fileURL.pathExtension,
                                creationDate: assetDate
                            ))
                        }
                    } else {
                        let data: Data? = await withCheckedContinuation { continuation in
                            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                                continuation.resume(returning: data)
                            }
                        }
                        let ext = provider.registeredTypeIdentifiers.first.flatMap {
                            UTType($0)?.preferredFilenameExtension
                        }
                        if let data = data {
                            loaded.append(CompatPickedMedia(
                                isVideo: false,
                                data: data,
                                fileURL: nil,
                                fileExtension: ext,
                                creationDate: assetDate
                            ))
                        }
                    }
                }
                let finalLoaded = loaded
                await MainActor.run {
                    self.parent.onComplete(finalLoaded)
                }
            }
        }
    }
}

// MARK: - ContentView Navigation Holder (iOS 15 / 16 bridging)

@MainActor
public final class ContentViewNavigationHolder: ObservableObject {
    public static let shared = ContentViewNavigationHolder()

    @Published public var navigationPathToken = UUID()

    public var isPathEmpty: Bool {
        if #available(iOS 16.0, *) {
            return navigationPath.isEmpty
        } else {
            return true
        }
    }

    private var _columnVisibility: Any? = nil

    @available(iOS 16.0, *)
    public var columnVisibility: NavigationSplitViewVisibility {
        get {
            (_columnVisibility as? NavigationSplitViewVisibility) ?? .automatic
        }
        set {
            _columnVisibility = newValue
            objectWillChange.send()
        }
    }

    private var _navigationPath: Any? = nil

    @available(iOS 16.0, *)
    public var navigationPath: NavigationPath {
        get {
            if let p = _navigationPath as? NavigationPath { return p }
            let p = NavigationPath()
            _navigationPath = p
            return p
        }
        set {
            _navigationPath = newValue
            navigationPathToken = UUID()
            objectWillChange.send()
        }
    }

    private var _settingsNavPath: Any? = nil

    @available(iOS 16.0, *)
    public var settingsNavPath: NavigationPath {
        get {
            if let p = _settingsNavPath as? NavigationPath { return p }
            let p = NavigationPath()
            _settingsNavPath = p
            return p
        }
        set {
            _settingsNavPath = newValue
            objectWillChange.send()
        }
    }

    private var _pendingBackgroundNav: Any? = nil

    @available(iOS 16.0, *)
    public var pendingBackgroundNavigation: (path: NavigationPath, deferredAt: Date)? {
        get {
            _pendingBackgroundNav as? (path: NavigationPath, deferredAt: Date)
        }
        set {
            _pendingBackgroundNav = newValue
            objectWillChange.send()
        }
    }
}

// MARK: - View Compatibility Extensions

extension View {
    @ViewBuilder
    public func compatContextMenu<M: View, P: View>(
        @ViewBuilder menuItems: () -> M,
        @ViewBuilder preview: () -> P
    ) -> some View {
        if #available(iOS 16.0, *) {
            self.contextMenu(menuItems: menuItems, preview: preview)
        } else {
            self.contextMenu(menuItems: menuItems)
        }
    }

    @ViewBuilder
    public func compatFontWeight(_ weight: Font.Weight?) -> some View {
        if #available(iOS 16.0, *) {
            self.fontWeight(weight)
        } else {
            self
        }
    }

    @ViewBuilder
    public func compatBold(_ active: Bool = true) -> some View {
        if #available(iOS 16.0, *) {
            self.bold(active)
        } else {
            self
        }
    }

    @ViewBuilder
    public func compatDraggable<T>(_ payload: @autoclosure @escaping () -> T) -> some View {
        #if canImport(CoreTransferable)
        if #available(iOS 16.0, *), let transferable = payload() as? String {
            self.draggable(transferable)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
