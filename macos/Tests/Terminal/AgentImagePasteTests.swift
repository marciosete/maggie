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

    @Test func aShellIsNotAnAgent() {
        #expect(!AgentImagePaste.isAgent(pid: Int(getpid())))
        #expect(!AgentImagePaste.isAgent(pid: 0))
    }
}
