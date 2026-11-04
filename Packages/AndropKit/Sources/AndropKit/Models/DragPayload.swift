import Foundation
import CoreGraphics

public enum EdgePosition: String, Codable {
    case right = "RIGHT"
    case left = "LEFT"
    case bottom = "BOTTOM"
    case top = "TOP"
}

public enum DragAction: String, Codable {
    case commit = "COMMIT"
    case cancel = "CANCEL"
}

public struct DragEnterEvent: Codable {
    public let type: String
    public let id: String
    public let name: String
    public let mimeType: String
    public let thumbnail: String // Base64 data URL or raw base64
    public let edge: EdgePosition?

    public init(id: String, name: String, mimeType: String, thumbnail: String, edge: EdgePosition? = .right) {
        self.type = "DRAG_ENTER"
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.thumbnail = thumbnail
        self.edge = edge
    }
}

public struct DragUpdateEvent: Codable {
    public let type: String
    public let id: String
    public let normalizedY: CGFloat // 0.0 to 1.0 (relative vertical position)
    public let crossRatio: CGFloat   // 0.0 to 1.0 (fraction of card crossing the boundary)
    public let velocityX: CGFloat?
    public let velocityY: CGFloat?
}

public struct DragReleaseEvent: Codable {
    public let type: String
    public let id: String
    public let action: DragAction
    public let velocityX: CGFloat
    public let velocityY: CGFloat
    public var stream: Bool? = nil
    public var size: Int64? = nil
    public let fullData: String? // Optional full base64 data if not streamed via chunks
}

public struct TransferEndEvent: Codable {
    public let type: String
    public let id: String
    public let bytes: Int64
    public let sha256: String
}

public enum ClientMessage {
    case enter(DragEnterEvent)
    case update(DragUpdateEvent)
    case release(DragReleaseEvent)
    case end(TransferEndEvent)
    case ping
    case unknown(String)
}

public func parseClientMessage(jsonString: String) -> ClientMessage {
    guard let data = jsonString.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String else {
        return .unknown(jsonString)
    }

    let decoder = JSONDecoder()
    switch type {
    case "DRAG_ENTER":
        if let event = try? decoder.decode(DragEnterEvent.self, from: data) {
            return .enter(event)
        }
    case "DRAG_UPDATE":
        if let event = try? decoder.decode(DragUpdateEvent.self, from: data) {
            return .update(event)
        }
    case "DRAG_RELEASE":
        if let event = try? decoder.decode(DragReleaseEvent.self, from: data) {
            return .release(event)
        }
    case "TRANSFER_END":
        if let event = try? decoder.decode(TransferEndEvent.self, from: data) { return .end(event) }
    case "PING":
        return .ping
    default:
        break
    }
    return .unknown(jsonString)
}
