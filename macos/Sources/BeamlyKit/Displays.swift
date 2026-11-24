import AppKit
import ScreenCaptureKit

public struct DisplayInfo: Sendable {
    public let index: Int
    public let name: String
    public let width: Int
    public let height: Int
}

/// Displays available for capture, in `StreamOptions.display` index order.
/// Triggers the Screen Recording permission prompt on first use.
public func listDisplays() async throws -> [DisplayInfo] {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    var names: [CGDirectDisplayID: String] = [:]
    for screen in NSScreen.screens {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            names[number.uint32Value] = screen.localizedName
        }
    }
    return content.displays.enumerated().map { index, display in
        DisplayInfo(
            index: index, name: names[display.displayID] ?? "Display \(index + 1)",
            width: display.width, height: display.height)
    }
}
