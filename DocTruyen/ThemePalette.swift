import SwiftUI

struct ThemePalette {
    let background: Color
    let cardBackground: Color
    let headerBackground: Color
    let primaryText: Color
    let secondaryText: Color
    let accent: Color
    let border: Color

    static func forTheme(_ theme: ReaderTheme) -> ThemePalette {
        switch theme {
        case .sepia:
            return ThemePalette(
                background: Color(red: 0.965, green: 0.945, blue: 0.902),
                cardBackground: Color(red: 0.996, green: 0.980, blue: 0.945),
                headerBackground: Color(red: 0.992, green: 0.969, blue: 0.922),
                primaryText: Color(red: 0.184, green: 0.141, blue: 0.094),
                secondaryText: Color(red: 0.525, green: 0.431, blue: 0.325),
                accent: Color(red: 0.545, green: 0.369, blue: 0.204),
                border: Color(red: 0.910, green: 0.863, blue: 0.780)
            )
        case .pearl:
            return ThemePalette(
                background: Color(red: 0.965, green: 0.969, blue: 0.980),
                cardBackground: Color.white,
                headerBackground: Color.white,
                primaryText: Color(red: 0.110, green: 0.125, blue: 0.165),
                secondaryText: Color(red: 0.420, green: 0.455, blue: 0.525),
                accent: Color(red: 0.145, green: 0.388, blue: 0.922),
                border: Color(red: 0.886, green: 0.902, blue: 0.933)
            )
        case .midnight:
            return ThemePalette(
                background: Color(red: 0.075, green: 0.082, blue: 0.106),
                cardBackground: Color(red: 0.118, green: 0.129, blue: 0.165),
                headerBackground: Color(red: 0.102, green: 0.114, blue: 0.145),
                primaryText: Color(red: 0.910, green: 0.918, blue: 0.941),
                secondaryText: Color(red: 0.580, green: 0.612, blue: 0.686),
                accent: Color(red: 0.380, green: 0.620, blue: 0.980),
                border: Color(red: 0.196, green: 0.216, blue: 0.271)
            )
        case .jade:
            return ThemePalette(
                background: Color(red: 0.918, green: 0.957, blue: 0.929),
                cardBackground: Color(red: 0.957, green: 0.984, blue: 0.965),
                headerBackground: Color(red: 0.941, green: 0.973, blue: 0.949),
                primaryText: Color(red: 0.118, green: 0.208, blue: 0.157),
                secondaryText: Color(red: 0.345, green: 0.475, blue: 0.396),
                accent: Color(red: 0.157, green: 0.490, blue: 0.349),
                border: Color(red: 0.812, green: 0.890, blue: 0.835)
            )
        }
    }
}
