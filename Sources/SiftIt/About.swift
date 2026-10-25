// About Sift It: its version, and the parts it's made with, each with its licence.

import AppKit

@MainActor
enum About {
    static func show() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// What the app ships, what that's built with, and the models it downloads.
    private static let parts: [(name: String, url: String, licence: String, role: String)] = [
        ("sift-it", "https://github.com/jwa91/sift-it", "MIT License", "the engine and the indexer, in the app"),
        ("llama.cpp", "https://github.com/ggml-org/llama.cpp", "MIT License", "runs the model, in sift-it"),
        (
            "FluidAudio", "https://github.com/FluidInference/FluidAudio", "Apache License 2.0",
            "by FluidInference, in sift-it-transcribe"
        ),
        (
            "EmbeddingGemma 2", "https://huggingface.co/google/embeddinggemma-2", "Apache License 2.0",
            "by Google DeepMind, downloaded once"
        ),
        (
            "Parakeet Ultra", "https://huggingface.co/FluidInference/parakeet-ultra-coreml", "CC BY 4.0",
            "by Moondream, from NVIDIA's Parakeet TDT 0.6B v3, in FluidInference's Core ML conversion, downloaded once"
        ),
    ]

    private static var credits: NSAttributedString {
        let text = NSMutableAttributedString()
        func add(
            _ string: String, size: CGFloat = 11, weight: NSFont.Weight = .regular, color: NSColor, after: CGFloat,
            link: String? = nil
        ) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.paragraphSpacing = after
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            attributes[.link] = link.flatMap(URL.init(string:))
            text.append(NSAttributedString(string: string, attributes: attributes))
        }
        for part in parts {
            add(part.name, weight: .semibold, color: .labelColor, after: 1, link: part.url)
            add(" · \(part.licence)\n", color: .secondaryLabelColor, after: 1)
            add(part.role + "\n", color: .secondaryLabelColor, after: 8)
        }
        add("Gemma is a trademark of Google LLC.", size: 10, color: .tertiaryLabelColor, after: 0)
        return text
    }
}
