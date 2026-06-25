import AppKit
import SwiftUI

enum AgentSessionLightColor {
    static func nsColor(for state: AgentSessionLightState) -> NSColor {
        switch state {
        case .empty:
            return .separatorColor
        case .working:
            return .systemGreen
        case .idle:
            return .systemYellow
        case .error:
            return .systemRed
        }
    }

    static func swiftUIColor(for state: AgentSessionLightState) -> Color {
        Color(nsColor: nsColor(for: state))
    }
}
