import Foundation
import AppKit

enum ImageWorkflow {
    static func intent(_ query: String) -> String? {
        let q = query.lowercased()
        if ["rimuovi lo sfondo", "remove the background", "cambia il colore", "modifica questa immagine", "edit this image"].contains(where: q.contains) { return "edit" }
        if ["genera un'immagine", "crea un'immagine", "generate an image", "draw ", "disegna "].contains(where: q.contains) { return "generate" }
        return nil
    }
    static func tool(model: String, size: String, transparent: Bool, action: String?) throws -> [String: Any] {
        guard let url = Bundle.main.url(forResource: "OpenAIModels", withExtension: "json"), let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw OpenAIError.message("Image configuration missing.") }
        let selected = model.isEmpty ? catalog["defaultImageModel"] as? String ?? "" : model
        guard (catalog["imageModels"] as? [String] ?? []).contains(selected), ["auto", "1024x1024", "1536x1024", "1024x1536"].contains(size) else { throw OpenAIError.message("Unsupported image model or size.") }
        return ["type": "image_generation", "model": selected, "size": size, "background": transparent ? "transparent" : "auto", "output_format": "png", "action": action ?? "auto"]
    }
    static func parse(_ output: [[String: Any]]) throws -> [String] {
        try output.filter { $0["type"] as? String == "image_generation_call" }.map { item in
            guard item["status"] as? String == "completed", let encoded = item["result"] as? String, encoded.count <= 68_000_000,
                  let data = Data(base64Encoded: encoded), validPNG(data), NSImage(data: data) != nil else { throw OpenAIError.message("Invalid or oversized generated PNG image.") }
            return encoded
        }
    }
    static func validPNG(_ data: Data) -> Bool {
        guard data.count >= 45, data.count <= 50_000_000, data.starts(with: [137,80,78,71,13,10,26,10]), Array(data[12..<16]) == [73,72,68,82], data.suffix(12) == Data([0,0,0,0,73,69,78,68,174,66,96,130]) else { return false }
        let width = data[16..<20].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let height = data[20..<24].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return width > 0 && height > 0 && width <= 16384 && height <= 16384 && width * height <= 32_000_000
    }
    @MainActor @discardableResult static func save(_ encoded: String, chooseURL: () -> URL? = {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "coucou-image.png"
        return panel.runModal() == .OK ? panel.url : nil
    }) -> Bool {
        guard let data = Data(base64Encoded: encoded), validPNG(data), NSImage(data: data) != nil, let url = chooseURL() else { return false }
        do { try data.write(to: url, options: .atomic); return true }
        catch { AppState.shared.noteMessage = "Could not save image."; AppState.shared.view = .note; return false }
    }
}
