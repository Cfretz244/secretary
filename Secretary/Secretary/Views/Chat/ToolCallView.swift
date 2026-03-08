import SwiftUI

struct ToolCallView: View {
    let toolCall: ChatMessage.ToolCallStatus

    var body: some View {
        HStack(spacing: 5) {
            statusIcon
            Text(toolCall.name)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
            if let detail = toolCall.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(pillBackground)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(borderColor.opacity(0.3), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch toolCall.status {
        case .running:
            Image(systemName: "gear")
                .font(.caption2)
                .foregroundStyle(.teal)
                .symbolEffect(.rotate, options: .repeating)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }

    private var pillBackground: some ShapeStyle {
        switch toolCall.status {
        case .running:
            AnyShapeStyle(Color.teal.opacity(0.08))
        case .completed:
            AnyShapeStyle(Color.green.opacity(0.06))
        case .failed:
            AnyShapeStyle(Color.red.opacity(0.06))
        }
    }

    private var borderColor: Color {
        switch toolCall.status {
        case .running: .teal
        case .completed: .green
        case .failed: .red
        }
    }
}
