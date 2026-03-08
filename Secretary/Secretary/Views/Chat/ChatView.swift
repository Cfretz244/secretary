import SwiftUI

struct ChatView: View {
    @StateObject private var viewModel = ChatViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var isNearBottom = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(viewModel.messages) { message in
                                MessageBubbleView(message: message)
                                    .id(message.id)
                            }
                            // Anchor at the very bottom for scroll tracking
                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                                .onAppear { isNearBottom = true }
                                .onDisappear { isNearBottom = false }
                        }
                        .padding()
                    }
                    .onChange(of: viewModel.messages.count) { _, _ in
                        if isNearBottom, let last = viewModel.messages.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: viewModel.messages.last?.text) { _, _ in
                        if isNearBottom {
                            proxy.scrollTo("bottom")
                        }
                    }
                    .onChange(of: viewModel.messages.last?.toolCalls) { _, _ in
                        if isNearBottom {
                            proxy.scrollTo("bottom")
                        }
                    }
                }

                Divider()

                // Input bar
                HStack(spacing: 12) {
                    TextField("Message...", text: $viewModel.inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .onSubmit {
                            viewModel.sendMessage()
                        }

                    Button {
                        if viewModel.isStreaming {
                            viewModel.stopStreaming()
                        } else {
                            viewModel.sendMessage()
                        }
                    } label: {
                        Image(systemName: viewModel.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(viewModel.isStreaming ? .red :
                                viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty ? .gray : .blue)
                    }
                    .disabled(viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty && !viewModel.isStreaming)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)
            }
            .navigationTitle("Secretary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        viewModel.clearConversation()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .onAppear {
                viewModel.setup()
            }
            .onChange(of: scenePhase) { _, newPhase in
                viewModel.handleScenePhase(newPhase)
            }
        }
    }
}
