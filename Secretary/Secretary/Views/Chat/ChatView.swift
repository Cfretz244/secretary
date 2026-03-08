import SwiftUI

struct ChatView: View {
    @EnvironmentObject var threadManager: ThreadManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showThreadList = false

    var body: some View {
        NavigationStack {
            Group {
                if let thread = threadManager.activeThread {
                    ThreadChatView(thread: thread)
                } else {
                    ContentUnavailableView("No Thread", systemImage: "bubble.left",
                        description: Text("Create a new thread to get started."))
                }
            }
            .navigationTitle(threadManager.activeThread?.title.isEmpty == false
                ? threadManager.activeThread!.title : "New Thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showThreadList = true
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "list.bullet")
                            if threadManager.threads.contains(where: {
                                $0.isStreaming && $0.id != threadManager.activeThreadId
                            }) {
                                Circle()
                                    .fill(.teal)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 4, y: -4)
                            }
                        }
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
            .sheet(isPresented: $showThreadList) {
                ThreadListView()
            }
            .onChange(of: scenePhase) { _, newPhase in
                threadManager.handleScenePhase(newPhase)
            }
            .tint(.teal)
        }
    }
}
