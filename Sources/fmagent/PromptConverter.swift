import ACPKit
import Foundation

/// ACP `ContentBlock` values converted into model input.
///
/// `text` is the concatenated plain-text prompt. `images` carries raw image
/// bytes (plus MIME type) for backends that support multimodal input; audio
/// and binary resource blobs are rejected during conversion.
public struct ConvertedPrompt: Sendable, Equatable {
    public struct Image: Sendable, Equatable {
        public var data: Data
        public var mimeType: String

        public init(data: Data, mimeType: String) {
            self.data = data
            self.mimeType = mimeType
        }
    }

    public var text: String
    public var images: [Image]

    public init(text: String, images: [Image] = []) {
        self.text = text
        self.images = images
    }
}

public enum PromptConverter {
    /// Converts ACP prompt blocks into a single text prompt plus images.
    ///
    /// - Text blocks are joined with blank lines.
    /// - Embedded text resources are inlined under their URI.
    /// - Resource links are referenced by name/URI (content stays client-side).
    /// - Images are validated (base64 must decode) and passed through.
    /// - Audio blocks and binary resource blobs throw
    ///   ``AgentError/invalidParams`` since the backing model cannot consume them.
    public static func convert(_ blocks: [ContentBlock]) throws -> ConvertedPrompt {
        var textParts: [String] = []
        var images: [ConvertedPrompt.Image] = []

        for block in blocks {
            switch block {
            case .text(let content):
                if !content.text.isEmpty {
                    textParts.append(content.text)
                }
            case .resourceLink(let link):
                var reference = "Resource: \(link.name) (\(link.uri))"
                if let description = link.description, !description.isEmpty {
                    reference += " — \(description)"
                }
                textParts.append(reference)
            case .resource(let embedded):
                switch embedded.resource {
                case .text(let contents):
                    textParts.append("[\(contents.uri)]\n\(contents.text)")
                case .blob:
                    throw AgentError.invalidParams(
                        "Binary resource content is not supported; send text resources instead")
                }
            case .image(let content):
                guard let data = Data(base64Encoded: content.data) else {
                    throw AgentError.invalidParams("Image content is not valid base64")
                }
                images.append(ConvertedPrompt.Image(data: data, mimeType: content.mimeType))
            case .audio:
                throw AgentError.invalidParams(
                    "Audio content is not supported by the backing model")
            }
        }

        return ConvertedPrompt(text: textParts.joined(separator: "\n\n"), images: images)
    }

    /// Short plain-text summary of a prompt for the session replay log.
    /// Images are represented by a placeholder (bytes are not logged).
    public static func summarize(_ prompt: ConvertedPrompt) -> String {
        var summary = prompt.text
        for image in prompt.images {
            if !summary.isEmpty {
                summary += "\n\n"
            }
            summary += "[image: \(image.mimeType)]"
        }
        return summary
    }
}
