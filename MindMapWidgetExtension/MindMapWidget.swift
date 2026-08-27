import SwiftUI
import WidgetKit

private struct MindMapCaptureEntry: TimelineEntry {
    let date: Date
}

private struct MindMapCaptureProvider: TimelineProvider {
    func placeholder(in context: Context) -> MindMapCaptureEntry {
        MindMapCaptureEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (MindMapCaptureEntry) -> Void) {
        completion(MindMapCaptureEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MindMapCaptureEntry>) -> Void) {
        completion(Timeline(entries: [MindMapCaptureEntry(date: .now)], policy: .never))
    }
}

private struct MindMapCaptureWidgetView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.teal)

            Spacer(minLength: 0)

            Text("Capture a thought")
                .font(.headline)
                .foregroundStyle(.primary)

            Text("Open quick capture in MindMap AI")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.background, for: .widget)
        .widgetURL(URL(string: "mindmapai://capture"))
        .accessibilityLabel("Capture a thought in MindMap AI")
        .accessibilityHint("Opens quick capture")
    }
}

private struct MindMapCaptureWidget: Widget {
    let kind = "MindMapCaptureWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MindMapCaptureProvider()) { _ in
            MindMapCaptureWidgetView()
        }
        .configurationDisplayName("Quick Capture")
        .description("Open MindMap AI and save a thought quickly.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct MindMapWidgetBundle: WidgetBundle {
    var body: some Widget {
        MindMapCaptureWidget()
    }
}
