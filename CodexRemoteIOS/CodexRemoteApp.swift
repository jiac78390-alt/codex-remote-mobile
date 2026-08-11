import SwiftUI
import AVFoundation
import PhotosUI
import QuickLook
import Speech
import UIKit
import UniformTypeIdentifiers

@main
struct CodexRemoteApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

private enum Palette {
    static let canvas = Color.black
    static let sidebar = Color(red: 0.055, green: 0.058, blue: 0.060)
    static let panel = Color.black
    static let raised = Color(red: 0.145, green: 0.148, blue: 0.152)
    static let composer = Color(red: 0.115, green: 0.118, blue: 0.122)
    static let line = Color.white.opacity(0.10)
    static let text = Color.white
    static let textMuted = Color.white.opacity(0.62)
    static let textSoft = Color.white.opacity(0.42)
    static let idle = Color.white.opacity(0.24)
    static let codeText = Color.white.opacity(0.88)
    static let accent = Color(red: 0.24, green: 0.82, blue: 0.60)
    static let blue = Color(red: 0.35, green: 0.61, blue: 1.00)
    static let amber = Color(red: 0.96, green: 0.68, blue: 0.27)
    static let red = Color(red: 1.00, green: 0.34, blue: 0.39)
    static let teal = Color(red: 0.22, green: 0.75, blue: 0.78)
}

private extension View {
    @ViewBuilder
    func codexPopoverPresentation() -> some View {
        if #available(iOS 16.4, *) {
            presentationCompactAdaptation(.popover)
        } else {
            self
        }
    }
}

private enum ConnectionRoute: String, CaseIterable, Identifiable {
    case tailscale
    case local

    var id: String { rawValue }
    var title: String { self == .tailscale ? "Tailscale" : "局域网" }
}

private enum InspectorTab: String, CaseIterable, Identifiable {
    case activity = "活动"
    case files = "文件"
    case diff = "Diff"

    var id: String { rawValue }
}

private enum TaskListFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case drafts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部任务"
        case .active: return "正在运行"
        case .drafts: return "有草稿"
        }
    }

    var icon: String {
        switch self {
        case .all: return "line.3.horizontal.decrease.circle"
        case .active: return "bolt.circle.fill"
        case .drafts: return "square.and.pencil.circle.fill"
        }
    }
}

struct RootView: View {
    @StateObject private var client = RemoteClient()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("codexRemote.host") private var host = ""
    @AppStorage("codexRemote.port") private var port = "8765"
    @State private var token = ""
    @AppStorage("codexRemote.route") private var route = ConnectionRoute.tailscale.rawValue
    @State private var attemptedConnection = false

    var body: some View {
        Group {
            if client.state == .connected || (attemptedConnection && !client.tasks.isEmpty) {
                WorkspaceView(client: client) {
                    client.disconnect()
                    attemptedConnection = false
                }
            } else {
                ConnectionView(
                    client: client,
                    host: $host,
                    port: $port,
                    token: $token,
                    route: $route,
                    attemptedConnection: $attemptedConnection
                )
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if token.isEmpty { token = client.savedPairingToken }
            connectIfConfigured()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                if attemptedConnection { client.resumeConnection() }
                else { connectIfConfigured() }
            } else {
                client.persistLocalState()
                client.pauseConnectionMonitoring()
            }
        }
    }

    private func connectIfConfigured() {
        guard !attemptedConnection, !host.isEmpty, !token.isEmpty else { return }
        attemptedConnection = true
        client.connect(host: host, port: port, token: token)
    }
}

private struct ConnectionView: View {
    @ObservedObject var client: RemoteClient
    @Binding var host: String
    @Binding var port: String
    @Binding var token: String
    @Binding var route: String
    @Binding var attemptedConnection: Bool
    @State private var showsToken = false

    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 12) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Codex Remote").font(.title2.bold())
                            Text("连接这台 Mac").font(.subheadline).foregroundStyle(Palette.textMuted)
                        }
                    }

                    Picker("连接方式", selection: $route) {
                        ForEach(ConnectionRoute.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)

                    VStack(spacing: 0) {
                        inputRow(icon: "desktopcomputer", title: "Mac 地址") {
                            TextField("100.x.x.x", text: $host)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                        }
                        Divider().overlay(Palette.line).padding(.leading, 48)
                        inputRow(icon: "network", title: "端口") {
                            TextField("8765", text: $port)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                        Divider().overlay(Palette.line).padding(.leading, 48)
                        inputRow(icon: "key.fill", title: "配对密钥") {
                            HStack(spacing: 6) {
                                Group {
                                    if showsToken { TextField("Mac 菜单栏中复制", text: $token) }
                                    else { SecureField("Mac 菜单栏中复制", text: $token) }
                                }
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                                Button { showsToken.toggle() } label: {
                                    Image(systemName: showsToken ? "eye.slash" : "eye").frame(width: 30, height: 30)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(showsToken ? "隐藏密钥" : "显示密钥")
                            }
                        }
                    }
                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(Palette.line) }

                    if case .failed(let message) = client.state {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Palette.amber)
                    }

                    Button {
                        attemptedConnection = true
                        client.connect(host: host, port: port, token: token)
                    } label: {
                        HStack(spacing: 8) {
                            if client.state == .connecting { ProgressView().tint(.white) }
                            Text(client.state == .connecting ? "正在连接" : "连接")
                            if client.state != .connecting { Image(systemName: "arrow.right") }
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Palette.accent, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(client.state == .connecting)
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 22)
                .padding(.top, 42)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func inputRow<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Palette.textMuted).frame(width: 24)
            Text(title).font(.subheadline.weight(.medium))
            Spacer(minLength: 12)
            content().frame(maxWidth: 280)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 54)
    }
}

private struct WorkspaceView: View {
    @ObservedObject var client: RemoteClient
    let disconnect: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var search = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var inspectorPresented = false
    @State private var phonePath: [String] = []
    @State private var shouldResumeLastTask = true

    var body: some View {
        workspaceNavigation
        .tint(Palette.accent)
        .safeAreaInset(edge: .top, spacing: 0) { messageBanner }
        .animation(.easeOut(duration: 0.2), value: client.lastMessage)
        .sheet(isPresented: $inspectorPresented) { inspectorSheet }
        .sheet(item: $client.pendingApproval) { approval in
            ApprovalSheet(client: client, approval: approval)
                .presentationDetents([.medium, .large])
        }
        .quickLookPreview($client.previewURL)
        .onChange(of: sizeClass) { value in
            if value == .compact { columnVisibility = .doubleColumn }
        }
        .onChange(of: client.selectedTaskID) { id in
            guard sizeClass == .compact, id != nil,
                  shouldResumeLastTask || uiTestOpensTask else { return }
            phonePath = ["conversation"]
            shouldResumeLastTask = false
        }
        .onChange(of: client.completionFeedbackToken) { _ in
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        .onChange(of: client.interruptionFeedbackToken) { _ in
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        .onChange(of: client.approvalFeedbackToken) { _ in
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        .onChange(of: client.errorFeedbackToken) { _ in
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        .onAppear {
            if sizeClass == .compact, client.selectedTaskID != nil,
               shouldResumeLastTask || uiTestOpensTask {
                phonePath = ["conversation"]
                shouldResumeLastTask = false
            }
        }
    }

    @ViewBuilder
    private var workspaceNavigation: some View {
        if sizeClass == .compact {
            NavigationStack(path: $phonePath) {
                TaskSidebar(
                    client: client,
                    search: $search,
                    disconnect: disconnect,
                    openTask: openTaskOnPhone,
                    createTask: createTaskOnPhone
                )
                .navigationDestination(for: String.self) { _ in
                    ConversationView(client: client, showInspector: { inspectorPresented = true })
                }
            }
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                TaskSidebar(
                    client: client,
                    search: $search,
                    disconnect: disconnect,
                    openTask: client.selectTask,
                    createTask: client.createTask
                )
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 350)
            } detail: {
                ConversationView(client: client, showInspector: { inspectorPresented = true })
                    .navigationSplitViewColumnWidth(min: 520, ideal: 780)
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    @ViewBuilder
    private var messageBanner: some View {
        if let message = client.lastMessage {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.amber)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { client.dismissMessage() } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭提示")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider().overlay(Palette.line) }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var inspectorSheet: some View {
        NavigationStack {
            InspectorView(client: client)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { inspectorPresented = false } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("关闭")
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    private func openTaskOnPhone(_ id: String) {
        client.selectTask(id)
        phonePath = ["conversation"]
    }

    private func createTaskOnPhone(cwd: String?, projectId: String?) {
        client.createTask(cwd: cwd, projectId: projectId)
        phonePath = ["creating"]
    }

    private var uiTestOpensTask: Bool {
        ProcessInfo.processInfo.arguments.contains("-CodexRemoteUITestOpenTask")
    }
}

private struct TaskSidebar: View {
    @ObservedObject var client: RemoteClient
    @Binding var search: String
    let disconnect: () -> Void
    let openTask: (String) -> Void
    let createTask: (String?, String?) -> Void
    @State private var renameTarget: RemoteTaskSummary?
    @State private var renameText = ""
    @State private var deleteTarget: RemoteTaskSummary?
    @State private var automationCenterPresented = ProcessInfo.processInfo.arguments.contains("-CodexRemoteUITestOpenAutomations")
    @State private var selectedProjectID: String?
    @State private var collapsedProjectIDs = Set<String>()
    @State private var taskFilter = TaskListFilter.all

    private struct TaskProject: Identifiable {
        let id: String
        let title: String
        let cwd: String?
        let tasks: [RemoteTaskSummary]
        let totalTaskCount: Int
        let isDefault: Bool

        var detail: String? { cwd }
    }

    private var visibleProjects: [TaskProject] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allProjects }
        return allProjects.compactMap { project in
            let projectMatches = project.title.localizedCaseInsensitiveContains(query)
                || (project.cwd?.localizedCaseInsensitiveContains(query) ?? false)
            let matchingTasks = project.tasks.filter { task in
                task.title.localizedCaseInsensitiveContains(query)
                    || task.preview.localizedCaseInsensitiveContains(query)
                    || task.cwd.localizedCaseInsensitiveContains(query)
            }
            guard projectMatches || !matchingTasks.isEmpty else { return nil }
            return TaskProject(
                id: project.id,
                title: project.title,
                cwd: project.cwd,
                tasks: projectMatches ? project.tasks : matchingTasks,
                totalTaskCount: project.totalTaskCount,
                isDefault: project.isDefault
            )
        }
    }

    private var selectedProject: TaskProject? {
        visibleProjects.first(where: { $0.id == selectedProjectID })
            ?? allProjects.first(where: { $0.id == selectedProjectID })
    }

    private var visiblePinnedTasks: [RemoteTaskSummary] {
        let pinned = client.tasks.filter(\.pinned)
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? pinned : pinned.filter { task in
            task.title.localizedCaseInsensitiveContains(query)
                || task.preview.localizedCaseInsensitiveContains(query)
                || task.cwd.localizedCaseInsensitiveContains(query)
        }
        return sortedTasks(filtered)
    }

    private var creationProject: TaskProject? {
        selectedProject
            ?? allProjects.first(where: { $0.isDefault })
            ?? allProjects.first(where: { $0.cwd != nil })
    }

    private var allProjects: [TaskProject] {
        let catalog = client.projects
        let catalogIDs = Set(catalog.map(\.id))
        let filteredTasks = client.tasks.filter(matchesTaskFilter)
        var grouped = Dictionary(grouping: filteredTasks) { task -> String? in
            guard let projectID = task.projectId, catalogIDs.contains(projectID) else { return nil }
            return projectID
        }
        var projects = catalog.map { project in
            let allTasks = grouped.removeValue(forKey: project.id) ?? []
            return TaskProject(
                id: project.id,
                title: project.name,
                cwd: project.path,
                tasks: sortedTasks(allTasks.filter { !$0.pinned }),
                totalTaskCount: allTasks.count,
                isDefault: project.isDefault
            )
        }
        if let allUnassigned = grouped[nil], !allUnassigned.isEmpty {
            projects.append(TaskProject(
                id: "unassigned",
                title: "无项目",
                cwd: nil,
                tasks: sortedTasks(allUnassigned.filter { !$0.pinned }),
                totalTaskCount: allUnassigned.count,
                isDefault: false
            ))
        }
        if client.showingArchived { projects.removeAll { $0.tasks.isEmpty } }
        return projects
    }

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            List {
                if client.isCreatingTask {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.pencil")
                            .foregroundStyle(Palette.accent)
                            .frame(width: 22)
                        Text(client.isSubmittingNewTask ? "正在启动任务" : "新任务")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        if client.isSubmittingNewTask { ProgressView().controlSize(.small) }
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Palette.raised)
                }

                if !visiblePinnedTasks.isEmpty {
                    Section("置顶") {
                        ForEach(visiblePinnedTasks) { task in
                            taskButton(task) { selectProject(for: task) }
                        }
                    }
                }

                if visibleProjects.isEmpty && visiblePinnedTasks.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 20))
                            .foregroundStyle(Palette.textMuted)
                        Text(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? (client.showingArchived ? "没有已归档任务" : "还没有任务")
                             : "没有匹配的项目或任务")
                            .font(.subheadline)
                            .foregroundStyle(Palette.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .listRowBackground(Color.clear)
                } else {
                    Section("项目") {
                        ForEach(visibleProjects) { project in
                            projectHeader(project)
                                .listRowBackground(
                                    project.id == selectedProjectID ? Palette.raised.opacity(0.48) : Color.clear
                                )
                            if !collapsedProjectIDs.contains(project.id) {
                                ForEach(project.tasks) { task in
                                    taskButton(task) { selectProject(project) }
                                        .padding(.leading, 20)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .refreshable { client.refresh() }

            connectionFooter
        }
        .background(Palette.sidebar)
        .searchable(text: $search, prompt: "搜索任务、内容或工作区")
        .onChange(of: client.selectedTaskID) { id in
            guard let id, let task = client.tasks.first(where: { $0.id == id }) else { return }
            selectProject(for: task)
        }
        .onChange(of: client.projects) { _ in synchronizeSelectedProject() }
        .onChange(of: search) { query in
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                collapsedProjectIDs.subtract(visibleProjects.map(\.id))
            }
        }
        .onAppear { synchronizeSelectedProject() }
        .sheet(item: $renameTarget) { task in
            RenameSheet(title: task.title, text: $renameText) {
                client.renameTask(renameText, id: task.id)
                renameTarget = nil
            }
            .presentationDetents([.height(210)])
        }
        .fullScreenCover(isPresented: $automationCenterPresented) {
            NavigationStack {
                AutomationCenterView(client: client) { threadID in
                    automationCenterPresented = false
                    openTask(threadID)
                }
            }
        }
        .alert("删除这个任务？", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        ), presenting: deleteTarget) { task in
            Button("删除", role: .destructive) { client.deleteTask(task.id); deleteTarget = nil }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: { task in
            Text("“\(task.title)”将从 Codex 历史中删除，此操作无法撤销。")
        }
    }

    private func taskButton(_ task: RemoteTaskSummary, beforeOpen: @escaping () -> Void) -> some View {
        Button {
            beforeOpen()
            openTask(task.id)
        } label: {
            TaskRow(task: task, hasDraft: client.hasComposerDraft(taskID: task.id))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(task.id == client.selectedTaskID ? Palette.raised : Color.clear)
        .contextMenu { taskMenu(task) }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                client.setTaskPinned(!task.pinned, id: task.id)
            } label: {
                Label(task.pinned ? "取消置顶" : "置顶", systemImage: task.pinned ? "pin.slash" : "pin")
            }
            .tint(Palette.accent)
        }
    }

    private var sidebarHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: "apple.terminal.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Codex").font(.headline)
                        Text("Mac 工作区").font(.caption2).foregroundStyle(Palette.textMuted)
                    }
                }
                Spacer()
                Menu {
                    Section("筛选") {
                        ForEach(TaskListFilter.allCases) { filter in
                            Button { taskFilter = filter } label: {
                                Label(filter.title, systemImage: taskFilter == filter ? "checkmark" : filter.icon)
                            }
                        }
                    }
                    Section("任务范围") {
                        Button { client.showArchived(false) } label: {
                            Label("进行中的任务", systemImage: client.showingArchived ? "circle" : "checkmark")
                        }
                        Button { client.showArchived(true) } label: {
                            Label("已归档", systemImage: client.showingArchived ? "checkmark" : "archivebox")
                        }
                    }
                    Divider()
                    Button { client.refresh() } label: { Label("刷新并同步", systemImage: "arrow.clockwise") }
                        .keyboardShortcut("r", modifiers: [.command])
                } label: {
                    Image(systemName: taskFilter.icon)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("任务筛选：\(taskFilter.title)")
                Button { createTask(creationProject?.cwd, creationProject?.id) } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Palette.raised, in: Circle())
                }
                .disabled(client.isCreatingTask)
                .accessibilityLabel("新建任务")
            }

            Button { createTask(creationProject?.cwd, creationProject?.id) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.pencil").frame(width: 22)
                    Text("新建任务").font(.subheadline.weight(.medium))
                    Spacer()
                }
                .padding(.horizontal, 11)
                .frame(height: 44)
                .background(Palette.raised, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .disabled(client.isCreatingTask)
            .accessibilityLabel(creationProject == nil ? "新建任务" : "在\(creationProject!.title)中新建任务")

            HStack(spacing: 8) {
                Button { automationCenterPresented = true } label: {
                    Label("自动化", systemImage: "clock.arrow.2.circlepath")
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(Palette.composer, in: RoundedRectangle(cornerRadius: 8))
                }
                Button { client.showArchived(!client.showingArchived) } label: {
                    Label(client.showingArchived ? "当前" : "归档", systemImage: client.showingArchived ? "bubble.left" : "archivebox")
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(Palette.composer, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var emptyTasks: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: client.showingArchived ? "archivebox" : "square.and.pencil")
                .font(.system(size: 26)).foregroundStyle(Palette.textMuted)
            Text(client.showingArchived ? "没有已归档任务" : "还没有任务")
                .font(.subheadline).foregroundStyle(Palette.textMuted)
            if !client.showingArchived {
                Button("新建任务") { createTask(creationProject?.cwd, creationProject?.id) }.buttonStyle(.bordered)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var connectionFooter: some View {
        HStack(spacing: 8) {
            Circle().fill(connectionStatus.color).frame(width: 7, height: 7)
            Text(connectionStatus.text)
                .font(.caption).foregroundStyle(Palette.textMuted).lineLimit(1)
            Spacer()
            if client.pendingCommandCount > 0 {
                Label("\(client.pendingCommandCount) 条待确认", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(Palette.amber)
                    .lineLimit(1)
            }
            if client.state != .connected {
                Button { client.reconnectNow() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).accessibilityLabel("立即重连")
            }
            Menu {
                Text(connectionStatus.text)
                Button { client.refresh() } label: { Label("刷新并同步", systemImage: "arrow.triangle.2.circlepath") }
                Button { client.reconnectNow() } label: { Label("重新连接", systemImage: "arrow.clockwise") }
                Button {
                    UIPasteboard.general.string = client.connectionDiagnostics
                } label: {
                    Label("复制连接诊断", systemImage: "doc.on.doc")
                }
                Button(role: .destructive, action: disconnect) {
                    Label("断开连接", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .overlay(alignment: .top) { Divider().overlay(Palette.line) }
    }

    private var connectionStatus: (text: String, color: Color) {
        switch client.state {
        case .connected:
            guard client.codexReady else { return ("Mac 在线，Codex 启动中", Palette.amber) }
            guard let latency = client.roundTripLatencyMs else { return ("Mac 与 Codex 在线", Palette.accent) }
            let color = latency <= 180 ? Palette.accent : (latency <= 600 ? Palette.amber : Palette.red)
            return ("Mac 与 Codex 在线 · \(latency) ms", color)
        case .connecting:
            return (client.connectionMessage, Palette.amber)
        case .failed:
            return (client.connectionMessage, client.networkAvailable ? Palette.amber : Palette.red)
        case .disconnected:
            return ("已断开", Palette.idle)
        }
    }

    @ViewBuilder private func taskMenu(_ task: RemoteTaskSummary) -> some View {
        Button { client.setTaskPinned(!task.pinned, id: task.id) } label: {
            Label(task.pinned ? "取消置顶" : "置顶", systemImage: task.pinned ? "pin.slash" : "pin")
        }
        Button { renameText = task.title; renameTarget = task } label: { Label("重命名", systemImage: "pencil") }
        if !client.isTransientTask(task.id) {
            if task.archived {
                Button { client.unarchiveTask(task.id) } label: { Label("恢复", systemImage: "arrow.uturn.backward") }
            } else {
                Button { client.archiveTask(task.id) } label: { Label("归档", systemImage: "archivebox") }
            }
            Divider()
            Button(role: .destructive) { deleteTarget = task } label: { Label("删除", systemImage: "trash") }
        }
    }

    private func projectHeader(_ project: TaskProject) -> some View {
        HStack(spacing: 8) {
            Button {
                if collapsedProjectIDs.contains(project.id) {
                    collapsedProjectIDs.remove(project.id)
                } else {
                    collapsedProjectIDs.insert(project.id)
                }
                selectedProjectID = project.id
            } label: {
                Image(systemName: collapsedProjectIDs.contains(project.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textSoft)
                    .frame(width: 18, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsedProjectIDs.contains(project.id) ? "展开项目" : "收起项目")

            Button { selectProject(project) } label: {
                HStack(spacing: 7) {
                    Image(systemName: project.cwd == nil ? "tray" : "folder")
                        .foregroundStyle(projectTint(project.id))
                    Text(project.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text("\(project.totalTaskCount)")
                        .font(.caption2).foregroundStyle(Palette.textMuted)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择项目 \(project.title)")

            Spacer(minLength: 4)

            Button { createTask(project.cwd, project.id == "unassigned" ? nil : project.id) } label: {
                Image(systemName: "square.and.pencil").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(client.isCreatingTask || project.cwd == nil)
            .accessibilityLabel("在 \(project.title) 中新建任务")
        }
        .frame(minHeight: 42)
        .contentShape(Rectangle())
    }

    private func selectProject(_ project: TaskProject) {
        selectedProjectID = project.id
        collapsedProjectIDs.remove(project.id)
    }

    private func selectProject(for task: RemoteTaskSummary) {
        selectedProjectID = task.projectId.flatMap { projectID in
            client.projects.contains(where: { $0.id == projectID }) ? projectID : nil
        } ?? "unassigned"
        collapsedProjectIDs.remove(selectedProjectID!)
    }

    private func synchronizeSelectedProject() {
        if let taskID = client.selectedTaskID,
           let task = client.tasks.first(where: { $0.id == taskID }) {
            selectProject(for: task)
            return
        }
        guard selectedProjectID == nil
                || !client.projects.contains(where: { $0.id == selectedProjectID }) else { return }
        selectedProjectID = client.projects.first(where: { $0.isDefault })?.id
            ?? client.projects.first?.id
    }

    private func projectTint(_ id: String) -> Color {
        let colors = [Palette.accent, Palette.blue, Palette.amber, Palette.red, Palette.teal]
        let value = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 997 }
        return colors[value % colors.count]
    }

    private func sortedTasks(_ tasks: [RemoteTaskSummary]) -> [RemoteTaskSummary] {
        tasks.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            if let lhsOrder = lhs.pinOrder, let rhsOrder = rhs.pinOrder, lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            if let lhsOrder = lhs.projectOrder, let rhsOrder = rhs.projectOrder, lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            if lhs.projectOrder != nil, rhs.projectOrder == nil { return true }
            if lhs.projectOrder == nil, rhs.projectOrder != nil { return false }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private func matchesTaskFilter(_ task: RemoteTaskSummary) -> Bool {
        switch taskFilter {
        case .all:
            return true
        case .active:
            let status = task.status.lowercased()
            return status.contains("active") || status.contains("running") || status.contains("progress")
        case .drafts:
            return client.hasComposerDraft(taskID: task.id)
        }
    }
}

private func automationScheduleLabel(_ rawValue: String) -> String {
    let value = rawValue.hasPrefix("RRULE:") ? String(rawValue.dropFirst(6)) : rawValue
    var fields: [String: String] = [:]
    for component in value.split(separator: ";") {
        let pair = component.split(separator: "=", maxSplits: 1).map(String.init)
        if pair.count == 2 { fields[pair[0]] = pair[1] }
    }
    let hours = (fields["BYHOUR"] ?? "0")
        .split(separator: ",")
        .compactMap { Int($0) }
    let minute = Int(fields["BYMINUTE"] ?? "") ?? 0
    let time = (hours.isEmpty ? [0] : hours)
        .map { String(format: "%02d:%02d", $0, minute) }
        .joined(separator: "、")
    switch fields["FREQ"] {
    case "DAILY":
        return "每天 \(time)"
    case "WEEKLY":
        let days = (fields["BYDAY"] ?? "").split(separator: ",").map(String.init)
        if Set(days) == Set(["MO", "TU", "WE", "TH", "FR", "SA", "SU"]) {
            return "每天 \(time)"
        }
        let labels = [
            "MO": "周一", "TU": "周二", "WE": "周三", "TH": "周四",
            "FR": "周五", "SA": "周六", "SU": "周日"
        ]
        let dayText = days.compactMap { labels[$0] }.joined(separator: "、")
        return dayText.isEmpty ? "每周 \(time)" : "每\(dayText) \(time)"
    case "MONTHLY":
        return "每月 \(fields["BYMONTHDAY"] ?? "1") 日 \(time)"
    default:
        return rawValue.isEmpty ? "未设置计划" : "已设置运行计划"
    }
}

private struct AutomationRow: View {
    let automation: RemoteAutomation

    private var isActive: Bool { automation.status.uppercased() == "ACTIVE" }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: automation.kind == "heartbeat" ? "waveform.path.ecg" : "clock.arrow.2.circlepath")
                .foregroundStyle(isActive ? Palette.accent : Palette.textSoft)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(automation.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("\(isActive ? "运行中" : "已暂停") · \(automationScheduleLabel(automation.schedule))")
                    .font(.caption2)
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
        }
        .padding(.vertical, 5)
    }
}

private struct AutomationCenterView: View {
    @ObservedObject var client: RemoteClient
    let openThread: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editorPresented = false

    private var active: [RemoteAutomation] {
        client.automations.filter { $0.status.uppercased() == "ACTIVE" }
    }

    private var paused: [RemoteAutomation] {
        client.automations.filter { $0.status.uppercased() != "ACTIVE" }
    }

    var body: some View {
        List {
            if client.automations.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.system(size: 28))
                        .foregroundStyle(Palette.textMuted)
                    Text("还没有自动化").font(.headline)
                    Text("创建后可以定时运行，也可以随时立即执行。")
                        .font(.subheadline)
                        .foregroundStyle(Palette.textMuted)
                    Button("创建自动化") { editorPresented = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 42)
                .listRowBackground(Color.clear)
            }
            if !active.isEmpty {
                Section("运行中") {
                    ForEach(active) { automation in automationLink(automation) }
                }
            }
            if !paused.isEmpty {
                Section("已暂停") {
                    ForEach(paused) { automation in automationLink(automation) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.sidebar)
        .listStyle(.plain)
        .navigationTitle("自动化")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("关闭")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { client.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("刷新自动化")
                Button { editorPresented = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("创建自动化")
            }
        }
        .sheet(isPresented: $editorPresented) {
            NavigationStack { AutomationEditorView(client: client, source: nil) }
        }
    }

    private func automationLink(_ automation: RemoteAutomation) -> some View {
        NavigationLink {
            AutomationDetailView(client: client, automationID: automation.id, openThread: openThread)
        } label: {
            AutomationRow(automation: automation)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                client.setAutomationEnabled(automation.status.uppercased() != "ACTIVE", id: automation.id)
            } label: {
                Label(automation.status.uppercased() == "ACTIVE" ? "暂停" : "启用",
                      systemImage: automation.status.uppercased() == "ACTIVE" ? "pause.fill" : "play.fill")
            }
            .tint(automation.status.uppercased() == "ACTIVE" ? Palette.amber : Palette.accent)
        }
    }
}

private struct AutomationDetailView: View {
    @ObservedObject var client: RemoteClient
    let automationID: String
    let openThread: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editorPresented = false
    @State private var deletePresented = false

    private var automation: RemoteAutomation? {
        client.automations.first { $0.id == automationID }
    }

    private var isActive: Bool { automation?.status.uppercased() == "ACTIVE" }

    var body: some View {
        Group {
            if let automation {
                content(automation)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(Palette.amber)
                    Text("自动化不可用").font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.canvas)
        .navigationTitle(automation?.name ?? "自动化")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { editorPresented = true } label: { Label("编辑", systemImage: "pencil") }
                    Button(role: .destructive) { deletePresented = true } label: { Label("删除", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis") }
            }
        }
        .sheet(isPresented: $editorPresented) {
            if let automation {
                NavigationStack { AutomationEditorView(client: client, source: automation) }
            }
        }
        .alert("删除这个自动化？", isPresented: $deletePresented) {
            Button("删除", role: .destructive) {
                if let automation { client.deleteAutomation(automation) }
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("自动化会从 Codex 中移除，并移到 Mac 废纸篓。")
        }
    }

    private func content(_ automation: RemoteAutomation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle().fill(isActive ? Palette.accent : Palette.idle).frame(width: 8, height: 8)
                        Text(isActive ? "运行中" : "已暂停")
                        Text("·").foregroundStyle(Palette.textSoft)
                        Text(automationScheduleLabel(automation.schedule))
                    }
                    .font(.subheadline)
                    .foregroundStyle(Palette.textMuted)

                    HStack(spacing: 14) {
                        Label(automation.kind == "heartbeat" ? "当前任务跟进" : "独立自动化",
                              systemImage: automation.kind == "heartbeat" ? "message.badge.waveform" : "gearshape.2")
                        if let model = automation.model, !model.isEmpty {
                            Label(model, systemImage: "cpu")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Palette.textMuted)
                }

                Divider().overlay(Palette.line)

                HStack(spacing: 10) {
                    Button { client.runAutomation(automation) } label: {
                        Label("立即运行", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)

                    Button { client.setAutomationEnabled(!isActive, id: automation.id) } label: {
                        Image(systemName: isActive ? "pause.fill" : "power")
                            .frame(width: 46, height: 46)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(isActive ? "暂停自动化" : "启用自动化")
                }

                if let runThreadID = client.latestAutomationRunThreadID {
                    Button { openThread(runThreadID) } label: {
                        Label("打开本次运行", systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity, minHeight: 42)
                    }
                    .buttonStyle(.bordered)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("自动化内容").font(.headline)
                    MarkdownMessageView(text: automation.prompt)
                }

                if automation.targetThreadId != nil {
                    Button { openThread(automation.targetThreadId!) } label: {
                        Label("打开绑定任务", systemImage: "arrow.up.right.square")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct AutomationEditorView: View {
    @ObservedObject var client: RemoteClient
    let source: RemoteAutomation?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var prompt: String
    @State private var schedule: String
    @State private var enabled: Bool
    @State private var selectedModel: String?
    @State private var selectedProjectID: String?

    init(client: RemoteClient, source: RemoteAutomation?) {
        self.client = client
        self.source = source
        _name = State(initialValue: source?.name ?? "")
        _prompt = State(initialValue: source?.prompt ?? "")
        _schedule = State(initialValue: source?.schedule ?? "FREQ=DAILY;BYHOUR=9;BYMINUTE=0")
        _enabled = State(initialValue: source?.status.uppercased() == "ACTIVE")
        _selectedModel = State(initialValue: source?.model)
        _selectedProjectID = State(initialValue: source?.projectId)
    }

    var body: some View {
        Form {
            Section("自动化") {
                TextField("名称", text: $name)
                Toggle("启用", isOn: $enabled)
            }

            Section("执行内容") {
                TextEditor(text: $prompt)
                    .frame(minHeight: 220)
            }

            Section("运行计划") {
                TextField("FREQ=DAILY;BYHOUR=9;BYMINUTE=0", text: $schedule)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Menu("使用常用计划") {
                    Button("每天 09:00") { schedule = "FREQ=DAILY;BYHOUR=9;BYMINUTE=0" }
                    Button("工作日 09:00") { schedule = "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9;BYMINUTE=0" }
                    Button("每周一 09:00") { schedule = "FREQ=WEEKLY;BYDAY=MO;BYHOUR=9;BYMINUTE=0" }
                    Button("每月 1 日 09:00") { schedule = "FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=9;BYMINUTE=0" }
                }
            }

            Section("运行位置") {
                Picker("项目", selection: $selectedProjectID) {
                    Text("Mac 默认工作区").tag(String?.none)
                    ForEach(client.projects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                if !client.models.isEmpty {
                    Picker("模型", selection: $selectedModel) {
                        Text("Codex 默认").tag(String?.none)
                        ForEach(client.models) { model in
                            Text(model.displayName).tag(Optional(model.model))
                        }
                    }
                }
            }
        }
        .navigationTitle(source == nil ? "创建自动化" : "编辑自动化")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(!canSave)
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && schedule.uppercased().contains("FREQ=")
    }

    private func save() {
        let project = client.projects.first { $0.id == selectedProjectID }
        let automation = RemoteAutomation(
            id: source?.id ?? "mobile-\(UUID().uuidString.lowercased())",
            kind: source?.kind ?? "cron",
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            status: enabled ? "ACTIVE" : "PAUSED",
            schedule: schedule.trimmingCharacters(in: .whitespacesAndNewlines),
            model: selectedModel,
            reasoningEffort: source?.reasoningEffort,
            targetThreadId: source?.targetThreadId,
            cwd: project?.path ?? source?.cwd,
            projectId: project?.id ?? source?.projectId,
            updatedAt: Date().timeIntervalSince1970 * 1_000
        )
        client.saveAutomation(automation)
        dismiss()
    }
}

private struct TaskRow: View {
    let task: RemoteTaskSummary
    let hasDraft: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: task.pinned ? "pin.fill" : "bubble.left")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(task.pinned ? Palette.accent : Palette.textMuted)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                if hasDraft || isRunning {
                    HStack(spacing: 5) {
                        if hasDraft {
                            Text("草稿").foregroundStyle(Palette.amber)
                        }
                        if hasDraft && isRunning {
                            Text("·").foregroundStyle(Palette.textSoft)
                        }
                        if isRunning {
                            Text("正在运行").foregroundStyle(Palette.accent)
                        }
                    }
                    .font(.caption2)
                }
            }
            Spacer(minLength: 4)
            Text(relativeDate)
                .font(.caption2)
                .foregroundStyle(Palette.textMuted)
                .lineLimit(1)
        }
        .padding(.vertical, 5)
    }

    private var isRunning: Bool {
        let status = task.status.lowercased()
        return status.contains("active") || status.contains("running") || status.contains("progress")
    }

    private var relativeDate: String {
        guard task.updatedAt > 0 else { return "" }
        return Date(timeIntervalSince1970: task.updatedAt).formatted(.relative(presentation: .numeric))
    }
}

private struct ConversationView: View {
    private static let transcriptBottomID = "transcript-bottom"
    private static let transcriptPageSize = 48

    @ObservedObject var client: RemoteClient
    let showInspector: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var renamePresented = false
    @State private var renameText = ""
    @State private var deletePresented = false
    @State private var workspacePresented = false
    @State private var activeDraftContextID = ""
    @State private var composerFocusRequest = 0
    @State private var visibleTranscriptItemLimit = Self.transcriptPageSize

    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()
            if client.selectedTask != nil || client.isCreatingTask {
                VStack(spacing: 0) {
                    header
                    Divider().overlay(Palette.line)
                    transcript
                    ComposerView(
                        client: client,
                        prompt: $prompt,
                        workspacePresented: $workspacePresented,
                        focusRequest: composerFocusRequest
                    )
                }
            } else {
                VStack(spacing: 13) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 28)).foregroundStyle(Palette.textMuted)
                    Text("选择或新建一个任务").font(.headline)
                    Button("新建任务") { client.createTask() }.buttonStyle(.bordered)
                }
            }
        }
        .sheet(isPresented: $renamePresented) {
            RenameSheet(title: client.selectedTask?.title ?? "任务", text: $renameText) {
                client.renameTask(renameText)
                renamePresented = false
            }
            .presentationDetents([.height(210)])
        }
        .sheet(isPresented: $workspacePresented) { WorkspaceSheet(client: client) }
        .alert("删除这个任务？", isPresented: $deletePresented) {
            Button("删除", role: .destructive) { client.deleteTask() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("该任务将从 Codex 历史中删除，此操作无法撤销。")
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { loadDraft(for: client.composerContextID) }
        .onChange(of: client.composerContextID) { contextID in
            if !activeDraftContextID.isEmpty {
                client.saveComposerDraft(prompt, for: activeDraftContextID)
            }
            loadDraft(for: contextID)
        }
        .onChange(of: prompt) { value in
            let contextID = activeDraftContextID.isEmpty ? client.composerContextID : activeDraftContextID
            client.saveComposerDraft(value, for: contextID)
        }
        .onChange(of: client.composerDraftState) { state in
            guard !activeDraftContextID.isEmpty else { return }
            let restored = state.draft(for: activeDraftContextID)
            guard !restored.isEmpty else { return }
            let merged = ComposerDraftState.merged(existing: prompt, recovered: restored)
            guard merged != prompt else { return }
            prompt = merged
            composerFocusRequest &+= 1
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if sizeClass == .compact {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 21, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .background(Palette.raised, in: Circle())
                }
                .accessibilityLabel("返回任务列表")
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(client.isCreatingTask ? "新任务" : (client.selectedTask?.title ?? "新任务"))
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if client.isLoadingTask || client.isSubmittingNewTask {
                        ProgressView().controlSize(.mini).tint(Palette.textMuted)
                    }
                    Text(projectTitle)
                    Text("·")
                    Text("iMac")
                }
                .font(.subheadline)
                .foregroundStyle(Palette.textMuted)
                .lineLimit(1)
            }
            Spacer()

            HStack(spacing: 2) {
                Button(action: createSiblingTask) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 42, height: 42)
                }
                .accessibilityLabel("在当前项目新建任务")

                Menu {
                    Button(action: showInspector) {
                        Label("任务详情", systemImage: "doc.text.magnifyingglass")
                    }
                    if let task = client.selectedTask {
                        Button { client.setTaskPinned(!task.pinned) } label: {
                            Label(task.pinned ? "取消置顶" : "置顶", systemImage: task.pinned ? "pin.slash" : "pin")
                        }
                    }
                    Button { renameText = client.selectedTask?.title ?? ""; renamePresented = true } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    if !client.isSelectedTaskTransient {
                        if client.selectedTask?.archived == true {
                            Button { client.unarchiveTask() } label: { Label("恢复", systemImage: "arrow.uturn.backward") }
                        } else {
                            Button { client.archiveTask() } label: { Label("归档", systemImage: "archivebox") }
                        }
                        Divider()
                        Button(role: .destructive) { deletePresented = true } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    Button { workspacePresented = true } label: { Label("工作区", systemImage: "folder") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 42, height: 42)
                }
                .disabled(client.selectedTask == nil)
                .accessibilityLabel("任务菜单")
            }
            .background(Palette.raised, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, sizeClass == .compact ? 16 : 20)
        .padding(.vertical, 10)
        .frame(minHeight: sizeClass == .compact ? 72 : 62)
        .background(Palette.panel)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if client.items.isEmpty {
                        VStack(spacing: 12) {
                            Spacer(minLength: 150)
                            if client.isLoadingTask {
                                ProgressView().tint(Palette.textMuted)
                                Text("正在同步任务")
                                    .font(.subheadline)
                                    .foregroundStyle(Palette.textMuted)
                            } else {
                                Image(systemName: "terminal")
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundStyle(Palette.textMuted)
                                Text("交给 Codex 一个任务")
                                    .font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    if client.items.count > visibleTranscriptItemLimit {
                        Button {
                            visibleTranscriptItemLimit = min(
                                client.items.count,
                                visibleTranscriptItemLimit + Self.transcriptPageSize
                            )
                        } label: {
                            Label("显示更早内容", systemImage: "arrow.up")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Palette.textMuted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(makeTranscriptBlocks(visibleTranscriptItems)) { block in
                        switch block.content {
                        case .message(let item):
                            MessageRow(client: client, item: item) { text in
                                prompt = ComposerDraftState.merged(existing: prompt, recovered: text)
                                composerFocusRequest &+= 1
                            }
                        case .activity(let items):
                            CodexActivityGroupView(client: client, items: items)
                        }
                    }
                    if client.isBusy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(Palette.accent)
                            Text("Codex 正在处理")
                                .font(.subheadline)
                                .foregroundStyle(Palette.textMuted)
                        }
                        .id("working")
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.transcriptBottomID)
                }
                .frame(maxWidth: 820)
                .padding(.horizontal, sizeClass == .compact ? 18 : 24)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: client.items.count) { _ in scrollToBottom(proxy) }
            .onChange(of: client.items.last?.text) { _ in scrollToBottom(proxy, animated: false) }
            .onChange(of: client.isBusy) { _ in scrollToBottom(proxy) }
            .onChange(of: client.isLoadingTask) { loading in
                if !loading { scrollToBottom(proxy, animated: false) }
            }
            .task(id: client.selectedTaskID) {
                visibleTranscriptItemLimit = Self.transcriptPageSize
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled else { return }
                scrollToBottom(proxy, animated: false)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let action = { proxy.scrollTo(Self.transcriptBottomID, anchor: .bottom) }
        if animated { withAnimation(.easeOut(duration: 0.16), action) }
        else { action() }
    }

    private var visibleTranscriptItems: [RemoteTranscriptItem] {
        Array(client.items.suffix(visibleTranscriptItemLimit))
    }

    private var projectTitle: String {
        if let projectID = client.selectedTask?.projectId,
           let project = client.projects.first(where: { $0.id == projectID }) {
            return project.name
        }
        let path = client.taskSettings?.cwd ?? client.selectedTask?.cwd ?? ""
        return path.isEmpty ? "本地任务" : (path as NSString).lastPathComponent
    }

    private func createSiblingTask() {
        let task = client.selectedTask
        client.createTask(cwd: task?.cwd, projectId: task?.projectId)
    }

    private func loadDraft(for contextID: String) {
        activeDraftContextID = contextID
        prompt = client.composerDraft(for: contextID)
    }
}

private enum TranscriptBlockContent {
    case message(RemoteTranscriptItem)
    case activity([RemoteTranscriptItem])
}

private struct TranscriptBlock: Identifiable {
    let id: String
    let content: TranscriptBlockContent
}

private func makeTranscriptBlocks(_ items: [RemoteTranscriptItem]) -> [TranscriptBlock] {
    var result: [TranscriptBlock] = []
    var activities: [RemoteTranscriptItem] = []

    func flushActivities() {
        guard let first = activities.first, let last = activities.last else { return }
        result.append(TranscriptBlock(id: "activity-\(first.id)-\(last.id)", content: .activity(activities)))
        activities.removeAll(keepingCapacity: true)
    }

    for item in items {
        if item.kind == "user" || item.kind == "assistant" {
            flushActivities()
            result.append(TranscriptBlock(id: item.id, content: .message(item)))
        } else {
            activities.append(item)
        }
    }
    flushActivities()
    return result
}

private struct MessageRow: View {
    @ObservedObject var client: RemoteClient
    let item: RemoteTranscriptItem
    let useAsPrompt: (String) -> Void

    @ViewBuilder
    var body: some View {
        Group {
            switch item.kind {
            case "user":
                HStack {
                    Spacer(minLength: 40)
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(item.text)
                            .textSelection(.enabled)
                            .padding(.horizontal, 15).padding(.vertical, 10)
                            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 18))
                        if item.status == "failed" {
                            Label("发送失败，文字已恢复", systemImage: "exclamationmark.circle")
                                .font(.caption2)
                                .foregroundStyle(Palette.red)
                        }
                        if let resources = item.resources, !resources.isEmpty {
                            RemoteResourceList(client: client, resources: resources)
                                .frame(maxWidth: 430)
                        }
                    }
                }
            case "assistant":
                VStack(alignment: .leading, spacing: 10) {
                    MarkdownMessageView(text: item.text.isEmpty ? " " : item.text)
                    if let resources = item.resources, !resources.isEmpty {
                        RemoteResourceList(client: client, resources: resources)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case "file":
                InlineFileChangesView(item: item)
            default:
                InlineActivityView(client: client, item: item)
            }
        }
        .contextMenu {
            if (item.kind == "user" || item.kind == "assistant") && !item.text.isEmpty {
                Button {
                    UIPasteboard.general.string = item.text
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                Button {
                    useAsPrompt(item.text)
                } label: {
                    Label("放入输入框", systemImage: "arrow.down.to.line")
                }
            }
        }
    }
}

private enum MessageMarkdownBlock {
    case paragraph(String)
    case heading(Int, String)
    case unordered([String])
    case ordered([String])
    case quote(String)
    case code(String, String?)
    case divider
}

private func parseMessageMarkdown(_ source: String) -> [MessageMarkdownBlock] {
    let lines = source.components(separatedBy: .newlines)
    var blocks: [MessageMarkdownBlock] = []
    var paragraph: [String] = []
    var unordered: [String] = []
    var ordered: [String] = []
    var code: [String] = []
    var codeLanguage: String?

    func flushParagraph() {
        guard !paragraph.isEmpty else { return }
        blocks.append(.paragraph(paragraph.joined(separator: " ")))
        paragraph.removeAll()
    }
    func flushLists() {
        if !unordered.isEmpty {
            blocks.append(.unordered(unordered))
            unordered.removeAll()
        }
        if !ordered.isEmpty {
            blocks.append(.ordered(ordered))
            ordered.removeAll()
        }
    }
    func orderedContent(_ value: String) -> String? {
        guard let dot = value.firstIndex(of: "."), dot != value.startIndex else { return nil }
        let number = value[..<dot]
        let after = value.index(after: dot)
        guard number.allSatisfy(\.isNumber), after < value.endIndex, value[after].isWhitespace else { return nil }
        return String(value[value.index(after: after)...])
    }

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if codeLanguage != nil {
            if trimmed.hasPrefix("```") {
                blocks.append(.code(code.joined(separator: "\n"), codeLanguage == "" ? nil : codeLanguage))
                code.removeAll()
                codeLanguage = nil
            } else {
                code.append(line)
            }
            continue
        }
        if trimmed.hasPrefix("```") {
            flushParagraph()
            flushLists()
            codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            continue
        }
        if trimmed.isEmpty {
            flushParagraph()
            flushLists()
            continue
        }

        let headingMarks = trimmed.prefix { $0 == "#" }.count
        if (1...4).contains(headingMarks), trimmed.dropFirst(headingMarks).hasPrefix(" ") {
            flushParagraph()
            flushLists()
            blocks.append(.heading(headingMarks, String(trimmed.dropFirst(headingMarks + 1))))
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            flushParagraph()
            if !ordered.isEmpty { flushLists() }
            unordered.append(String(trimmed.dropFirst(2)))
        } else if let content = orderedContent(trimmed) {
            flushParagraph()
            if !unordered.isEmpty { flushLists() }
            ordered.append(content)
        } else if trimmed.hasPrefix("> ") {
            flushParagraph()
            flushLists()
            blocks.append(.quote(String(trimmed.dropFirst(2))))
        } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            flushParagraph()
            flushLists()
            blocks.append(.divider)
        } else {
            flushLists()
            paragraph.append(trimmed)
        }
    }
    if codeLanguage != nil { blocks.append(.code(code.joined(separator: "\n"), codeLanguage)) }
    flushParagraph()
    flushLists()
    return blocks
}

private func inlineMarkdown(_ source: String) -> Text {
    let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
    )
    if let value = try? AttributedString(markdown: source, options: options) {
        return Text(value)
    }
    return Text(source)
}

private struct MarkdownMessageView: View {
    let text: String

    private var blocks: [MessageMarkdownBlock] { parseMessageMarkdown(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MessageMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let value):
            inlineMarkdown(value)
                .font(.body)
                .lineSpacing(3)
        case .heading(let level, let value):
            inlineMarkdown(value)
                .font(level == 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, level == 1 ? 4 : 1)
        case .unordered(let values):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("•").foregroundStyle(Palette.textMuted)
                        inlineMarkdown(value).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .ordered(let values):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("\(index + 1).")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(Palette.textMuted)
                        inlineMarkdown(value).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .quote(let value):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(Palette.line).frame(width: 3)
                inlineMarkdown(value).foregroundStyle(Palette.textMuted)
            }
        case .code(let value, let language):
            VStack(alignment: .leading, spacing: 0) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Palette.textMuted)
                        .padding(.horizontal, 12).padding(.top, 9)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(value.isEmpty ? " " : value)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Palette.codeText)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(12)
                }
            }
            .background(Palette.composer, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).stroke(Palette.line) }
        case .divider:
            Divider().overlay(Palette.line)
        }
    }
}

private struct InlineFileChangesView: View {
    let item: RemoteTranscriptItem
    @State private var expanded = false

    private var files: [RemoteFileChange] { item.files ?? [] }
    private var counts: DiffCounts { countDiffLines(files.map(\.diff).joined(separator: "\n")) }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(spacing: 0) {
                ForEach(files) { change in
                    FileChangeRow(change: change)
                    if change.id != files.last?.id { Divider().overlay(Palette.line) }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "doc.badge.gearshape.fill")
                    .foregroundStyle(Palette.blue)
                    .frame(width: 22)
                Text(files.isEmpty ? "文件变更" : "已编辑 \(files.count) 个文件")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if counts.additions > 0 {
                    Text("+\(counts.additions)").foregroundStyle(Palette.accent)
                }
                if counts.deletions > 0 {
                    Text("-\(counts.deletions)").foregroundStyle(Palette.red)
                }
            }
            .font(.caption.monospacedDigit())
        }
        .tint(Palette.blue)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Palette.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(Palette.blue.opacity(0.16)) }
    }
}

private struct CodexActivityGroupView: View {
    @ObservedObject var client: RemoteClient
    let items: [RemoteTranscriptItem]

    private var fileItems: [RemoteTranscriptItem] { items.filter { $0.kind == "file" } }
    private var approvalItems: [RemoteTranscriptItem] { items.filter { $0.kind == "approval" } }
    private var reasoningItems: [RemoteTranscriptItem] {
        items.filter { $0.kind == "reasoning" || $0.kind == "plan" }
    }
    private var toolItems: [RemoteTranscriptItem] { items.filter { $0.kind == "tool" } }
    private var inspectionItems: [RemoteTranscriptItem] { toolItems.filter(isInspection) }
    private var commandItems: [RemoteTranscriptItem] { toolItems.filter { !isInspection($0) } }
    private var otherItems: [RemoteTranscriptItem] {
        items.filter { !["file", "approval", "reasoning", "plan", "tool"].contains($0.kind) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !inspectionItems.isEmpty {
                CodexActivityDisclosureRow(
                    client: client,
                    items: inspectionItems,
                    icon: "magnifyingglass",
                    title: inspectionTitle,
                    tint: Palette.textMuted
                )
            }
            if !fileItems.isEmpty {
                CodexFileActivityRow(items: fileItems)
            }
            if !commandItems.isEmpty {
                CodexActivityDisclosureRow(
                    client: client,
                    items: commandItems,
                    icon: "terminal",
                    title: commandTitle,
                    tint: Palette.textMuted
                )
            }
            if !approvalItems.isEmpty {
                CodexActivityDisclosureRow(
                    client: client,
                    items: approvalItems,
                    icon: "checkmark.shield",
                    title: approvalTitle,
                    tint: Palette.textMuted
                )
            }
            if !reasoningItems.isEmpty {
                CodexActivityDisclosureRow(
                    client: client,
                    items: reasoningItems,
                    icon: reasoningItems.contains(where: { $0.kind == "plan" }) ? "list.bullet.clipboard" : "brain",
                    title: reasoningItems.contains(where: { $0.kind == "plan" }) ? "方案与分析" : "已完成分析",
                    tint: Palette.textMuted
                )
            }
            if !otherItems.isEmpty {
                CodexActivityDisclosureRow(
                    client: client,
                    items: otherItems,
                    icon: "info.circle",
                    title: otherItems.count == 1 ? "系统消息" : "\(otherItems.count) 条系统消息",
                    tint: Palette.textMuted
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inspectionTitle: String {
        let reads = inspectionItems.filter { activityKind($0) == .read }.count
        let searches = inspectionItems.filter { activityKind($0) == .search }.count
        let lists = inspectionItems.filter { activityKind($0) == .list }.count
        var parts: [String] = []
        if reads > 0 { parts.append("已浏览 \(reads) 个文件") }
        if searches > 0 { parts.append("执行了 \(searches) 次搜索") }
        if lists > 0 { parts.append("\(lists) 次列表") }
        return parts.isEmpty ? "已完成 \(inspectionItems.count) 项检查" : parts.joined(separator: "，")
    }

    private var commandTitle: String {
        if let running = commandItems.first(where: isRunning),
           let command = running.command?.split(whereSeparator: \.isNewline).first {
            return "正在运行 \(command)"
        }
        return commandItems.count == 1 ? "已运行 1 条命令" : "已运行 \(commandItems.count) 条命令"
    }

    private var approvalTitle: String {
        let approved = approvalItems.filter { ($0.status ?? "").lowercased() == "approved" }.count
        let pending = approvalItems.filter { ($0.status ?? "").lowercased() == "pending" }.count
        if pending > 0 { return "等待批准 \(pending) 个请求" }
        return "已批准 \(max(approved, approvalItems.count)) 个请求"
    }

    private enum InspectionKind { case read, search, list, other }

    private func isInspection(_ item: RemoteTranscriptItem) -> Bool { activityKind(item) != .other }

    private func activityKind(_ item: RemoteTranscriptItem) -> InspectionKind {
        let value = "\(item.toolName ?? "") \(item.command ?? "")".lowercased()
        if value.contains("rg --files") || value.contains(" ls ") || value.hasPrefix("ls ")
            || value.contains("list") || value.contains("glob") {
            return .list
        }
        if value.contains("rg ") || value.contains("grep") || value.contains("search")
            || value.contains("find ") {
            return .search
        }
        if value.contains("sed ") || value.contains("cat ") || value.contains("head ")
            || value.contains("tail ") || value.contains("read") || value.contains("view") {
            return .read
        }
        return .other
    }

    private func isRunning(_ item: RemoteTranscriptItem) -> Bool {
        let status = (item.status ?? "").lowercased()
        return status == "running" || status == "inprogress" || status == "in_progress"
    }
}

private struct CodexActivityDisclosureRow: View {
    @ObservedObject var client: RemoteClient
    let items: [RemoteTranscriptItem]
    let icon: String
    let title: String
    let tint: Color
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(activityName(item))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Palette.textMuted)
                        let detail = activityDetail(item)
                        if !detail.isEmpty {
                            Text(detail)
                                .font(item.command == nil ? .caption : .system(size: 11, design: .monospaced))
                                .foregroundStyle(Palette.codeText.opacity(0.78))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let resources = item.resources, !resources.isEmpty {
                            RemoteResourceList(client: client, resources: resources)
                        }
                    }
                    if item.id != items.last?.id { Divider().overlay(Palette.line) }
                }
            }
            .padding(.top, 9)
            .padding(.leading, 34)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(2)
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
        }
        .tint(Palette.textMuted)
    }

    private func activityName(_ item: RemoteTranscriptItem) -> String {
        if let toolName = item.toolName, !toolName.isEmpty { return toolName }
        if let command = item.command, !command.isEmpty {
            return command.split(whereSeparator: \.isNewline).first.map(String.init) ?? "命令"
        }
        if item.kind == "approval" { return "权限请求" }
        if item.kind == "reasoning" { return "分析" }
        if item.kind == "plan" { return "方案" }
        return "Codex"
    }

    private func activityDetail(_ item: RemoteTranscriptItem) -> String {
        if let output = item.output, !output.isEmpty { return output }
        return item.text
    }
}

private struct CodexFileActivityRow: View {
    let items: [RemoteTranscriptItem]
    @State private var expanded = false

    private var files: [RemoteFileChange] {
        var order: [String] = []
        var values: [String: RemoteFileChange] = [:]
        for file in items.flatMap({ $0.files ?? [] }) {
            if values[file.path] == nil { order.append(file.path) }
            values[file.path] = file
        }
        return order.compactMap { values[$0] }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(spacing: 0) {
                ForEach(files) { change in
                    FileChangeRow(change: change)
                    if change.id != files.last?.id { Divider().overlay(Palette.line) }
                }
            }
            .padding(.top, 8)
            .padding(.leading, 24)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.badge.gearshape")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
                    .frame(width: 22)
                Text(files.isEmpty ? "文件变更" : "已编辑 \(files.count) 个文件")
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.textMuted)
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
        }
        .tint(Palette.textMuted)
    }
}

private struct InlineActivityView: View {
    @ObservedObject var client: RemoteClient
    let item: RemoteTranscriptItem
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $expanded) {
                Text(detail)
                    .font(item.kind == "tool" ? .system(size: 11, design: .monospaced) : .caption)
                    .foregroundStyle(Palette.codeText.opacity(0.82))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8).padding(.leading, 30)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: icon).foregroundStyle(tint).frame(width: 22)
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    if let status = item.status, !status.isEmpty {
                        Text(activityStatusLabel(status))
                            .font(.caption2)
                            .foregroundStyle(status.lowercased().contains("fail") ? Palette.red : Palette.textMuted)
                    }
                }
            }
            .tint(tint)
            if let resources = item.resources, !resources.isEmpty {
                RemoteResourceList(client: client, resources: resources)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Palette.raised.opacity(0.62), in: RoundedRectangle(cornerRadius: 7))
    }

    private var detail: String {
        let value = item.output?.isEmpty == false ? item.output! : item.text
        return value.isEmpty ? "无输出" : value
    }
    private var icon: String {
        switch item.kind {
        case "reasoning": return "brain"
        case "plan": return "checklist"
        case "tool": return item.command == nil ? "wrench.and.screwdriver" : "terminal"
        default: return "info.circle"
        }
    }
    private var tint: Color {
        switch item.kind {
        case "reasoning", "plan": return Palette.amber
        case "tool": return Palette.accent
        default: return Palette.textMuted
        }
    }
    private var title: String {
        if let command = item.command, !command.isEmpty {
            return command.split(whereSeparator: \.isNewline).first.map(String.init) ?? "终端命令"
        }
        if let toolName = item.toolName, !toolName.isEmpty { return toolName }
        return item.kind == "reasoning" ? "思考" : item.kind == "plan" ? "计划" : "工具"
    }
}

private func activityStatusLabel(_ value: String) -> String {
    switch value.lowercased() {
    case "inprogress", "running": return "运行中"
    case "completed": return "已完成"
    case "failed": return "失败"
    case "declined": return "已拒绝"
    default: return value
    }
}

private struct RemoteResourceList: View {
    @ObservedObject var client: RemoteClient
    let resources: [RemoteResource]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(resources) { resource in
                Button { client.openResource(resource) } label: {
                    HStack(spacing: 11) {
                        Image(systemName: resource.kind == "image" ? "photo.fill" : fileIcon(resource.name))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Palette.blue)
                            .frame(width: 34, height: 34)
                            .background(Palette.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(resource.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(resource.sizeBytes), countStyle: .file))
                                .font(.caption2)
                                .foregroundStyle(Palette.textMuted)
                        }
                        Spacer(minLength: 8)
                        if client.loadingResourcePaths.contains(resource.path) {
                            ProgressView().controlSize(.small).tint(Palette.blue)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Palette.blue)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).stroke(Palette.blue.opacity(0.20)) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开 \(resource.name)")
            }
        }
    }

    private func fileIcon(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["zip", "ipa", "dmg", "pkg"].contains(ext) { return "shippingbox.fill" }
        if ext == "pdf" { return "doc.richtext.fill" }
        return "doc.fill"
    }
}

@MainActor
private final class SpeechInputController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var errorMessage: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var update: ((String) -> Void)?
    private var prefix = ""
    private var tapInstalled = false
    private var sessionGate = SpeechInputSessionGate()

    func start(prefix: String, update: @escaping (String) -> Void) {
        guard !isRecording else { return }
        let session = sessionGate.begin()
        isRecording = true
        errorMessage = nil
        self.prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        self.update = update
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self, self.sessionGate.accepts(session) else { return }
                guard status == .authorized else {
                    self.failSession("请在系统设置中允许语音识别", session: session)
                    return
                }
                self.requestMicrophoneAccess(session: session)
            }
        }
    }

    func stop() {
        sessionGate.invalidate()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.reset()
        let request = recognitionRequest
        let task = recognitionTask
        recognitionRequest = nil
        recognitionTask = nil
        update = nil
        isRecording = false
        request?.endAudio()
        task?.cancel()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func stop(session: UInt64) {
        guard sessionGate.accepts(session) else { return }
        stop()
    }

    private func failSession(_ message: String, session: UInt64) {
        guard sessionGate.accepts(session) else { return }
        stop()
        errorMessage = message
    }

    private func requestMicrophoneAccess(session sessionID: UInt64) {
        guard sessionGate.accepts(sessionID) else { return }
        let audioSession = AVAudioSession.sharedInstance()
        switch audioSession.recordPermission {
        case .granted:
            beginRecording(session: sessionID)
        case .undetermined:
            audioSession.requestRecordPermission { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self, self.sessionGate.accepts(sessionID) else { return }
                    if allowed { self.beginRecording(session: sessionID) }
                    else { self.failSession("请在系统设置中允许麦克风访问", session: sessionID) }
                }
            }
        case .denied:
            failSession("请在系统设置中允许麦克风访问", session: sessionID)
        @unknown default:
            failSession("当前无法使用麦克风", session: sessionID)
        }
    }

    private func beginRecording(session: UInt64) {
        guard sessionGate.accepts(session) else { return }
        guard let recognizer, recognizer.isAvailable else {
            failSession("语音识别暂时不可用", session: session)
            return
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            recognitionRequest = request
            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw CocoaError(.featureUnsupported) }
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            tapInstalled = true

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self, self.sessionGate.accepts(session) else { return }
                    if let result {
                        let spoken = result.bestTranscription.formattedString
                        let separator = self.prefix.isEmpty || spoken.isEmpty ? "" : " "
                        self.update?(self.prefix + separator + spoken)
                        if result.isFinal { self.stop(session: session) }
                    } else if error != nil {
                        self.stop(session: session)
                    }
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            failSession("无法开始语音输入：\(error.localizedDescription)", session: session)
        }
    }
}

private struct CameraCaptureView: UIViewControllerRepresentable {
    let completion: (UIImage) -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCaptureView

        init(parent: CameraCaptureView) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage { parent.completion(image) }
            else { parent.cancel() }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.cancel() }
    }
}

private struct ComposerView: View {
    private struct PendingAttachment: Identifiable, Hashable {
        let id: UUID
        let name: String
        let kind: String
        let mimeType: String
        let data: Data

        init(id: UUID, name: String, kind: String, mimeType: String, data: Data) {
            self.id = id
            self.name = name
            self.kind = kind
            self.mimeType = mimeType
            self.data = data
        }

        init?(remoteValue: RemoteAttachment) {
            guard let id = UUID(uuidString: remoteValue.id),
                  let data = Data(base64Encoded: remoteValue.dataBase64),
                  data.count == remoteValue.sizeBytes else { return nil }
            self.init(
                id: id,
                name: remoteValue.name,
                kind: remoteValue.kind,
                mimeType: remoteValue.mimeType,
                data: data
            )
        }

        var remoteValue: RemoteAttachment {
            RemoteAttachment(
                id: id.uuidString,
                name: name,
                kind: kind,
                mimeType: mimeType,
                dataBase64: data.base64EncodedString(),
                sizeBytes: data.count
            )
        }
    }

    @ObservedObject var client: RemoteClient
    @Binding var prompt: String
    @Binding var workspacePresented: Bool
    let focusRequest: Int
    @StateObject private var speech = SpeechInputController()
    @FocusState private var focused: Bool
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var attachments: [PendingAttachment] = []
    @State private var selectedSkills: [RemoteSkill] = []
    @State private var fileImporterPresented = false
    @State private var cameraPresented = false
    @State private var attachmentPickerPresented = ProcessInfo.processInfo.arguments.contains("-CodexRemoteUITestAttachmentMenu")
    @State private var permissionPickerPresented = ProcessInfo.processInfo.arguments.contains("-CodexRemoteUITestPermissionMenu")
    @State private var isImporting = false
    @State private var attachmentError: String?

    private var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool {
        !trimmedPrompt.isEmpty || !attachments.isEmpty || !selectedSkills.isEmpty
    }
    private var currentModel: RemoteModel? {
        let selected = client.selectedModel
        return client.models.first { $0.model == selected || $0.id == selected }
            ?? client.models.first(where: \.isDefault)
            ?? client.models.first
    }
    private var availableEfforts: [RemoteReasoningEffort] { currentModel?.efforts ?? [] }
    private let maximumAttachmentCount = 6
    private let maximumAttachmentBytes = 16 * 1024 * 1024
    private let maximumTotalBytes = 28 * 1024 * 1024

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                if !attachments.isEmpty || !selectedSkills.isEmpty || client.planMode {
                    selectionStrip
                }

                TextField(client.items.isEmpty ? "描述任务" : "跟进", text: $prompt, axis: .vertical)
                    .lineLimit(1...7)
                    .focused($focused)
                    .textInputAutocapitalization(.sentences)
                    .padding(.horizontal, 14)
                    .padding(.top, 13)
                    .padding(.bottom, 7)

                HStack(spacing: 14) {
                    attachmentMenu
                    permissionMenu

                    Spacer(minLength: 8)

                    modelAndEffortMenu

                    Button(action: toggleSpeech) {
                        Image(systemName: speech.isRecording ? "waveform" : "mic")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(speech.isRecording ? Palette.red : Color.white)
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel(speech.isRecording ? "停止语音输入" : "语音输入")

                    primaryAction
                }
                .foregroundStyle(Palette.textMuted)
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.bottom, 11)
            }
            .frame(maxWidth: 820)
            .background(Palette.composer, in: RoundedRectangle(cornerRadius: 26))
            .overlay { RoundedRectangle(cornerRadius: 26).stroke(Palette.line) }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .background(Palette.panel)
        .onAppear {
            focusForNewTask()
            restoreFailedDeliveryIfNeeded()
            if ProcessInfo.processInfo.arguments.contains("-CodexRemoteUITestFocusComposer") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { focused = true }
            }
        }
        .onChange(of: client.isCreatingTask) { creating in
            if creating {
                focusForNewTask()
                restoreFailedDeliveryIfNeeded()
            }
        }
        .onChange(of: focusRequest) { _ in focused = true }
        .onChange(of: photoSelection) { selection in
            guard !selection.isEmpty else { return }
            importPhotos(selection)
        }
        .onChange(of: client.selectedTaskID) { _ in
            clearSelections()
            restoreFailedDeliveryIfNeeded()
        }
        .onChange(of: client.failedDeliveries) { _ in restoreFailedDeliveryIfNeeded() }
        .onChange(of: speech.errorMessage) { message in
            if let message { attachmentError = message }
        }
        .onChange(of: client.plugins) { plugins in
            let availablePaths = Set(plugins.flatMap(\.skills).map(\.path))
            selectedSkills.removeAll { !availablePaths.contains($0.path) }
        }
        .fileImporter(
            isPresented: $fileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let error): attachmentError = error.localizedDescription
            }
        }
        .fullScreenCover(isPresented: $cameraPresented) {
            CameraCaptureView { image in
                cameraPresented = false
                importCameraImage(image)
            } cancel: {
                cameraPresented = false
            }
            .ignoresSafeArea()
        }
        .onDisappear { speech.stop() }
        .alert("无法添加附件", isPresented: Binding(
            get: { attachmentError != nil },
            set: { if !$0 { attachmentError = nil } }
        )) {
            Button("好") { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "")
        }
    }

    private var selectionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    attachmentChip(attachment)
                }
                ForEach(selectedSkills) { skill in
                    skillChip(skill)
                }
                if client.planMode {
                    HStack(spacing: 7) {
                        Image(systemName: "list.bullet.clipboard").foregroundStyle(Palette.blue)
                        Text("方案模式").font(.caption)
                        Button { client.setPlanMode(false) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.textSoft)
                        }
                        .accessibilityLabel("关闭方案模式")
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 40)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
        }
        .frame(height: 54)
    }

    private func attachmentChip(_ attachment: PendingAttachment) -> some View {
        HStack(spacing: 8) {
            Group {
                if attachment.kind == "image", let image = UIImage(data: attachment.data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "doc.fill").foregroundStyle(Palette.blue)
                }
            }
            .frame(width: 30, height: 30)
            .background(Palette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(attachment.name)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 150)
            Button { attachments.removeAll { $0.id == attachment.id } } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Palette.textSoft)
            }
            .accessibilityLabel("移除 \(attachment.name)")
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: 40)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 8))
    }

    private func skillChip(_ skill: RemoteSkill) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(Palette.accent)
            Text(skill.pluginName).font(.caption).lineLimit(1)
            Button { selectedSkills.removeAll { $0.path == skill.path } } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.textSoft)
            }
            .accessibilityLabel("移除插件 \(skill.pluginName)")
        }
        .padding(.horizontal, 9)
        .frame(height: 40)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 8))
    }

    private var attachmentMenu: some View {
        Button { attachmentPickerPresented.toggle() } label: {
            Group {
                if isImporting { ProgressView().controlSize(.small) }
                else { Image(systemName: "plus") }
            }
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(Color.white)
            .frame(width: 32, height: 32)
        }
        .disabled(isImporting || attachments.count >= maximumAttachmentCount)
        .accessibilityLabel("添加内容")
        .popover(isPresented: $attachmentPickerPresented, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Button { client.setPlanMode(!client.planMode) } label: {
                        popoverRowLabel(
                            title: "方案模式",
                            icon: "list.bullet.clipboard",
                            selected: client.planMode,
                            enabled: !client.isBusy
                        )
                    }
                    .disabled(client.isBusy)
                    Divider().overlay(Palette.line)
                    Button {
                        attachmentPickerPresented = false
                        fileImporterPresented = true
                    } label: {
                        popoverRowLabel(title: "文件", icon: "paperclip")
                    }
                    Button {
                        attachmentPickerPresented = false
                        openCamera()
                    } label: {
                        popoverRowLabel(title: "相机", icon: "camera")
                    }
                    PhotosPicker(
                        selection: $photoSelection,
                        maxSelectionCount: maximumAttachmentCount,
                        matching: .images
                    ) {
                        popoverRowLabel(title: "照片", icon: "photo.on.rectangle")
                    }
                    Divider().overlay(Palette.line)
                    Text("插件")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.textMuted)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 5)
                    if client.plugins.isEmpty {
                        Button { client.requestPlugins(cwd: client.taskSettings?.cwd ?? client.selectedTask?.cwd) } label: {
                            popoverRowLabel(title: "载入插件", icon: "puzzlepiece.extension")
                        }
                    } else {
                        ForEach(client.plugins) { plugin in
                            pluginEntry(plugin)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 46)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .frame(width: 330)
            .frame(maxHeight: 520)
            .background(Palette.raised)
            .codexPopoverPresentation()
        }
    }

    private var permissionMenu: some View {
        Button { permissionPickerPresented.toggle() } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Color.white)
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel("权限模式：\(permissionModeTitle)")
        .popover(isPresented: $permissionPickerPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Text("应如何批准 Codex 操作？")
                    .font(.subheadline)
                    .foregroundStyle(Palette.textMuted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                permissionButton(
                    .ask,
                    title: "请求批准",
                    detail: "编辑外部文件和使用互联网前始终先询问",
                    icon: "hand.raised"
                )
                permissionButton(
                    .auto,
                    title: "替我批准",
                    detail: "仅在检测到可能不安全的操作时询问",
                    icon: "terminal"
                )
                permissionButton(
                    .full,
                    title: "完全访问",
                    detail: "完全访问计算机（风险较高）",
                    icon: "exclamationmark.shield"
                )
                permissionButton(
                    .custom,
                    title: "自定义 (config.toml)",
                    detail: "使用 config.toml 中定义的权限",
                    icon: "gearshape"
                )
            }
            .buttonStyle(.plain)
            .frame(width: 350)
            .padding(.vertical, 4)
            .background(Palette.raised)
            .codexPopoverPresentation()
        }
    }

    @ViewBuilder
    private func permissionButton(
        _ mode: RemotePermissionMode,
        title: String,
        detail: String,
        icon: String
    ) -> some View {
        Button {
            client.setPermissionMode(mode)
            permissionPickerPresented = false
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.white)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).foregroundStyle(Color.white)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Palette.textMuted)
                }
                Spacer(minLength: 8)
                if client.permissionMode == mode.rawValue {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
    }

    private func popoverRowLabel(
        title: String,
        icon: String,
        selected: Bool = false,
        enabled: Bool = true
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 28)
            Text(title).font(.body)
            Spacer()
            if selected { Image(systemName: "checkmark") }
        }
        .foregroundStyle(enabled ? Color.white : Palette.textMuted)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func pluginEntry(_ plugin: RemotePlugin) -> some View {
        if plugin.skills.count == 1, let skill = plugin.skills.first {
            Button { toggleSkill(skill) } label: {
                pluginLabel(plugin, selected: isSelected(skill), showsDisclosure: false)
            }
        } else if plugin.skills.isEmpty {
            pluginLabel(plugin, selected: false, showsDisclosure: false)
                .foregroundStyle(Palette.textMuted)
        } else {
            Menu {
                ForEach(plugin.skills) { skill in
                    skillButton(skill, title: skill.name)
                }
            } label: {
                pluginLabel(
                    plugin,
                    selected: plugin.skills.contains(where: isSelected),
                    showsDisclosure: true
                )
            }
        }
    }

    private func pluginLabel(
        _ plugin: RemotePlugin,
        selected: Bool,
        showsDisclosure: Bool
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: pluginIcon(plugin))
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(pluginTint(plugin))
                .frame(width: 28)
            Text(plugin.displayName)
                .font(.body)
                .foregroundStyle(Color.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.white)
            } else if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .contentShape(Rectangle())
    }

    private func isSelected(_ skill: RemoteSkill) -> Bool {
        selectedSkills.contains { $0.path == skill.path }
    }

    private func pluginIcon(_ plugin: RemotePlugin) -> String {
        let name = "\(plugin.name) \(plugin.displayName)".lowercased()
        if name.contains("browser") || name.contains("chrome") { return "globe" }
        if name.contains("computer") { return "desktopcomputer" }
        if name.contains("document") { return "doc.text.fill" }
        if name.contains("pdf") { return "doc.richtext.fill" }
        return "puzzlepiece.extension.fill"
    }

    private func pluginTint(_ plugin: RemotePlugin) -> Color {
        let name = "\(plugin.name) \(plugin.displayName)".lowercased()
        if name.contains("browser") || name.contains("chrome") { return Palette.blue }
        if name.contains("computer") { return Palette.amber }
        if name.contains("document") { return Palette.teal }
        if name.contains("pdf") { return Palette.red }
        return Palette.accent
    }

    private func skillButton(_ skill: RemoteSkill, title: String) -> some View {
        Button { toggleSkill(skill) } label: {
            if selectedSkills.contains(where: { $0.path == skill.path }) {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var modelAndEffortMenu: some View {
        Menu {
            Section("模型") {
                ForEach(client.models) { model in
                    Button { client.updateSettings(model: model.model, effort: model.defaultEffort) } label: {
                        if model.model == client.selectedModel || model.id == client.selectedModel {
                            Label(model.displayName, systemImage: "checkmark")
                        } else {
                            Text(model.displayName)
                        }
                    }
                }
            }
            if !availableEfforts.isEmpty {
                Section("推理强度") {
                    ForEach(availableEfforts) { effort in
                        Button { client.updateSettings(effort: effort.value) } label: {
                            if effort.value == client.selectedEffort {
                                Label(effortDisplayName(effort.value), systemImage: "checkmark")
                            } else {
                                Text(effortDisplayName(effort.value))
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(shortModelName).foregroundStyle(Color.white)
                Text(effortDisplayName(client.selectedEffort))
                    .foregroundStyle(Palette.textMuted)
            }
            .font(.system(size: 15, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .disabled(client.models.isEmpty)
        .accessibilityLabel("模型与推理强度")
    }

    @ViewBuilder
    private var primaryAction: some View {
        if client.isBusy && !canSubmit {
            Button { client.interrupt() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.black)
                    .frame(width: 40, height: 40)
                    .background(Color.white, in: Circle())
            }
            .disabled(client.isInterrupting)
            .opacity(client.isInterrupting ? 0.45 : 1)
            .accessibilityLabel("停止")
        } else {
            Button(action: submit) {
                Image(systemName: client.isBusy ? "arrow.turn.up.right" : "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.black)
                    .frame(width: 40, height: 40)
                    .background(Color.white, in: Circle())
            }
            .disabled(!canSubmit || client.isSubmittingNewTask || isImporting)
            .opacity(!canSubmit || client.isSubmittingNewTask || isImporting ? 0.30 : 1)
            .accessibilityLabel(client.isBusy ? "追加指令" : "发送")
        }
    }

    private var shortModelName: String {
        let value = currentModel?.displayName ?? (client.selectedModel.isEmpty ? "模型" : client.selectedModel)
        return value
            .replacingOccurrences(of: "GPT-", with: "")
            .replacingOccurrences(of: "gpt-", with: "")
    }

    private var permissionModeTitle: String {
        switch RemotePermissionMode(rawValue: client.permissionMode) {
        case .ask: return "请求批准"
        case .auto: return "替我批准"
        case .full: return "完全访问"
        case .custom, .none: return "自定义"
        }
    }

    private func effortDisplayName(_ value: String) -> String {
        switch value.lowercased() {
        case "none": return "关闭"
        case "minimal": return "最低"
        case "low": return "低"
        case "medium": return "中"
        case "high": return "高"
        case "xhigh": return "极高"
        case "ultra": return "超高"
        default: return value.isEmpty ? "推理" : value
        }
    }

    private func submit() {
        guard canSubmit else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let remoteAttachments = attachments.map(\.remoteValue)
        if client.isBusy {
            client.steer(trimmedPrompt, attachments: remoteAttachments, skills: selectedSkills)
        } else {
            client.sendPrompt(trimmedPrompt, attachments: remoteAttachments, skills: selectedSkills)
        }
        prompt = ""
        clearSelections()
    }

    private func toggleSkill(_ skill: RemoteSkill) {
        if selectedSkills.contains(where: { $0.path == skill.path }) {
            selectedSkills.removeAll { $0.path == skill.path }
        } else {
            selectedSkills.append(skill)
        }
        focused = true
    }

    private func toggleSpeech() {
        if speech.isRecording {
            speech.stop()
            return
        }
        focused = false
        speech.start(prefix: prompt) { value in
            prompt = value
        }
    }

    private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            attachmentError = "这台设备没有可用的相机"
            return
        }
        cameraPresented = true
    }

    private func importCameraImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.88) else {
            attachmentError = "无法读取相机照片"
            return
        }
        do {
            try appendAttachment(PendingAttachment(
                id: UUID(),
                name: "相机照片-\(attachments.count + 1).jpg",
                kind: "image",
                mimeType: "image/jpeg",
                data: data
            ))
        } catch {
            attachmentError = error.localizedDescription
        }
    }

    private func importPhotos(_ selection: [PhotosPickerItem]) {
        let remaining = maximumAttachmentCount - attachments.count
        guard remaining > 0 else {
            photoSelection = []
            attachmentError = "一次最多添加 \(maximumAttachmentCount) 个附件"
            return
        }
        isImporting = true
        let startingCount = attachments.count
        Task { @MainActor in
            defer {
                isImporting = false
                photoSelection = []
            }
            for (index, item) in selection.prefix(remaining).enumerated() {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) }) ?? .jpeg
                    let fileExtension = type.preferredFilenameExtension ?? "jpg"
                    let name = "图片-\(startingCount + index + 1).\(fileExtension)"
                    try appendAttachment(
                        PendingAttachment(
                            id: UUID(),
                            name: name,
                            kind: "image",
                            mimeType: type.preferredMIMEType ?? "image/jpeg",
                            data: data
                        )
                    )
                } catch {
                    attachmentError = error.localizedDescription
                    break
                }
            }
        }
    }

    private func importFiles(_ urls: [URL]) {
        let remaining = maximumAttachmentCount - attachments.count
        guard remaining > 0 else {
            attachmentError = "一次最多添加 \(maximumAttachmentCount) 个附件"
            return
        }
        isImporting = true
        Task { @MainActor in
            defer { isImporting = false }
            for url in urls.prefix(remaining) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                    let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                        ?? UTType(filenameExtension: url.pathExtension)
                        ?? .data
                    let isImage = type.conforms(to: .image)
                    if isImage, UIImage(data: data) == nil { throw CocoaError(.fileReadCorruptFile) }
                    try appendAttachment(
                        PendingAttachment(
                            id: UUID(),
                            name: url.lastPathComponent,
                            kind: isImage ? "image" : "document",
                            mimeType: type.preferredMIMEType ?? "application/octet-stream",
                            data: data
                        )
                    )
                } catch {
                    attachmentError = error.localizedDescription
                    break
                }
            }
        }
    }

    private func appendAttachment(_ attachment: PendingAttachment) throws {
        guard attachments.count < maximumAttachmentCount else {
            throw NSError(domain: "CodexRemote", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "一次最多添加 \(maximumAttachmentCount) 个附件"
            ])
        }
        guard attachment.data.count <= maximumAttachmentBytes else {
            throw NSError(domain: "CodexRemote", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "\(attachment.name) 超过 16 MB 限制"
            ])
        }
        let totalBytes = attachments.reduce(0) { $0 + $1.data.count } + attachment.data.count
        guard totalBytes <= maximumTotalBytes else {
            throw NSError(domain: "CodexRemote", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "本次附件总大小超过 28 MB"
            ])
        }
        attachments.append(attachment)
    }

    private func clearSelections() {
        attachments = []
        selectedSkills = []
        photoSelection = []
    }

    private func restoreFailedDeliveryIfNeeded() {
        let contextID = client.composerContextID
        guard !contextID.isEmpty,
              let delivery = client.failedDelivery(for: contextID) else { return }

        prompt = ComposerDraftState.merged(existing: prompt, recovered: delivery.text)

        var restoredAllAttachments = true
        var attachmentIDs = Set(attachments.map { $0.id.uuidString.lowercased() })
        for remote in delivery.attachments where attachmentIDs.insert(remote.id.lowercased()).inserted {
            guard let attachment = PendingAttachment(remoteValue: remote) else {
                restoredAllAttachments = false
                attachmentError = "无法恢复附件 \(remote.name)，原提交仍已保留"
                continue
            }
            do {
                try appendAttachment(attachment)
            } catch {
                restoredAllAttachments = false
                attachmentError = error.localizedDescription
            }
        }

        var selectedPaths = Set(selectedSkills.map(\.path))
        for skill in delivery.skills where selectedPaths.insert(skill.path).inserted {
            selectedSkills.append(skill)
        }

        guard restoredAllAttachments else { return }
        client.consumeFailedDelivery(id: delivery.id, contextID: contextID)
        focused = true
    }

    private func focusForNewTask() {
        guard client.isCreatingTask else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            focused = true
        }
    }
}

private struct DiffCounts {
    var additions = 0
    var deletions = 0
}

private func countDiffLines(_ text: String) -> DiffCounts {
    var result = DiffCounts()
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { result.additions += 1 }
        if line.hasPrefix("-") && !line.hasPrefix("---") { result.deletions += 1 }
    }
    return result
}

private struct InspectorView: View {
    @ObservedObject var client: RemoteClient
    @State private var tab = InspectorTab.activity

    private var activity: [RemoteTranscriptItem] {
        client.items.filter { $0.kind != "user" && $0.kind != "assistant" }
    }

    private var fileChanges: [RemoteFileChange] {
        var order: [String] = []
        var byPath: [String: RemoteFileChange] = [:]
        for change in client.items.flatMap({ $0.files ?? [] }) {
            if byPath[change.path] == nil { order.append(change.path) }
            if var existing = byPath[change.path], change.diff.isEmpty {
                existing.kind = change.kind
                byPath[change.path] = existing
            } else {
                byPath[change.path] = change
            }
        }
        return order.compactMap { byPath[$0] }
    }

    private var effectiveDiff: String {
        let live = client.diff.trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty { return client.diff }
        return fileChanges.map(\.diff)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "rectangle.3.group")
                    .foregroundStyle(Palette.accent)
                Text("任务详情").font(.headline)
                Spacer()
                if client.isBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(Palette.accent)
                        Text("运行中").font(.caption).foregroundStyle(Palette.accent)
                    }
                }
            }
            .padding(.horizontal, 14).frame(height: 54)

            Picker("任务详情", selection: $tab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12).padding(.bottom, 10)

            Divider().overlay(Palette.line)
            switch tab {
            case .activity: activityView
            case .files: filesView
            case .diff: diffView
            }
        }
        .background(Palette.sidebar.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }

    private var activityView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if activity.isEmpty {
                    emptyState(icon: "waveform.path.ecg", text: client.isBusy ? "等待活动输出" : "本任务暂无工具活动")
                } else {
                    ForEach(activity) { item in
                        ActivityRow(item: item)
                        Divider().overlay(Palette.line).padding(.leading, 42)
                    }
                }
            }
        }
        .background(Palette.canvas)
    }

    private var filesView: some View {
        VStack(spacing: 0) {
            if fileChanges.isEmpty {
                emptyState(icon: "doc.on.doc", text: "本任务暂无文件改动")
            } else {
                let counts = countDiffLines(fileChanges.map(\.diff).joined(separator: "\n"))
                HStack(spacing: 14) {
                    Label("\(fileChanges.count) 个文件", systemImage: "doc.on.doc")
                    Text("+\(counts.additions)").foregroundStyle(Palette.accent)
                    Text("-\(counts.deletions)").foregroundStyle(Palette.red)
                    Spacer()
                }
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 14).frame(height: 42)
                Divider().overlay(Palette.line)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(fileChanges) { change in
                            FileChangeRow(change: change)
                            Divider().overlay(Palette.line).padding(.leading, 42)
                        }
                    }
                }
            }
        }
        .background(Palette.canvas)
    }

    private var diffView: some View {
        VStack(spacing: 0) {
            if effectiveDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyState(icon: "doc.text.magnifyingglass", text: "本任务暂无 Diff")
            } else {
                let counts = countDiffLines(effectiveDiff)
                HStack(spacing: 14) {
                    Text("+\(counts.additions)").foregroundStyle(Palette.accent)
                    Text("-\(counts.deletions)").foregroundStyle(Palette.red)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = effectiveDiff
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("复制 Diff")
                }
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 14).frame(height: 42)
                Divider().overlay(Palette.line)
                DiffCodeView(text: effectiveDiff)
            }
        }
        .background(Palette.canvas)
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 11) {
            Spacer(minLength: 80)
            Image(systemName: icon).font(.system(size: 25)).foregroundStyle(Palette.textMuted)
            Text(text).font(.subheadline).foregroundStyle(Palette.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

}

private struct FileChangeRow: View {
    let change: RemoteFileChange
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.textSoft)
                        .frame(width: 18, height: 32)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 2) {
                    Text((change.path as NSString).lastPathComponent)
                        .font(.caption.weight(.semibold)).lineLimit(1)
                    Text(change.path)
                        .font(.caption2).foregroundStyle(Palette.textMuted).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(kindLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(kindTint)
                Button { UIPasteboard.general.string = change.path } label: {
                    Image(systemName: "doc.on.doc").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textMuted)
                .accessibilityLabel("复制文件路径")
            }
            .padding(.horizontal, 12).padding(.vertical, 7)

            if expanded {
                if change.diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("没有可显示的 Diff")
                        .font(.caption).foregroundStyle(Palette.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 40).padding(.bottom, 10)
                } else {
                    DiffCodeView(text: change.diff, maximumHeight: 300)
                        .padding(.leading, 39).padding(.bottom, 10)
                }
            }
        }
    }

    private var normalizedKind: String { change.kind.lowercased() }
    private var kindLabel: String {
        if normalizedKind.contains("add") || normalizedKind.contains("create") { return "新增" }
        if normalizedKind.contains("delete") || normalizedKind.contains("remove") { return "删除" }
        return "修改"
    }
    private var kindTint: Color {
        if kindLabel == "新增" { return Palette.accent }
        if kindLabel == "删除" { return Palette.red }
        return Palette.blue
    }
}

private struct DiffCodeView: View {
    let text: String
    var maximumHeight: CGFloat? = nil

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    DiffCodeLine(line: line)
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxHeight: maximumHeight)
        .background(Color(white: 0.975))
    }
}

private struct DiffCodeLine: View {
    let line: String

    var body: some View {
        Text(line.isEmpty ? " " : line)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(foreground)
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12).padding(.vertical, 2)
            .background(background)
    }

    private var foreground: Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return Color(red: 0.04, green: 0.42, blue: 0.24) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Palette.red }
        if line.hasPrefix("@@") { return Palette.blue }
        if line.hasPrefix("diff ") || line.hasPrefix("index ") { return Palette.textMuted }
        return Palette.codeText
    }

    private var background: Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return Palette.accent.opacity(0.10) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Palette.red.opacity(0.08) }
        if line.hasPrefix("@@") { return Palette.blue.opacity(0.08) }
        return Color.clear
    }
}

private struct ActivityRow: View {
    let item: RemoteTranscriptItem
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(item.text.isEmpty ? "无输出" : item.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.codeText.opacity(0.82))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8).padding(.leading, 29)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).foregroundStyle(tint).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                    if let status = item.status, !status.isEmpty {
                        Text(statusLabel(status))
                            .font(.caption2)
                            .foregroundStyle(status.lowercased().contains("fail") ? Palette.red : Palette.textMuted)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contextMenu {
            Button { UIPasteboard.general.string = item.text } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
        }
    }

    private var icon: String {
        switch item.kind {
        case "reasoning": return "brain"
        case "plan": return "checklist"
        case "file": return "doc.badge.gearshape"
        case "tool": return item.command == nil ? "wrench.and.screwdriver" : "terminal"
        default: return "info.circle"
        }
    }

    private var tint: Color {
        switch item.kind {
        case "reasoning", "plan": return Palette.amber
        case "file": return Palette.blue
        case "tool": return Palette.accent
        default: return Palette.textMuted
        }
    }

    private var title: String {
        if let command = item.command, !command.isEmpty {
            return command.split(whereSeparator: \.isNewline).first.map(String.init) ?? "终端命令"
        }
        if let toolName = item.toolName, !toolName.isEmpty { return toolName }
        switch item.kind {
        case "reasoning": return "思考"
        case "plan": return "计划"
        case "file": return "文件改动"
        case "tool": return "工具"
        default: return "系统"
        }
    }

    private func statusLabel(_ value: String) -> String {
        switch value.lowercased() {
        case "inprogress", "running": return "运行中"
        case "completed": return "已完成"
        case "failed": return "失败"
        case "declined": return "已拒绝"
        default: return value
        }
    }
}

private struct RenameSheet: View {
    let title: String
    @Binding var text: String
    let save: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("任务名称").font(.caption).foregroundStyle(Palette.textMuted)
                TextField(title, text: $text)
                    .focused($focused)
                    .textFieldStyle(.roundedBorder)
                Spacer()
            }
            .padding(18)
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle("重命名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }
}

private struct WorkspaceSheet: View {
    @ObservedObject var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Mac 上的绝对路径").font(.caption).foregroundStyle(Palette.textMuted)
                TextField("/Users/name/Projects/app", text: $path)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Text("新命令和文件操作会在这个工作区执行。")
                    .font(.caption).foregroundStyle(Palette.textMuted)
                Spacer()
            }
            .padding(18)
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle("工作区")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") { client.updateSettings(cwd: path); dismiss() }
                        .disabled(!path.hasPrefix("/"))
                }
            }
            .onAppear { path = client.taskSettings?.cwd ?? client.selectedTask?.cwd ?? "" }
        }
        .presentationDetents([.height(250)])
    }
}

private struct ApprovalSheet: View {
    @ObservedObject var client: RemoteClient
    let approval: RemoteApproval
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Label(approval.title, systemImage: "checkmark.shield")
                    .font(.title3.weight(.semibold)).foregroundStyle(Palette.amber)
                ScrollView {
                    Text(approval.detail)
                        .font(.callout.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 4)
                VStack(spacing: 9) {
                    Button {
                        client.answerApproval("approve"); dismiss()
                    } label: { Text("允许一次").frame(maxWidth: .infinity, minHeight: 42) }
                    .buttonStyle(.borderedProminent).tint(Palette.accent).foregroundStyle(.white)
                    if approval.allowsSessionApproval {
                        Button {
                            client.answerApproval("approveSession"); dismiss()
                        } label: { Text("本次会话允许").frame(maxWidth: .infinity, minHeight: 42) }
                        .buttonStyle(.bordered)
                    }
                    Button(role: .destructive) {
                        client.answerApproval("deny"); dismiss()
                    } label: { Text("拒绝").frame(maxWidth: .infinity, minHeight: 42) }
                    .buttonStyle(.bordered)
                }
            }
            .padding(20)
            .background(Palette.canvas.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭")
                }
            }
        }
    }
}
