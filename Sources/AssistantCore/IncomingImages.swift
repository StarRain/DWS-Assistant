import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImageResource: Equatable {
    public let type: String
    public let id: String
    public let messageID: String
    public let conversationID: String
}

public enum IncomingImages {
    public static func resources(_ result: CommandResult, event: IMEvent) throws -> [ImageResource] {
        let data = JSONOutput.payload(try JSONOutput.object(result))
        guard data["messagesComplete"] as? Bool != false, let rows = data["messages"] as? [[String: Any]] else {
            throw AssistantError.command("图片消息详情读取失败")
        }
        let requested = Set(event.imageMessageIDs)
        var resources: [ImageResource] = []
        for row in rows where requested.contains(JSONOutput.string(row, "messageId")) {
            guard JSONOutput.string(row, "conversationId") == event.conversationID else { throw AssistantError.invalid("图片消息与当前会话不一致") }
            let imageMessage = ["image", "picture"].contains(JSONOutput.string(row, "messageType").lowercased())
            let imageText = IMEvent.mayContainImage(JSONOutput.string(row, "text"))
            for ref in row["resourceRefs"] as? [[String: Any]] ?? [] {
                let kind = JSONOutput.string(ref, "contentType").lowercased()
                let ext = (JSONOutput.string(ref, "name") as NSString).pathExtension.lowercased()
                guard ["image", "picture"].contains(kind) || ["jpg", "jpeg", "png", "webp", "gif", "heic", "heif"].contains(ext)
                        || (kind.isEmpty && (imageMessage || imageText)) else { continue }
                guard let download = ref["download"] as? [String: Any], download["ready"] as? Bool == true,
                      let args = download["arguments"] as? [String: Any] else { throw AssistantError.command("图片缺少可用下载信息") }
                let type = JSONOutput.string(ref, "resourceIdType", "type"), id = JSONOutput.string(ref, "resourceId")
                guard ["mediaId", "fileId"].contains(type) else { continue }
                let messageID = JSONOutput.string(args, "message-id").nonempty ?? JSONOutput.string(row, "messageId")
                let conversationID = JSONOutput.string(args, "open-conversation-id").nonempty ?? event.conversationID
                // Do not follow resources belonging to another forwarded chat.
                guard requested.contains(messageID), conversationID == event.conversationID else { continue }
                try Validation.stableID(id, name: "图片资源 ID")
                let resource = ImageResource(type: type, id: id, messageID: messageID, conversationID: conversationID)
                if !resources.contains(resource) { resources.append(resource) }
            }
        }
        guard !resources.isEmpty else { throw AssistantError.command("没有取得可读取的图片，请发送原图后重试") }
        guard resources.count <= ImageCache.maximumImages else { throw AssistantError.invalid("每条消息最多识别 4 张图片，请分开发送") }
        return resources
    }
}

public struct ImageCacheLease {
    public let id: UUID
    public let directory: URL
    public let count: Int
}

/// Reservations include both the bounded download and its normalized image.
/// Only app-owned per-turn directories live here; finished turns retain no bytes.
@MainActor public final class ImageCache {
    public nonisolated static let maximumImages = 4
    public nonisolated static let maximumImageBytes = 8 * 1024 * 1024
    public nonisolated static let maximumCacheBytes = 64 * 1024 * 1024
    public let directory: URL
    private let capacity: Int
    private var reservations: [UUID: Int] = [:]
    public var reservedBytes: Int { reservations.values.reduce(0, +) }

    public init(directory: URL, capacity: Int = ImageCache.maximumCacheBytes) throws {
        let files = FileManager.default
        if files.fileExists(atPath: directory.path),
           try files.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeSymbolicLink {
            throw AssistantError.storage("图片缓存目录不能是符号链接")
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.directory = directory.resolvingSymlinksInPath().standardizedFileURL
        self.capacity = capacity
        for entry in try files.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil) {
            // A previous process can leave partial downloads after a crash.
            if entry.lastPathComponent.hasPrefix("turn-") { try files.removeItem(at: entry) }
        }
    }

    public func reserve(count: Int) throws -> ImageCacheLease {
        guard (1...Self.maximumImages).contains(count) else { throw AssistantError.invalid("每条消息最多识别 4 张图片") }
        let bytes = count * Self.maximumImageBytes * 2
        guard reservedBytes + bytes <= capacity else { throw AssistantError.storage("图片处理繁忙，缓存已达 64 MB 上限，请稍后重试") }
        let id = UUID(), folder = directory.appendingPathComponent("turn-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        reservations[id] = bytes
        return ImageCacheLease(id: id, directory: folder, count: count)
    }

    public func release(_ lease: ImageCacheLease) throws {
        guard reservations[lease.id] != nil else { return }
        if FileManager.default.fileExists(atPath: lease.directory.path) { try FileManager.default.removeItem(at: lease.directory) }
        reservations.removeValue(forKey: lease.id)
    }

    public func image(from result: CommandResult, resource: ImageResource, index: Int, lease: ImageCacheLease) throws -> String {
        guard reservations[lease.id] != nil, (0..<lease.count).contains(index) else { throw AssistantError.storage("图片缓存已失效") }
        let row = JSONOutput.payload(try JSONOutput.object(result))
        guard JSONOutput.string(row, "resourceId") == resource.id else { throw AssistantError.invalid("图片下载结果与请求不一致") }
        let relative = JSONOutput.string(row, "localPath")
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { throw AssistantError.invalid("图片下载路径无效") }
        let source = lease.directory.appendingPathComponent(relative).standardizedFileURL
        guard source.resolvingSymlinksInPath().path == source.path,
              source.path.hasPrefix(lease.directory.path + "/") else { throw AssistantError.invalid("图片下载路径越界") }
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber, bytes.intValue > 0, bytes.intValue <= Self.maximumImageBytes else {
            throw AssistantError.invalid("图片超过 8 MB 限制或文件无效")
        }
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0, width.doubleValue * height.doubleValue <= 40_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) else {
            throw AssistantError.invalid("图片无法解码或尺寸过大，未交给 AI")
        }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else { throw AssistantError.storage("无法准备图片") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), encoded.length <= Self.maximumImageBytes else { throw AssistantError.invalid("图片转换后超过 8 MB 限制") }
        let output = lease.directory.appendingPathComponent("image-\(index).jpg")
        try (encoded as Data).write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        try FileManager.default.removeItem(at: source)
        return output.path
    }
}
