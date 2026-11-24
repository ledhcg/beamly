import Foundation

/// Looks up a user-facing string in the app bundle's `Localizable.strings` (English is the source language).
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Localized format string.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
}
