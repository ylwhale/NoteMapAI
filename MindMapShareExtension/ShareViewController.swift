import Social
import UniformTypeIdentifiers

private struct SharedCapturePayload: Codable {
    let id: UUID
    let title: String
    let body: String
    let createdAt: Date
    let source: String
}

final class ShareViewController: SLComposeServiceViewController {
    override func isContentValid() -> Bool {
        true
    }

    override func didSelectPost() {
        Task { @MainActor in
            do {
                let values = await sharedValues()
                let editorText = (contentText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let combined = ([editorText] + values)
                    .filter { !$0.isEmpty }
                    .reduce(into: [String]()) { result, value in
                        guard !result.contains(value) else { return }
                        result.append(value)
                    }
                    .joined(separator: "\n\n")

                guard !combined.isEmpty else {
                    throw ShareCaptureError.emptyContent
                }

                try queueCapture(body: combined)
                extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            } catch {
                presentFailure(error.localizedDescription)
            }
        }
    }

    override func configurationItems() -> [Any]! {
        []
    }

    private func sharedValues() async -> [String] {
        var values: [String] = []
        let extensionItems = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []

        for item in extensionItems {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let value = await loadItem(from: provider, typeIdentifier: UTType.url.identifier) {
                    if let url = value as? URL {
                        values.append(url.absoluteString)
                    } else if let urlString = value as? String {
                        values.append(urlString)
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let value = await loadItem(from: provider, typeIdentifier: UTType.plainText.identifier),
                          let text = value as? String {
                    values.append(text)
                }
            }
        }
        return values
    }

    private func loadItem(from provider: NSItemProvider, typeIdentifier: String) async -> NSSecureCoding? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    private func queueCapture(body: String) throws {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.jyhuang28.MindMapAI"
        ) else {
            throw ShareCaptureError.appGroupUnavailable
        }

        let directory = container.appendingPathComponent("CaptureInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = SharedCapturePayload(
            id: UUID(),
            title: "",
            body: body,
            createdAt: .now,
            source: "shareExtension"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(
            to: directory
                .appendingPathComponent(payload.id.uuidString.lowercased())
                .appendingPathExtension("json"),
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
    }

    private func presentFailure(_ message: String) {
        let alert = UIAlertController(
            title: "Could not save to MindMap AI",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }
}

private enum ShareCaptureError: LocalizedError {
    case emptyContent
    case appGroupUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "Add or share some text before posting."
        case .appGroupUnavailable:
            return "The shared capture area is unavailable. Open MindMap AI once, then try again."
        }
    }
}
