//
//  AppLocalization.swift
//  MinisApp
//

import Foundation

/// The bundle localized lookups should read from.
enum AppBundle {
    static var current: Bundle {
        Bundle.main.languageBundle ?? Bundle.main
    }
}

/// Localized string that follows the in-app language override.
/// Compatible with iOS 15+.
func AppLocalized(_ key: String, comment: String = "") -> String {
    NSLocalizedString(key, bundle: AppBundle.current, comment: comment)
}

#if canImport(AppIntents)
import AppIntents

@available(iOS 16.0, *)
@_disfavoredOverload
func AppLocalized(_ resource: LocalizedStringResource) -> String {
    String(localized: resource)
}
#endif
