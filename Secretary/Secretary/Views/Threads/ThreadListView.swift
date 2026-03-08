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
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(thread.title.isEmpty ? "New Thread" : thread.title)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(thread.createdAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if thread.isStreaming {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            if thread.id == threadManager.activeThreadId {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
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
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        threadManager.createThread()
                        dismiss()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }
}
