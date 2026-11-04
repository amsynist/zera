import Foundation
import CoreGraphics

public enum PhonePlacement: String, CaseIterable {
    case rightOfMac = "Right of Mac"
    case leftOfMac = "Left of Mac"
    case belowMac = "Below Mac"
    case aboveMac = "Above Mac"

    /// The Mac screen edge from which the card enters
    public var entryEdge: EdgePosition {
        switch self {
        case .rightOfMac: return .right
        case .leftOfMac: return .left
        case .belowMac: return .bottom
        case .aboveMac: return .top
        }
    }

    /// The Android edge that should be swiped
    public var phoneSwipeEdge: String {
        switch self {
        case .rightOfMac: return "Left Edge (swipe towards your left/Mac)"
        case .leftOfMac: return "Right Edge (swipe towards your right/Mac)"
        case .belowMac: return "Top Edge (swipe upwards towards Mac)"
        case .aboveMac: return "Bottom Edge (swipe downwards towards Mac)"
        }
    }
}
