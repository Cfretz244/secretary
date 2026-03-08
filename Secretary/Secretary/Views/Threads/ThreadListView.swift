import SwiftUI

struct ThreadListView: View {
    @EnvironmentObject var threadManager: ThreadManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(threadManager.threads) { thread in
                    Button {
                        threadManager.switchToThread(id: thread.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(thread.title.isEmpty ? "New Thread" : thread.title)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                if let preview = thread.messages.last(where: { $0.role == .assistant && !$0.text.isEmpty })?.text {
                                    Text(preview)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }

                                Text(thread.createdAt, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.quaternary)
                            }

                            Spacer()

                            if thread.isStreaming {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.teal)
                            }

                            if thread.id == threadManager.activeThreadId {
                                Image(systemName: "checkmark")
                                    .font(.caption)
                                    .foregroundStyle(.teal)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { threadManager.threads[$0].id }
                    for id in ids {
                        threadManager.deleteThread(id: id)
                    }
                }
            }
            .navigationTitle("Threads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                    .tint(.teal)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        threadManager.createThread()
                        dismiss()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .tint(.teal)
                }
            }
        }
    }
}
