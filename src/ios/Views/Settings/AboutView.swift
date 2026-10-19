import SwiftUI
import UIKit

struct AboutView: View {
    private let appVersion: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        // [T-build-in-version] `build<CFBundleVersion>` is the CI run number; see the iOS 26 line's twin for why this is not cosmetic.
        return "\(version) build\(build)"
    }()

    /// When this binary was built, from the executable's modification date.
    ///
    /// Exists because the version string alone cannot answer "is the fix I
    /// just shipped actually running on that device?" — CFBundleVersion is
    /// static across rebuilds, so an OTA install that silently didn't replace
    /// the app looks identical to one that did. That ambiguity has cost real
    /// debugging time on the test devices. Same source as the debug server's
    /// `buildDate`, but visible in Release too, where no debug server exists.
    private let buildDate: String = {
        guard let url = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mod = attrs[.modificationDate] as? Date
        else { return "unknown" }
        let fmt = DateFormatter()
        // Local time, seconds included: this gets compared by eye against the
        // timestamp of a build that just finished.
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.string(from: mod)
    }()

    var body: some View {
        List {
            // MARK: - Project Info
            Section {
                VStack(spacing: 8) {
                    if let icon = UIImage(named: "AppIcon60x60") ?? UIImage(named: "AppIcon") {
                        Image(uiImage: icon)
                            .resizable()
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(Color(UIColor.separator), lineWidth: 0.5)
                            )
                    }
                    Text("Minis")
                        .font(AppFont.sw(22, weight: .bold, category: .title))
                    Text("Version \(appVersion)")
                        .font(AppFont.sw(15, weight: .regular, category: .body))
                        .foregroundStyle(.secondary)
                    Text("Built \(buildDate)")
                        .font(AppFont.sw(12, weight: .regular, category: .ui))
                        .foregroundStyle(.tertiary)
                        // Selectable so it can be copied into a bug report.
                        .textSelection(.enabled)
                    Text("Minis is Your Fully Local, Fully Private On-Device Agent.")
                        .font(AppFont.sw(15, weight: .regular, category: .body))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            // MARK: - Links
            Section("Links") {
                Link(destination: URL(string: "https://github.com/czy20010112/openminis-dshcore")!) {
                    Label {
                        HStack {
                            Text("GitHub Repository")
                                .foregroundStyle(Color(UIColor.label))
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "link.circle.fill")
                    }
                }
                Link(destination: URL(string: "https://github.com/czy20010112/openminis-dshcore/issues")!) {
                    Label {
                        HStack {
                            Text("Report an Issue")
                                .foregroundStyle(Color(UIColor.label))
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                    }
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
