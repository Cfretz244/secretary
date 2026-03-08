import SwiftUI

struct ToolCallView: View {
    let toolCall: ChatMessage.ToolCallStatus
    @State private var isExpanded = false

    private var displayName: String {
        toolCall.name
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    var body: some View {
        if isExpanded {
            expandedCard
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)))
        } else {
            collapsedPill
                .transition(.opacity.combined(with: .scale(scale: 1.02, anchor: .topLeading)))
        }
    }

    // MARK: - Collapsed pill

    private var collapsedPill: some View {
        Button {
            guard canExpand else { return }
            withAnimation(.spring(duration: 0.35, bounce: 0.12)) {
                isExpanded = true
            }
        } label: {
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
                if canExpand {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.tertiary)
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
        .buttonStyle(.plain)
    }

    // MARK: - Expanded card

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button {
                withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
                    isExpanded = false
                }
            } label: {
                HStack(spacing: 6) {
                    statusIcon
                    Text(displayName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            // Input section
            if let input = toolCall.input, input != "{}", !input.isEmpty {
                sectionDivider
                codeSection(label: "INPUT", content: input, accent: .teal)
            }

            // Output section
            if let result = toolCall.result, !result.isEmpty {
                sectionDivider
                codeSection(label: "OUTPUT", content: result, accent: statusAccent)
            } else if case .failed(let reason) = toolCall.status {
                sectionDivider
                codeSection(label: "ERROR", content: reason, accent: .red)
            } else if case .running = toolCall.status {
                sectionDivider
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Running...")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(borderColor.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }

    // MARK: - Code section

    private func codeSection(label: String, content: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(accent.opacity(0.7))
                    .frame(width: 2, height: 9)
                Text(label)
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(accent.opacity(0.8))
                    .tracking(1.2)
            }

            Text(content)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.75))
                .lineLimit(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(8)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Shared components

    private var sectionDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 0.5)
            .padding(.horizontal, 12)
    }

    private var canExpand: Bool {
        toolCall.input != nil || toolCall.result != nil
    }

    private var statusAccent: Color {
        switch toolCall.status {
        case .running: .teal
        case .completed: .green
        case .failed: .red
        }
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

// MARK: - Wrapping layout that switches between flow and full-width for expanded cards

struct WrappingToolCallsView: View {
    let toolCalls: [ChatMessage.ToolCallStatus]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(toolCalls) { tool in
                ToolCallView(toolCall: tool)
            }
        }
    }
}
