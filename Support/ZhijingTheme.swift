import AppKit
import SwiftUI

enum ZhijingTheme {
    static let accentNSColor = dynamicColor(
        light: NSColor(red: 0.22, green: 0.43, blue: 0.68, alpha: 1),
        dark: NSColor(red: 0.48, green: 0.68, blue: 0.92, alpha: 1)
    )
    static let canvasNSColor = dynamicColor(
        light: NSColor(red: 0.957, green: 0.972, blue: 0.988, alpha: 1),
        dark: NSColor(red: 0.075, green: 0.095, blue: 0.122, alpha: 1)
    )
    static let paperNSColor = dynamicColor(
        light: NSColor(red: 0.992, green: 0.996, blue: 1.000, alpha: 1),
        dark: NSColor(red: 0.098, green: 0.119, blue: 0.151, alpha: 1)
    )
    static let sidebarNSColor = dynamicColor(
        light: NSColor(red: 0.937, green: 0.957, blue: 0.980, alpha: 1),
        dark: NSColor(red: 0.086, green: 0.108, blue: 0.139, alpha: 1)
    )
    static let chromeNSColor = dynamicColor(
        light: NSColor(red: 0.970, green: 0.981, blue: 0.994, alpha: 1),
        dark: NSColor(red: 0.112, green: 0.136, blue: 0.170, alpha: 1)
    )
    static let gutterNSColor = dynamicColor(
        light: NSColor(red: 0.978, green: 0.987, blue: 0.998, alpha: 1),
        dark: NSColor(red: 0.090, green: 0.112, blue: 0.143, alpha: 1)
    )
    static let hairlineNSColor = dynamicColor(
        light: NSColor(red: 0.24, green: 0.36, blue: 0.50, alpha: 0.12),
        dark: NSColor(red: 0.68, green: 0.78, blue: 0.90, alpha: 0.15)
    )
    static let quoteNSColor = dynamicColor(
        light: NSColor(red: 0.28, green: 0.44, blue: 0.62, alpha: 1),
        dark: NSColor(red: 0.60, green: 0.75, blue: 0.91, alpha: 1)
    )
    static let annotationNSColor = dynamicColor(
        light: NSColor(red: 0.22, green: 0.43, blue: 0.68, alpha: 1),
        dark: NSColor(red: 0.48, green: 0.68, blue: 0.92, alpha: 1)
    )
    static let codeNSColor = dynamicColor(
        light: NSColor(red: 0.27, green: 0.38, blue: 0.57, alpha: 1),
        dark: NSColor(red: 0.66, green: 0.76, blue: 0.91, alpha: 1)
    )
    static let highlightNSColor = dynamicColor(
        light: NSColor(red: 0.94, green: 0.72, blue: 0.20, alpha: 1),
        dark: NSColor(red: 0.93, green: 0.70, blue: 0.24, alpha: 1)
    )
    static let importantNSColor = dynamicColor(
        light: NSColor(red: 0.72, green: 0.18, blue: 0.21, alpha: 1),
        dark: NSColor(red: 0.96, green: 0.47, blue: 0.48, alpha: 1)
    )
    static let conceptNSColor = dynamicColor(
        light: NSColor(red: 0.15, green: 0.43, blue: 0.72, alpha: 1),
        dark: NSColor(red: 0.47, green: 0.70, blue: 0.95, alpha: 1)
    )
    static let underlineNSColor = dynamicColor(
        light: NSColor(red: 0.31, green: 0.43, blue: 0.58, alpha: 0.90),
        dark: NSColor(red: 0.63, green: 0.75, blue: 0.88, alpha: 0.90)
    )

    static let accent = Color(nsColor: accentNSColor)
    static let canvas = Color(nsColor: canvasNSColor)
    static let paper = Color(nsColor: paperNSColor)
    static let sidebar = Color(nsColor: sidebarNSColor)
    static let chrome = Color(nsColor: chromeNSColor)
    static let gutter = Color(nsColor: gutterNSColor)
    static let hairline = Color(nsColor: hairlineNSColor)
    static let quote = Color(nsColor: quoteNSColor)
    static let annotation = Color(nsColor: annotationNSColor)
    static let code = Color(nsColor: codeNSColor)
    static let highlight = Color(nsColor: highlightNSColor)
    static let important = Color(nsColor: importantNSColor)
    static let concept = Color(nsColor: conceptNSColor)
    static let underline = Color(nsColor: underlineNSColor)

    private static func dynamicColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? dark
                : light
        }
    }
}
