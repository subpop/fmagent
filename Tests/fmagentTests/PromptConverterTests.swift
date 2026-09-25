import ACPKit
import Foundation
import Testing

@testable import fmagent

@Test func convertsTextBlocks() throws {
    let prompt = try PromptConverter.convert([
        .text(TextContent(text: "hello")),
        .text(TextContent(text: "world")),
    ])
    #expect(prompt.text == "hello\n\nworld")
    #expect(prompt.images.isEmpty)
}

@Test func convertsResourcesAndLinks() throws {
    let prompt = try PromptConverter.convert([
        .resourceLink(ResourceLink(name: "main.swift", uri: "file:///a/main.swift")),
        .resource(EmbeddedResource(resource: .text(
            TextResourceContents(text: "let x = 1", uri: "file:///a/x.swift")))),
    ])
    #expect(prompt.text.contains("main.swift"))
    #expect(prompt.text.contains("let x = 1"))
}

@Test func convertsValidImage() throws {
    let data = Data([0x89, 0x50, 0x4E, 0x47])
    let prompt = try PromptConverter.convert([
        .image(ImageContent(data: data.base64EncodedString(), mimeType: "image/png"))
    ])
    #expect(prompt.images.count == 1)
    #expect(prompt.images[0].data == data)
}

@Test func rejectsBadImageAndAudioAndBlob() {
    #expect(throws: AgentError.invalidParams("Image content is not valid base64")) {
        try PromptConverter.convert([.image(ImageContent(data: "!!!", mimeType: "image/png"))])
    }
    #expect(throws: AgentError.invalidParams(
        "Audio content is not supported by the backing model"))
    {
        try PromptConverter.convert([.audio(AudioContent(data: "AAA", mimeType: "audio/mp3"))])
    }
    #expect(throws: AgentError.self) {
        try PromptConverter.convert([.resource(EmbeddedResource(resource: .blob(
            BlobResourceContents(blob: "AAA", uri: "file:///a.bin"))))])
    }
}

@Test func summarizeNotesImages() {
    let summary = PromptConverter.summarize(ConvertedPrompt(
        text: "hi", images: [.init(data: Data(), mimeType: "image/jpeg")]))
    #expect(summary.contains("hi"))
    #expect(summary.contains("[image: image/jpeg]"))
}
