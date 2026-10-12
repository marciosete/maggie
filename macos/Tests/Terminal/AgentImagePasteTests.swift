import AppKit
import Testing
@testable import Ghostty

@Suite
struct AgentImagePasteTests {
    /// A pasteboard of its own, released after `body`.
    @MainActor
    private func withPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard(name: .init("maggie-image-paste-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        try body(pasteboard)
    }

    private var png: Data {
        let image = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        return image?.representation(using: .png, properties: [:]) ?? Data()
    }

    @Test @MainActor func anImageAloneIsForTheAgent() {
        withPasteboard { pasteboard in
            pasteboard.declareTypes([.png], owner: nil)
            pasteboard.setData(png, forType: .png)
            #expect(AgentImagePaste.hasOnlyImage(pasteboard))
        }
    }

    @Test @MainActor func textIsPastedAsUsual() {
        withPasteboard { pasteboard in
            #expect(!AgentImagePaste.hasOnlyImage(pasteboard))

            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString("hello", forType: .string)
            #expect(!AgentImagePaste.hasOnlyImage(pasteboard))

            // An image copied with its text, as from a web page or a document.
            pasteboard.declareTypes([.png, .string], owner: nil)
            pasteboard.setData(png, forType: .png)
            pasteboard.setString("hello", forType: .string)
            #expect(!AgentImagePaste.hasOnlyImage(pasteboard))
        }
    }

    /// Safari's Copy Image puts the image's URL beside it as text.
    @Test @MainActor func anImageCopiedWithItsAddressIsForTheAgent() {
        withPasteboard { pasteboard in
            pasteboard.declareTypes([.tiff, .URL, .string], owner: nil)
            pasteboard.setData(png, forType: .tiff)
            pasteboard.setString("https://example.com/cat.png", forType: .URL)
            pasteboard.setString("https://example.com/cat.png", forType: .string)
            #expect(AgentImagePaste.hasOnlyImage(pasteboard))
        }
    }

    @Test @MainActor func aCopiedFilePastesItsPath() {
        withPasteboard { pasteboard in
            let url = URL(fileURLWithPath: "/Users/me/Desktop/shot.png")
            pasteboard.declareTypes([.fileURL, .png], owner: nil)
            pasteboard.setString(url.absoluteString, forType: .fileURL)
            pasteboard.setData(png, forType: .png)
            #expect(!AgentImagePaste.hasOnlyImage(pasteboard))
        }
    }

    @Test func onlyOneWebAddressCountsAsTheImagesAddress() {
        #expect(AgentImagePaste.isWebAddress(" https://example.com/a.png\n"))
        #expect(AgentImagePaste.isWebAddress("http://x.io"))
        #expect(!AgentImagePaste.isWebAddress("see https://example.com"))
        #expect(!AgentImagePaste.isWebAddress("file:///tmp/a.png"))
        #expect(!AgentImagePaste.isWebAddress("cat.png"))
        #expect(!AgentImagePaste.isWebAddress(""))
    }

    /// The native install runs a binary named for its version, started as `claude`;
    /// an npm install runs node with the package's script.
    @Test func claudeCodeIsKnownByItsCommand() {
        #expect(AgentImagePaste.isClaudeCode("2.1.4", arguments: ["claude", "--resume"]))
        #expect(AgentImagePaste.isClaudeCode("claude", arguments: []))
        #expect(AgentImagePaste.isClaudeCode(
            "node", arguments: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]))
        #expect(AgentImagePaste.isClaudeCode("node", arguments: ["node", "/Users/me/.npm-global/bin/claude"]))
        #expect(!AgentImagePaste.isClaudeCode("zsh", arguments: ["-zsh"]))
        #expect(!AgentImagePaste.isClaudeCode("vim", arguments: ["vim", "claude.md"]))
    }

    @Test func aShellIsNotAnAgent() {
        #expect(!AgentImagePaste.isAgent(pid: Int(getpid())))
        #expect(!AgentImagePaste.isAgent(pid: 0))
    }
}
