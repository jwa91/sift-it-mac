// About Sift It, the settings' last pane: its version, who made it and where its source is, and the parts it's made
// with, each with its licence.

import SwiftUI

struct AboutPane: View {
    private struct Part: Identifiable {
        let name: String
        let url: String
        let licence: String
        let role: String
        var id: String { name }
    }

    /// What the app ships, what that's built with, and the models it downloads.
    private static let parts: [Part] = [
        Part(
            name: "sift-it", url: "https://github.com/jwa91/sift-it", licence: "MIT License",
            role: "The engine and the indexer, in the app"),
        Part(
            name: "llama.cpp", url: "https://github.com/ggml-org/llama.cpp", licence: "MIT License",
            role: "Runs EmbeddingGemma 2, in sift-it"),
        Part(
            name: "FluidAudio", url: "https://github.com/FluidInference/FluidAudio", licence: "Apache License 2.0",
            role: "By FluidInference, in sift-it-transcribe"),
        Part(
            name: "EmbeddingGemma 2", url: "https://huggingface.co/google/embeddinggemma-2",
            licence: "Apache License 2.0", role: "By Google DeepMind, downloaded once"),
        Part(
            name: "Parakeet Ultra", url: "https://huggingface.co/FluidInference/parakeet-ultra-coreml",
            licence: "CC BY 4.0",
            role: "By Moondream, from NVIDIA's Parakeet TDT 0.6B v3, in FluidInference's Core ML conversion, "
                + "downloaded once"),
    ]

    private static let site = URL(string: "https://www.janwillemaltink.com")!
    private static let source = URL(string: "https://github.com/jwa91/sift-it")!

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sift It").font(.title2.weight(.semibold))
                        Text("Version \(Self.info("CFBundleShortVersionString"))")
                            .foregroundStyle(.secondary)
                        Text(Self.info("NSHumanReadableCopyright"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                LabeledContent("Website") { Link("janwillemaltink.com", destination: Self.site) }
                LabeledContent("Source code") { Link("github.com/jwa91/sift-it", destination: Self.source) }
            }
            Section {
                ForEach(Self.parts) { part in
                    LabeledContent {
                        Text(part.licence)
                    } label: {
                        Link(part.name, destination: URL(string: part.url)!)
                        Text(part.role)
                    }
                }
            } header: {
                Text("Made with")
            } footer: {
                Text("Gemma is a trademark of Google LLC.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private static func info(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
    }
}
