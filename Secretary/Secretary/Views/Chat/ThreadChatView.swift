import SwiftUI

struct ThreadChatView: View {
    @ObservedObject var thread: ThreadState
    @EnvironmentObject var threadManager: ThreadManager
    @State private var isNearBottom = true

    var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(thread.messages) { message in
                            MessageBubbleView(message: message)
                                .id(message.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                            .onAppear { isNearBottom = true }
                            .onDisappear { isNearBottom = false }
                    }
                    .padding()
                }
                .onChange(of: thread.messages.count) { _, _ in
                    if isNearBottom, let last = thread.messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: thread.messages.last?.text) { _, _ in
                    if isNearBottom {
                        proxy.scrollTo("bottom")
                    }
                }
                .onChange(of: thread.messages.last?.toolCalls) { _, _ in
                    if isNearBottom {
                        proxy.scrollTo("bottom")
                    }
                }
            }

            Divider()

            // Input bar
            HStack(spacing: 12) {
                TextField("Message...", text: $thread.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .onSubmit {
                        threadManager.sendMessage(in: thread)
                    }

                Button {
                    if thread.isStreaming {
                        threadManager.stopStreaming(in: thread)
                    } else {
                        threadManager.sendMessage(in: thread)
                    }
                } label: {
                    Image(systemName: thread.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(thread.isStreaming ? .red :
                            thread.inputText.trimmingCharacters(in: .whitespaces).isEmpty ? .gray : .blue)
                }
                .disabled(thread.inputText.trimmingCharacters(in: .whitespaces).isEmpty && !thread.isStreaming)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}
