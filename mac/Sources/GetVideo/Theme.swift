import SwiftUI

// GetVideo's identity: broadcast colour bars on an edit-bay grey. Each stage of a job owns one
// bar colour everywhere it appears.

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { ap in
            let hex = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }

    static let bay = Color(light: 0xE6E9ED, dark: 0x111418)      // window background
    static let deck = Color(light: 0xFBFCFD, dark: 0x1A1E24)     // cards
    static let well = Color(light: 0xF0F2F5, dark: 0x12151A)     // inset fields, empty track
    static let line = Color(light: 0xCFD5DC, dark: 0x2C323B)     // hairlines
    static let ink = Color(light: 0x141C26, dark: 0xE9EDF2)      // text, primary button
    static let soft = Color(light: 0x5A6675, dark: 0x98A3B1)     // secondary text
    static let barWhite = Color(light: 0xD9DDE2, dark: 0xE9EDF2)
    static let barYellow = Color(light: 0xC99A00, dark: 0xE3B505)
    static let barCyan = Color(light: 0x0F8FA0, dark: 0x2BB8CA)
    static let barGreen = Color(light: 0x23874C, dark: 0x3FB56F)
    static let barMagenta = Color(light: 0xB0368A, dark: 0xD85CB1)
    static let barRed = Color(light: 0xC8351F, dark: 0xEF6A54)
    static let barBlue = Color(light: 0x2853C4, dark: 0x6F93F5)

    /// The seven bars, in broadcast order, for the logo.
    static let bars: [Color] = [.barWhite, .barYellow, .barCyan, .barGreen, .barMagenta, .barRed, .barBlue]
}

extension Font {
    /// Condensed slate lettering for headings and labels; always set in uppercase with tracking.
    static func slate(_ size: CGFloat) -> Font { .custom("AvenirNextCondensed-DemiBold", size: size) }
    /// Timecode-style numbers and paths.
    static func timecode(_ size: CGFloat = 12) -> Font { .system(size: size, design: .monospaced) }
}

enum Stage: CaseIterable {
    case download, convert, save

    var label: String {
        switch self {
        case .download: "Download"
        case .convert: "Convert"
        case .save: "Save"
        }
    }

    var color: Color {
        switch self {
        case .download: .barCyan
        case .convert: .barMagenta
        case .save: .barGreen
        }
    }
}
