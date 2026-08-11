import Foundation
import Network
import Security

@MainActor
final class RemoteClient: NSObject, ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var codexReady = false
    @Published private(set) var projects: [RemoteProject] = []
    @Published private(set) var tasks: [RemoteTaskSummary] = []
    @Published private(set) var models: [RemoteModel] = []
    @Published private(set) var plugins: [RemotePlugin] = []
    @Published private(set) var automations: [RemoteAutomation] = []
    @Published private(set) var selectedTaskID: String?
    @Published private(set) var items: [RemoteTranscriptItem] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isInterrupting = false
    @Published private(set) var activeTurnID: String?
    @Published private(set) var taskSettings: RemoteTaskSettings?
    @Published private(set) var selectedModel = ""
    @Published private(set) var selectedEffort = ""
    @Published private(set) var permissionMode = RemotePermissionMode.custom.rawValue
    @Published private(set) var planMode = false
    @Published private(set) var diff = ""
    @Published private(set) var plan: [RemotePlanStep] = []
    @Published private(set) var planExplanation: String?
    @Published private(set) var showingArchived = false
    @Published private(set) var isCreatingTask = false
    @Published private(set) var isSubmittingNewTask = false
    @Published private(set) var isLoadingTask = false
    @Published private(set) var queuedPrompt: String?
    @Published var pendingApproval: RemoteApproval?
    @Published private(set) var lastMessage: String?
    @Published var previewURL: URL?
    @Published private(set) var loadingResourcePaths = Set<String>()
    @Published private(set) var pendingCommandCount = 0
    @Published private(set) var connectionMessage = "尚未连接"
    @Published private(set) var networkAvailable = true
    @Published private(set) var roundTripLatencyMs: Int?
    @Published private(set) var lastHeartbeatAt: Date?
    @Published private(set) var latestAutomationRunThreadID: String?
    @Published private(set) var composerDraftState = ComposerDraftState()
    @Published private(set) var failedDeliveries: [String: FailedDelivery] = [:]
    @Published private(set) var completionFeedbackToken = 0
    @Published private(set) var interruptionFeedbackToken = 0
    @Published private(set) var approvalFeedbackToken = 0
    @Published private(set) var errorFeedbackToken = 0

    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var timeoutTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatTimeoutTask: Task<Void, Never>?
    private var outboxRetryTask: Task<Void, Never>?
    private var interruptConfirmationFallbackTask: Task<Void, Never>?
    private var completionFeedbackTask: Task<Void, Never>?
    private var connectionURL: URL?
    private var connectionToken: String?
    private var reconnectEnabled = false
    private var reconnectAttempt = 0
    private var pendingHeartbeatID: UUID?
    private var requestedInitialTask = false
    private var creationRequestID: String?
    private var creationTimeoutTask: Task<Void, Never>?
    private var creationWorkspace: String?
    private var creationProjectID: String?
    private var transientThreadIDs = Set<String>()
    private var cachedItemsByThread: [String: [RemoteTranscriptItem]] = [:]
    private var cachedPlansByThread: [String: [RemotePlanStep]] = [:]
    private var cachedPlanExplanationsByThread: [String: String] = [:]
    private var cacheSaveTask: Task<Void, Never>?
    private var pendingDeltas: [String: String] = [:]
    private var deltaFlushTask: Task<Void, Never>?
    private var pluginRefreshTask: Task<Void, Never>?
    private var pendingResourceRequests: [String: RemoteResource] = [:]
    private var lastApprovalFeedbackID: String?
    private let clientID: String
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.codexremote.network-monitor")
    private var outbox: [String: RemoteCommand] = [:]
    private var outboxRetrySchedule = ReliableRetrySchedule(retryDelay: 8)
    private var interruptsAwaitingRuntimeConfirmation = Set<String>()
    private var activeTurnFailed = false
    private var activeTurnErrorFeedbackEmitted = false
    private var feedbackCoordinator = TaskFeedbackCoordinator()

    private static let reliableCommandTypes: Set<String> = [
        RemoteMessage.taskCreate,
        RemoteMessage.taskRename,
        RemoteMessage.taskPin,
        RemoteMessage.taskArchive,
        RemoteMessage.taskUnarchive,
        RemoteMessage.taskDelete,
        RemoteMessage.taskSettingsUpdate,
        RemoteMessage.prompt,
        RemoteMessage.steer,
        RemoteMessage.interrupt,
        RemoteMessage.approvalDecision,
        RemoteMessage.automationSave,
        RemoteMessage.automationSetEnabled,
        RemoteMessage.automationRun,
        RemoteMessage.automationDelete
    ]

    private struct OutboxEnvelope: Codable {
        var version: Int
        var commands: [RemoteCommand]
    }

    private struct CacheEnvelope: Codable {
        var projects: [RemoteProject]
        var tasks: [RemoteTaskSummary]
        var models: [RemoteModel]?
        var automations: [RemoteAutomation]?
        var selectedTaskID: String?
        var selectedItems: [RemoteTranscriptItem]
        var itemsByThread: [String: [RemoteTranscriptItem]]?
        var plansByThread: [String: [RemotePlanStep]]?
        var planExplanationsByThread: [String: String]?
        var selectedSettings: RemoteTaskSettings?
        var showingArchived: Bool
        var composerDraftState: ComposerDraftState?
        var failedDeliveries: [String: FailedDelivery]?
    }

    override init() {
        clientID = Self.loadOrCreateClientID()
        super.init()
        restoreCache()
        restoreOutbox()
        startNetworkMonitor()
    }

    var savedPairingToken: String {
        let defaults = UserDefaults.standard
        let fallbackKey = "codexRemote.token"
        let fallback = defaults.string(forKey: fallbackKey) ?? ""
        if !fallback.isEmpty {
            Self.persistSecretWithFallback(
                fallback,
                account: "pairing-token",
                fallbackKey: fallbackKey
            )
            return fallback
        }
        return Self.readSecret(account: "pairing-token") ?? ""
    }

    var selectedTask: RemoteTaskSummary? {
        tasks.first(where: { $0.id == selectedTaskID })
    }

    var isSelectedTaskTransient: Bool {
        guard let selectedTaskID else { return false }
        return transientThreadIDs.contains(selectedTaskID)
    }

    func isTransientTask(_ id: String) -> Bool {
        transientThreadIDs.contains(id)
    }

    var composerContextID: String {
        if isCreatingTask {
            return ComposerDraftState.newTaskContextID(
                projectID: creationProjectID,
                cwd: creationWorkspace
            )
        }
        guard let selectedTaskID else { return "" }
        return ComposerDraftState.taskContextID(selectedTaskID)
    }

    func composerDraft(for contextID: String) -> String {
        composerDraftState.draft(for: contextID)
    }

    func hasComposerDraft(taskID: String) -> Bool {
        composerDraftState.hasDraft(for: ComposerDraftState.taskContextID(taskID))
    }

    func saveComposerDraft(_ value: String, for contextID: String) {
        guard !contextID.isEmpty else { return }
        var updated = composerDraftState
        updated.setDraft(value, for: contextID)
        guard updated != composerDraftState else { return }
        composerDraftState = updated
        scheduleCacheSave()
    }

    func failedDelivery(for contextID: String) -> FailedDelivery? {
        failedDeliveries[contextID]
    }

    func consumeFailedDelivery(id: String, contextID: String) {
        guard failedDeliveries[contextID]?.id == id else { return }
        var updated = failedDeliveries
        updated.removeValue(forKey: contextID)
        guard persistCache(failedDeliveriesOverride: updated) else { return }
        failedDeliveries = updated
    }

    func connect(host: String, port: String, token: String) {
        reconnectEnabled = false
        reconnectTask?.cancel()
        reconnectTask = nil
        closeTransport()
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty,
              let portNumber = Int(port),
              (1...65535).contains(portNumber),
              !cleanToken.isEmpty else {
            state = .failed("请填写 Mac 地址、端口和配对密钥")
            return
        }

        var components = URLComponents()
        components.scheme = "ws"
        components.host = cleanHost
        components.port = portNumber
        components.path = "/control"
        guard let url = components.url else {
            state = .failed("Mac 地址格式不正确")
            return
        }

        connectionURL = url
        connectionToken = cleanToken
        Self.persistSecretWithFallback(
            cleanToken,
            account: "pairing-token",
            fallbackKey: "codexRemote.token"
        )
        reconnectEnabled = true
        reconnectAttempt = 0
        openConnection()
    }

    func ensureConnected() {
        guard reconnectEnabled, connectionURL != nil,
              state != .connected, state != .connecting else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        openConnection()
    }

    func reconnectNow() {
        guard reconnectEnabled, connectionURL != nil else { return }
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        openConnection()
    }

    var connectionDiagnostics: String {
        let stateText: String
        switch state {
        case .disconnected: stateText = "已断开"
        case .connecting: stateText = "正在连接"
        case .connected: stateText = codexReady ? "Mac 与 Codex 在线" : "Mac 在线，Codex 启动中"
        case .failed(let message): stateText = message
        }
        let endpoint = connectionURL.map { url in
            let host = url.host ?? "未知"
            return "\(host):\(url.port ?? 8765)"
        } ?? "未配置"
        let latency = roundTripLatencyMs.map { "\($0) ms" } ?? "尚未测量"
        let lastHeartbeat = lastHeartbeatAt.map {
            ISO8601DateFormatter().string(from: $0)
        } ?? "无"
        return [
            "Codex Remote 连接诊断",
            "状态：\(stateText)",
            "地址：\(endpoint)",
            "网络：\(networkAvailable ? "可用" : "不可用")",
            "往返延迟：\(latency)",
            "最近心跳：\(lastHeartbeat)",
            "待确认操作：\(pendingCommandCount)"
        ].joined(separator: "\n")
    }

    func resumeConnection() {
        if state == .connected {
            startHeartbeat()
            refresh()
            sendHeartbeat()
            scheduleInterruptConfirmationFallback()
        } else {
            ensureConnected()
        }
    }

    func pauseConnectionMonitoring() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        heartbeatTimeoutTask?.cancel()
        heartbeatTimeoutTask = nil
        interruptConfirmationFallbackTask?.cancel()
        interruptConfirmationFallbackTask = nil
        pendingHeartbeatID = nil
    }

    func persistLocalState() {
        cacheSaveTask?.cancel()
        cacheSaveTask = nil
        persistCache()
        persistOutbox()
    }

    private func openConnection() {
        guard reconnectEnabled, let connectionURL else { return }
        closeTransport()
        interruptsAwaitingRuntimeConfirmation = Set(
            outbox.values.compactMap { command in
                command.type == RemoteMessage.interrupt ? command.threadId : nil
            }
        )
        if let selectedTaskID {
            interruptsAwaitingRuntimeConfirmation.insert(selectedTaskID)
        }
        roundTripLatencyMs = nil
        state = .connecting
        connectionMessage = reconnectAttempt == 0
            ? "正在连接 Mac"
            : "正在第 \(reconnectAttempt) 次重连"
        codexReady = false
        requestedInitialTask = false
        guard let connectionToken else { return }
        let activeSession = connectionSession()
        var request = URLRequest(url: connectionURL)
        request.timeoutInterval = 12
        request.setValue("Bearer \(connectionToken)", forHTTPHeaderField: "Authorization")
        request.setValue(clientID, forHTTPHeaderField: "X-CodexRemote-Client-ID")
        request.setValue("2", forHTTPHeaderField: "X-CodexRemote-Protocol")
        let task = activeSession.webSocketTask(with: request)
        task.maximumMessageSize = 48 * 1024 * 1024
        socket = task
        task.resume()
        receiveLoop()

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, let self, self.state == .connecting else { return }
            self.fail("连接超时，请检查 Tailscale、地址和 Mac companion")
        }
    }

    func disconnect(clearContent: Bool = true) {
        reconnectEnabled = false
        reconnectAttempt = 0
        connectionURL = nil
        connectionToken = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        outboxRetryTask?.cancel()
        outboxRetryTask = nil
        cancelPendingCompletionFeedback()
        closeTransport()
        resetSession()
        creationTimeoutTask?.cancel()
        creationTimeoutTask = nil
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        pluginRefreshTask?.cancel()
        pluginRefreshTask = nil
        pendingDeltas.removeAll()
        pendingResourceRequests.removeAll()
        loadingResourcePaths.removeAll()
        previewURL = nil
        state = .disconnected
        connectionMessage = "已断开"
        codexReady = false
        pendingApproval = nil
        isBusy = false
        isInterrupting = false
        activeTurnID = nil
        activeTurnFailed = false
        activeTurnErrorFeedbackEmitted = false
        taskSettings = nil
        diff = ""
        plan = []
        planExplanation = nil
        isCreatingTask = false
        isSubmittingNewTask = false
        isLoadingTask = false
        queuedPrompt = nil
        creationRequestID = nil
        creationWorkspace = nil
        creationProjectID = nil
        transientThreadIDs.removeAll()
        if clearContent {
            projects = []
            tasks = []
            models = []
            plugins = []
            automations = []
            selectedTaskID = nil
            selectedModel = ""
            selectedEffort = ""
            items = []
            cachedItemsByThread.removeAll()
            cachedPlansByThread.removeAll()
            cachedPlanExplanationsByThread.removeAll()
        }
    }

    func refresh() {
        send(RemoteCommand(type: RemoteMessage.refresh, archived: showingArchived))
        send(RemoteCommand(type: RemoteMessage.projectsRequest))
        send(RemoteCommand(type: RemoteMessage.modelsRequest))
        send(RemoteCommand(type: RemoteMessage.automationsRequest))
        requestPlugins()
        if let selectedTaskID { send(RemoteCommand(type: RemoteMessage.taskOpen, threadId: selectedTaskID)) }
    }

    func showArchived(_ archived: Bool) {
        cancelPendingCompletionFeedback()
        flushPendingDeltas()
        cacheCurrentItems()
        creationTimeoutTask?.cancel()
        creationTimeoutTask = nil
        showingArchived = archived
        isCreatingTask = false
        isSubmittingNewTask = false
        isLoadingTask = false
        queuedPrompt = nil
        creationRequestID = nil
        creationWorkspace = nil
        creationProjectID = nil
        selectedTaskID = nil
        items = []
        taskSettings = nil
        diff = ""
        plan = []
        planExplanation = nil
        isBusy = false
        isInterrupting = false
        activeTurnID = nil
        send(RemoteCommand(type: RemoteMessage.tasksRequest, archived: archived))
        scheduleCacheSave()
    }

    func selectTask(_ id: String) {
        if selectedTaskID == id {
            isLoadingTask = items.isEmpty
            send(RemoteCommand(type: RemoteMessage.taskOpen, threadId: id))
            return
        }
        cancelPendingCompletionFeedback()
        flushPendingDeltas()
        cacheCurrentItems()
        creationTimeoutTask?.cancel()
        creationTimeoutTask = nil
        isCreatingTask = false
        isSubmittingNewTask = false
        queuedPrompt = nil
        creationRequestID = nil
        creationWorkspace = nil
        creationProjectID = nil
        selectedTaskID = id
        items = cachedItemsByThread[id] ?? []
        isLoadingTask = items.isEmpty
        isBusy = false
        isInterrupting = false
        activeTurnID = nil
        taskSettings = nil
        selectedModel = ""
        selectedEffort = ""
        permissionMode = RemotePermissionMode.custom.rawValue
        planMode = false
        diff = ""
        plan = cachedPlansByThread[id] ?? []
        planExplanation = cachedPlanExplanationsByThread[id]
        pendingApproval = nil
        send(RemoteCommand(type: RemoteMessage.taskOpen, threadId: id))
        schedulePluginRefresh(cwd: tasks.first(where: { $0.id == id })?.cwd, delay: 500_000_000)
        scheduleCacheSave()
    }

    func createTask(cwd: String? = nil, projectId: String? = nil) {
        if let pending = outbox.values.first(where: { $0.type == RemoteMessage.taskCreate }) {
            if let createdThreadID = pending.threadId, !createdThreadID.isEmpty {
                selectTask(createdThreadID)
                lastMessage = "上一个任务已创建，失败的首轮提交仍在安全恢复"
            } else {
                resumePendingTaskCreation(pending)
                lastMessage = "上一个新任务仍在确认，正在使用原请求自动重试"
            }
            return
        }
        cancelPendingCompletionFeedback()
        flushPendingDeltas()
        cacheCurrentItems()
        if showingArchived { showingArchived = false }
        creationTimeoutTask?.cancel()
        creationTimeoutTask = nil
        creationRequestID = nil
        creationWorkspace = cwd
        creationProjectID = projectId
        isCreatingTask = true
        isSubmittingNewTask = false
        queuedPrompt = nil
        selectedTaskID = nil
        items = []
        isLoadingTask = false
        isBusy = false
        isInterrupting = false
        activeTurnID = nil
        activeTurnFailed = false
        activeTurnErrorFeedbackEmitted = false
        taskSettings = nil
        permissionMode = RemotePermissionMode.custom.rawValue
        planMode = false
        diff = ""
        plan = []
        planExplanation = nil
        pendingApproval = nil
        ensureModelSelection()
        scheduleCacheSave()
    }

    func renameTask(_ name: String, id: String? = nil) {
        guard let threadID = id ?? selectedTaskID else { return }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if let index = tasks.firstIndex(where: { $0.id == threadID }) {
            tasks[index].title = value
            scheduleCacheSave()
        }
        send(RemoteCommand(type: RemoteMessage.taskRename, threadId: threadID, value: value))
    }

    func setTaskPinned(_ pinned: Bool, id: String? = nil) {
        guard let threadID = id ?? selectedTaskID else { return }
        if let index = tasks.firstIndex(where: { $0.id == threadID }) {
            tasks[index].pinned = pinned
            tasks[index].pinOrder = pinned ? 0 : nil
            scheduleCacheSave()
        }
        send(RemoteCommand(type: RemoteMessage.taskPin, threadId: threadID, pinned: pinned))
    }

    func archiveTask(_ id: String? = nil) {
        guard let threadID = id ?? selectedTaskID else { return }
        send(RemoteCommand(type: RemoteMessage.taskArchive, threadId: threadID))
    }

    func unarchiveTask(_ id: String? = nil) {
        guard let threadID = id ?? selectedTaskID else { return }
        send(RemoteCommand(type: RemoteMessage.taskUnarchive, threadId: threadID))
    }

    func deleteTask(_ id: String? = nil) {
        guard let threadID = id ?? selectedTaskID else { return }
        send(RemoteCommand(type: RemoteMessage.taskDelete, threadId: threadID))
    }

    func updateSettings(
        model: String? = nil,
        effort: String? = nil,
        cwd: String? = nil,
        permissionMode: String? = nil,
        planMode: Bool? = nil
    ) {
        if let model, !model.isEmpty {
            let selected = models.first { $0.model == model || $0.id == model }
            selectedModel = selected?.model ?? model
            if effort == nil, let selected { selectedEffort = selected.defaultEffort }
        }
        if let effort, !effort.isEmpty { selectedEffort = effort }
        if let permissionMode, RemotePermissionMode(rawValue: permissionMode) != nil {
            self.permissionMode = permissionMode
        }
        if let planMode { self.planMode = planMode }
        guard let selectedTaskID else { return }
        send(RemoteCommand(
            type: RemoteMessage.taskSettingsUpdate,
            threadId: selectedTaskID,
            cwd: cwd,
            model: model,
            effort: effort,
            permissionMode: permissionMode,
            planMode: planMode
        ))
    }

    func setPermissionMode(_ mode: RemotePermissionMode) {
        permissionMode = mode.rawValue
        guard selectedTaskID != nil else { return }
        updateSettings(permissionMode: mode.rawValue)
    }

    func setPlanMode(_ enabled: Bool) {
        planMode = enabled
        guard selectedTaskID != nil else { return }
        updateSettings(planMode: enabled)
    }

    func sendPrompt(
        _ value: String,
        attachments: [RemoteAttachment] = [],
        skills: [RemoteSkill] = []
    ) {
        let prompt = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !attachments.isEmpty || !skills.isEmpty else { return }
        var draftParts: [String] = []
        if !prompt.isEmpty { draftParts.append(prompt) }
        draftParts.append(contentsOf: attachments.map { "附件：\($0.name)" })
        draftParts.append(contentsOf: skills.map { "插件：\($0.name)" })
        let draftText = draftParts.joined(separator: "\n")
        if isCreatingTask {
            guard !isSubmittingNewTask else { return }
            let requestID = UUID().uuidString
            creationRequestID = requestID
            queuedPrompt = draftText
            isSubmittingNewTask = true
            items = [RemoteTranscriptItem(id: "draft-\(requestID)", kind: "user", text: draftText)]
            send(RemoteCommand(
                type: RemoteMessage.taskCreate,
                value: prompt,
                cwd: creationWorkspace,
                requestId: requestID,
                model: selectedModel.nilIfEmpty,
                effort: selectedEffort.nilIfEmpty,
                projectId: creationProjectID,
                permissionMode: permissionMode,
                planMode: planMode,
                attachments: attachments,
                skills: skills,
                messageId: requestID
            ))
            scheduleCreationTimeout(
                requestID: requestID,
                after: 20_000_000_000,
                message: "Mac 未确认创建请求，请检查连接后重试"
            )
            return
        }
        guard selectedTaskID != nil else {
            lastMessage = "请先新建或选择一个任务"
            return
        }
        let messageID = UUID().uuidString
        items.append(RemoteTranscriptItem(id: "draft-\(messageID)", kind: "user", text: draftText))
        cacheCurrentItems()
        persistCache()
        send(RemoteCommand(
            type: RemoteMessage.prompt,
            threadId: selectedTaskID,
            value: prompt,
            model: selectedModel.nilIfEmpty,
            effort: selectedEffort.nilIfEmpty,
            permissionMode: permissionMode,
            planMode: planMode,
            afterInterrupt: isInterrupting ? true : nil,
            attachments: attachments,
            skills: skills,
            messageId: messageID
        ))
    }

    func steer(
        _ value: String,
        attachments: [RemoteAttachment] = [],
        skills: [RemoteSkill] = []
    ) {
        let prompt = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !attachments.isEmpty || !skills.isEmpty,
              let selectedTaskID, isBusy else { return }
        let messageID = UUID().uuidString
        send(RemoteCommand(
            type: RemoteMessage.steer,
            threadId: selectedTaskID,
            turnId: activeTurnID,
            value: prompt,
            model: selectedModel.nilIfEmpty,
            effort: selectedEffort.nilIfEmpty,
            permissionMode: permissionMode,
            planMode: planMode,
            attachments: attachments,
            skills: skills,
            messageId: messageID
        ))
    }

    func requestPlugins(cwd: String? = nil) {
        pluginRefreshTask?.cancel()
        pluginRefreshTask = nil
        send(RemoteCommand(type: RemoteMessage.pluginsRequest, cwd: cwd))
    }

    func saveAutomation(_ automation: RemoteAutomation) {
        if let index = automations.firstIndex(where: { $0.id == automation.id }) {
            automations[index] = automation
        } else {
            automations.insert(automation, at: 0)
        }
        scheduleCacheSave()
        send(RemoteCommand(type: RemoteMessage.automationSave, automation: automation))
    }

    func setAutomationEnabled(_ enabled: Bool, id: String) {
        guard let index = automations.firstIndex(where: { $0.id == id }) else { return }
        automations[index].status = enabled ? "ACTIVE" : "PAUSED"
        automations[index].updatedAt = Date().timeIntervalSince1970 * 1_000
        scheduleCacheSave()
        send(RemoteCommand(
            type: RemoteMessage.automationSetEnabled,
            value: enabled ? "ACTIVE" : "PAUSED",
            automation: automations[index]
        ))
    }

    func runAutomation(_ automation: RemoteAutomation) {
        latestAutomationRunThreadID = nil
        send(RemoteCommand(type: RemoteMessage.automationRun, automation: automation))
    }

    func deleteAutomation(_ automation: RemoteAutomation) {
        automations.removeAll { $0.id == automation.id }
        scheduleCacheSave()
        send(RemoteCommand(type: RemoteMessage.automationDelete, automation: automation))
    }

    func openResource(_ resource: RemoteResource) {
        guard !loadingResourcePaths.contains(resource.path) else { return }
        let requestID = UUID().uuidString
        pendingResourceRequests[requestID] = resource
        loadingResourcePaths.insert(resource.path)
        send(RemoteCommand(
            type: RemoteMessage.resourceRequest,
            value: resource.path,
            requestId: requestID
        ))
    }

    func dismissPreview() {
        previewURL = nil
    }

    private func schedulePluginRefresh(cwd: String?, delay: UInt64) {
        pluginRefreshTask?.cancel()
        pluginRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.requestPlugins(cwd: cwd)
        }
    }

    func interrupt() {
        guard let selectedTaskID, isBusy, !isInterrupting else { return }
        isInterrupting = true
        send(RemoteCommand(
            type: RemoteMessage.interrupt,
            threadId: selectedTaskID,
            turnId: activeTurnID
        ))
    }

    func answerApproval(_ decision: String) {
        guard let approval = pendingApproval else { return }
        send(RemoteCommand(type: RemoteMessage.approvalDecision, requestId: approval.id, decision: decision))
        if let index = items.firstIndex(where: { $0.id == "approval-\(approval.id)" }) {
            items[index].status = decision == "deny" ? "declined" : "approved"
            cacheCurrentItems()
            scheduleCacheSave()
        }
        pendingApproval = nil
    }

    func dismissMessage() {
        lastMessage = nil
    }

    private func send(_ incoming: RemoteCommand) {
        var command = incoming
        let isReliable = Self.reliableCommandTypes.contains(command.type)
        if isReliable {
            if command.type == RemoteMessage.interrupt,
               let threadID = command.threadId {
                if let duplicate = outbox.values.first(where: {
                    $0.type == RemoteMessage.interrupt
                        && $0.threadId == threadID
                        && $0.turnId == command.turnId
                }) {
                    if state == .connected,
                       !interruptsAwaitingRuntimeConfirmation.contains(threadID) {
                        transmit(duplicate)
                    }
                    scheduleOutboxRetry()
                    return
                }
                discardPendingInterrupts(
                    threadID: threadID,
                    retainingTurnID: command.turnId
                )
            }
            let messageID = command.messageId ?? command.requestId ?? UUID().uuidString
            command.messageId = messageID
            command.clientId = clientID
            command.createdAt = command.createdAt ?? Date().timeIntervalSince1970
            if outbox[messageID] == nil {
                outbox[messageID] = command
                outboxRetrySchedule.enqueue(
                    messageID: messageID,
                    now: command.createdAt ?? Date().timeIntervalSince1970
                )
                persistOutbox()
            }
        }
        if command.type == RemoteMessage.interrupt,
           let threadID = command.threadId,
           interruptsAwaitingRuntimeConfirmation.contains(threadID) {
            scheduleOutboxRetry()
            return
        }
        if shouldDeferUntilPendingInterruptSettles(command) {
            scheduleOutboxRetry()
            return
        }
        transmit(command)
        if isReliable { scheduleOutboxRetry() }
    }

    private func transmit(_ command: RemoteCommand) {
        guard let socket else {
            if Self.reliableCommandTypes.contains(command.type) {
                lastMessage = "消息已安全保存，连接恢复后自动发送"
            } else {
                lastMessage = "连接正在恢复，请连接成功后再发送"
            }
            ensureConnected()
            return
        }
        guard let data = try? RemoteJSON.encoder.encode(command),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard self?.state == .connected else { return }
                self?.fail(self?.friendlyMessage(for: error) ?? "连接已断开")
            }
        }
    }

    private func replayOutbox(threadID: String? = nil) {
        guard state == .connected, !outbox.isEmpty else { return }
        let queued = outbox.values.filter {
            threadID == nil || $0.threadId == threadID
        }.sorted {
            let left = $0.createdAt ?? 0
            let right = $1.createdAt ?? 0
            if left == right { return ($0.messageId ?? "") < ($1.messageId ?? "") }
            return left < right
        }
        let now = Date().timeIntervalSince1970
        for command in queued {
            if command.type == RemoteMessage.interrupt,
               let threadID = command.threadId,
               interruptsAwaitingRuntimeConfirmation.contains(threadID) {
                continue
            }
            if shouldDeferUntilPendingInterruptSettles(command) { continue }
            transmit(command)
            if let messageID = command.messageId {
                outboxRetrySchedule.markAttempted(messageID: messageID, now: now)
            }
        }
        pendingCommandCount = outbox.count
        scheduleOutboxRetry()
    }

    private func scheduleOutboxRetry() {
        outboxRetryTask?.cancel()
        guard !outbox.isEmpty, let deadline = outboxRetrySchedule.nextDeadline else {
            outboxRetryTask = nil
            return
        }
        let delay = max(0, deadline - Date().timeIntervalSince1970)
        outboxRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.outboxRetryTask = nil
            guard self.state == .connected else { return }
            let now = Date().timeIntervalSince1970
            for messageID in self.outboxRetrySchedule.dueMessageIDs(at: now) {
                guard let command = self.outbox[messageID] else {
                    self.outboxRetrySchedule.acknowledge(messageID: messageID)
                    continue
                }
                if command.type == RemoteMessage.interrupt,
                   let threadID = command.threadId,
                   self.interruptsAwaitingRuntimeConfirmation.contains(threadID) {
                    self.outboxRetrySchedule.markAttempted(messageID: messageID, now: now)
                    continue
                }
                if self.shouldDeferUntilPendingInterruptSettles(command) {
                    self.outboxRetrySchedule.markAttempted(messageID: messageID, now: now)
                    continue
                }
                self.transmit(command)
                self.outboxRetrySchedule.markAttempted(messageID: messageID, now: now)
            }
            self.scheduleOutboxRetry()
        }
    }

    private func shouldDeferUntilPendingInterruptSettles(_ command: RemoteCommand) -> Bool {
        guard command.type == RemoteMessage.prompt || command.type == RemoteMessage.steer,
              let threadID = command.threadId else { return false }
        let pendingInterrupts = outbox.values.compactMap { pending -> ReliableInterruptCandidate? in
            guard pending.type == RemoteMessage.interrupt,
                  pending.threadId == threadID,
                  let messageID = pending.messageId else { return nil }
            return ReliableInterruptCandidate(
                messageID: messageID,
                turnID: pending.turnId,
                createdAt: pending.createdAt ?? 0
            )
        }
        return ReliableCommandOrderingPolicy.shouldDeferUntilInterruptSettles(
            commandCreatedAt: command.createdAt,
            pendingInterrupts: pendingInterrupts
        )
    }

    private func discardPendingInterrupts(
        threadID: String,
        retainingTurnID: String? = nil
    ) {
        let discarded = outbox.compactMap { messageID, command -> String? in
            guard command.type == RemoteMessage.interrupt,
                  command.threadId == threadID,
                  retainingTurnID == nil || command.turnId != retainingTurnID else { return nil }
            return messageID
        }
        guard !discarded.isEmpty else { return }
        for messageID in discarded {
            outbox.removeValue(forKey: messageID)
            outboxRetrySchedule.acknowledge(messageID: messageID)
        }
        _ = persistOutbox()
    }

    private func reconcilePendingInterrupts(
        threadID: String,
        busy: Bool,
        activeTurnID: String?,
        inactiveTurnID: String? = nil,
        isFullSnapshot: Bool
    ) {
        let wasAwaitingRuntimeConfirmation = interruptsAwaitingRuntimeConfirmation.remove(threadID) != nil
        let commands = outbox.values
            .filter { $0.type == RemoteMessage.interrupt && $0.threadId == threadID }
        let candidates = commands.compactMap { command -> ReliableInterruptCandidate? in
            guard let messageID = command.messageId else { return nil }
            return ReliableInterruptCandidate(
                messageID: messageID,
                turnID: command.turnId,
                createdAt: command.createdAt ?? 0
            )
        }
        let decision = ReliableInterruptPolicy.reconcile(
            candidates,
            busy: busy,
            activeTurnID: activeTurnID,
            inactiveTurnID: inactiveTurnID,
            isFullSnapshot: isFullSnapshot,
            wasAwaitingRuntimeConfirmation: wasAwaitingRuntimeConfirmation
        )
        if decision.deferUntilRuntimeConfirmation {
            interruptsAwaitingRuntimeConfirmation.insert(threadID)
            scheduleInterruptConfirmationFallback()
            scheduleOutboxRetry()
            return
        }
        for messageID in decision.discardedMessageIDs {
            outbox.removeValue(forKey: messageID)
            outboxRetrySchedule.acknowledge(messageID: messageID)
        }
        if !decision.discardedMessageIDs.isEmpty {
            _ = persistOutbox()
        }

        if !busy,
           selectedTaskID == threadID,
           isFullSnapshot || inactiveTurnID == nil || self.activeTurnID == inactiveTurnID {
            isInterrupting = false
        } else if busy,
                  let activeTurnID,
                  selectedTaskID == threadID {
            let hasMatchingInterrupt = outbox.values.contains { command in
                command.type == RemoteMessage.interrupt
                    && command.threadId == threadID
                    && (command.turnId == nil || command.turnId == activeTurnID)
            }
            isInterrupting = hasMatchingInterrupt
        }

        if let messageID = decision.messageIDToSend,
           let retained = outbox[messageID],
           state == .connected {
            transmit(retained)
            outboxRetrySchedule.markAttempted(
                messageID: messageID,
                now: Date().timeIntervalSince1970
            )
        }
        if !commands.isEmpty,
           !outbox.values.contains(where: {
               $0.type == RemoteMessage.interrupt && $0.threadId == threadID
           }) {
            scheduleInterruptConfirmationFallback()
            replayOutbox(threadID: threadID)
            return
        }
        scheduleInterruptConfirmationFallback()
        scheduleOutboxRetry()
    }

    private func scheduleInterruptConfirmationFallback() {
        interruptConfirmationFallbackTask?.cancel()
        let waitingThreadIDs = Set(outbox.values.compactMap { command -> String? in
            guard command.type == RemoteMessage.interrupt,
                  let threadID = command.threadId,
                  interruptsAwaitingRuntimeConfirmation.contains(threadID) else { return nil }
            return threadID
        })
        guard state == .connected, !waitingThreadIDs.isEmpty else {
            interruptConfirmationFallbackTask = nil
            return
        }
        interruptConfirmationFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self, self.state == .connected else { return }
            self.interruptConfirmationFallbackTask = nil
            for threadID in waitingThreadIDs.sorted() {
                guard self.interruptsAwaitingRuntimeConfirmation.contains(threadID) else { continue }
                let candidates = self.outbox.values.compactMap { command -> ReliableInterruptCandidate? in
                    guard command.type == RemoteMessage.interrupt,
                          command.threadId == threadID,
                          let messageID = command.messageId else { return nil }
                    return ReliableInterruptCandidate(
                        messageID: messageID,
                        turnID: command.turnId,
                        createdAt: command.createdAt ?? 0
                    )
                }
                guard let messageID = ReliableInterruptFallbackPolicy.messageIDToProbe(
                    candidates,
                    confirmationWaitElapsed: true
                ), let command = self.outbox[messageID] else {
                    self.interruptsAwaitingRuntimeConfirmation.remove(threadID)
                    continue
                }
                self.interruptsAwaitingRuntimeConfirmation.remove(threadID)
                self.transmit(command)
                self.outboxRetrySchedule.markAttempted(
                    messageID: messageID,
                    now: Date().timeIntervalSince1970
                )
            }
            self.scheduleOutboxRetry()
            self.scheduleInterruptConfirmationFallback()
        }
    }

    private func receiveLoop() {
        guard let socket else { return }
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === socket else { return }
                switch result {
                case .success(.string(let text)):
                    self.handle(text: text)
                    self.receiveLoop()
                case .success(.data(let data)):
                    if let text = String(data: data, encoding: .utf8) { self.handle(text: text) }
                    self.receiveLoop()
                case .failure(let error):
                    self.fail(self.friendlyMessage(for: error))
                @unknown default:
                    self.fail("收到未知的连接数据")
                }
            }
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? RemoteJSON.decoder.decode(RemoteEvent.self, from: data) else { return }
        switch event.type {
        case RemoteMessage.hello:
            timeoutTask?.cancel()
            timeoutTask = nil
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectAttempt = 0
            state = .connected
            connectionMessage = "Mac 与 Codex 在线"
            codexReady = event.codexReady ?? false
            lastMessage = nil
            startHeartbeat()
            sendHeartbeat()
            for threadID in interruptsAwaitingRuntimeConfirmation.sorted() {
                send(RemoteCommand(type: RemoteMessage.taskOpen, threadId: threadID))
            }
            replayOutbox()
            scheduleInterruptConfirmationFallback()
            send(RemoteCommand(type: RemoteMessage.tasksRequest, archived: showingArchived))
            send(RemoteCommand(type: RemoteMessage.projectsRequest))
            send(RemoteCommand(type: RemoteMessage.modelsRequest))
            send(RemoteCommand(type: RemoteMessage.automationsRequest))
            schedulePluginRefresh(cwd: selectedTask?.cwd, delay: 800_000_000)
        case RemoteMessage.projects:
            projects = event.projects ?? []
            scheduleCacheSave()
        case RemoteMessage.tasks:
            guard (event.archived ?? false) == showingArchived else { return }
            let incoming = event.tasks ?? []
            let incomingIDs = Set(incoming.map(\.id))
            transientThreadIDs.subtract(incomingIDs)
            // This list is filtered by archive state, so absence is not proof of deletion.
            // Pending interrupts are settled by authoritative snapshots or explicit actions.
            let localOnly = tasks.filter { transientThreadIDs.contains($0.id) && !incomingIDs.contains($0.id) }
            tasks = incoming + localOnly
            scheduleCacheSave()
            if requestedInitialTask {
                if let selectedTaskID, !tasks.contains(where: { $0.id == selectedTaskID }) {
                    self.selectedTaskID = nil
                    items = []
                    isBusy = false
                    isInterrupting = false
                    activeTurnID = nil
                    taskSettings = nil
                    diff = ""
                    if let first = tasks.first { selectTask(first.id) }
                }
                return
            }
            requestedInitialTask = true
            guard !isCreatingTask else { return }
            if let selectedTaskID, tasks.contains(where: { $0.id == selectedTaskID }) {
                send(RemoteCommand(type: RemoteMessage.taskOpen, threadId: selectedTaskID))
            } else if let first = tasks.first {
                selectTask(first.id)
            }
        case RemoteMessage.taskSnapshot:
            let snapshotThreadID = event.task?.id ?? event.threadId
            let runtimeAuthoritative = event.runtimeAuthoritative != false
            if let task = event.task {
                upsertTask(task)
            }
            if let snapshotThreadID {
                cachedItemsByThread[snapshotThreadID] = event.items ?? []
                if let incomingPlan = event.plan {
                    cachedPlansByThread[snapshotThreadID] = incomingPlan
                }
                if let explanation = event.planExplanation {
                    cachedPlanExplanationsByThread[snapshotThreadID] = explanation
                } else {
                    cachedPlanExplanationsByThread.removeValue(forKey: snapshotThreadID)
                }
                if runtimeAuthoritative {
                    reconcilePendingInterrupts(
                        threadID: snapshotThreadID,
                        busy: event.busy ?? false,
                        activeTurnID: event.turnId,
                        isFullSnapshot: true
                    )
                }
            }
            guard snapshotThreadID == selectedTaskID else {
                scheduleCacheSave()
                return
            }
            lastMessage = nil
            deltaFlushTask?.cancel()
            deltaFlushTask = nil
            pendingDeltas.removeAll()
            items = event.items ?? []
            isLoadingTask = false
            if runtimeAuthoritative {
                let wasBusy = isBusy
                isBusy = event.busy ?? false
                if isBusy && !wasBusy {
                    activeTurnFailed = false
                    activeTurnErrorFeedbackEmitted = false
                }
                activeTurnID = isBusy ? event.turnId : nil
                if !isBusy {
                    isInterrupting = false
                    activeTurnFailed = false
                    activeTurnErrorFeedbackEmitted = false
                }
            }
            if let settings = event.settings { apply(settings) }
            diff = event.diff ?? ""
            if let incomingPlan = event.plan {
                plan = incomingPlan
                if let snapshotThreadID { cachedPlansByThread[snapshotThreadID] = incomingPlan }
            }
            planExplanation = event.planExplanation
            if let snapshotThreadID {
                if let explanation = event.planExplanation {
                    cachedPlanExplanationsByThread[snapshotThreadID] = explanation
                } else {
                    cachedPlanExplanationsByThread.removeValue(forKey: snapshotThreadID)
                }
            }
            scheduleCacheSave()
        case RemoteMessage.models:
            if let incoming = event.models, !incoming.isEmpty {
                models = incoming
            }
            ensureModelSelection()
            scheduleCacheSave()
        case RemoteMessage.plugins:
            plugins = event.plugins ?? []
        case RemoteMessage.automations:
            automations = event.automations ?? []
            scheduleCacheSave()
        case RemoteMessage.resourceData:
            handleResource(event)
        case RemoteMessage.taskSettings:
            guard event.threadId == selectedTaskID else { return }
            if let settings = event.settings { apply(settings) }
        case RemoteMessage.taskItem:
            guard let threadID = event.threadId, let item = event.item else { return }
            guard threadID == selectedTaskID else {
                upsertCachedItem(item, threadID: threadID)
                return
            }
            if !item.text.isEmpty { pendingDeltas.removeValue(forKey: item.id) }
            if item.status?.lowercased() == "failed" {
                activeTurnFailed = true
                recordFeedbackFailure()
            }
            upsertItem(item)
        case RemoteMessage.taskDelta:
            guard event.threadId == selectedTaskID,
                  let itemId = event.itemId,
                  let delta = event.delta else { return }
            pendingDeltas[itemId, default: ""] += delta
            scheduleDeltaFlush()
        case RemoteMessage.taskState:
            let wasInterruptingBeforeReconcile = isInterrupting
            let activeTurnBeforeEvent = activeTurnID
            if let threadID = event.threadId {
                reconcilePendingInterrupts(
                    threadID: threadID,
                    busy: event.busy ?? false,
                    activeTurnID: event.busy == true ? event.turnId : nil,
                    inactiveTurnID: event.busy == false ? event.turnId : nil,
                    isFullSnapshot: false
                )
            }
            guard event.threadId == selectedTaskID else { return }
            if event.busy == false,
               let inactiveTurnID = event.turnId,
               let activeTurnBeforeEvent,
               inactiveTurnID != activeTurnBeforeEvent {
                return
            }
            if event.busy == false { flushPendingDeltas() }
            let wasBusy = isBusy
            let wasInterrupting = wasInterruptingBeforeReconcile
            isBusy = event.busy ?? false
            if isBusy && !wasBusy {
                activeTurnFailed = false
                activeTurnErrorFeedbackEmitted = false
            }
            activeTurnID = isBusy ? (event.turnId ?? activeTurnID) : nil
            if !isBusy {
                isInterrupting = false
                switch TaskFeedbackOutcome.resolve(
                    wasBusy: wasBusy,
                    wasInterrupting: wasInterrupting,
                    failed: activeTurnFailed
                ) {
                case .completed:
                    scheduleCompletionFeedback()
                case .interrupted:
                    cancelPendingCompletionFeedback()
                    interruptionFeedbackToken &+= 1
                case .failed:
                    recordFeedbackFailure()
                    if !activeTurnErrorFeedbackEmitted { errorFeedbackToken &+= 1 }
                case nil:
                    break
                }
                activeTurnFailed = false
                activeTurnErrorFeedbackEmitted = false
            }
            scheduleCacheSave()
        case RemoteMessage.taskDiff:
            guard event.threadId == selectedTaskID else { return }
            diff = event.diff ?? ""
        case RemoteMessage.taskPlan:
            guard let threadID = event.threadId, let incomingPlan = event.plan else { return }
            cachedPlansByThread[threadID] = incomingPlan
            if let explanation = event.planExplanation {
                cachedPlanExplanationsByThread[threadID] = explanation
            } else {
                cachedPlanExplanationsByThread.removeValue(forKey: threadID)
            }
            guard threadID == selectedTaskID else { return }
            plan = incomingPlan
            planExplanation = event.planExplanation
            scheduleCacheSave()
        case RemoteMessage.taskAction:
            if event.value == "creating", event.requestId == creationRequestID,
               let requestID = event.requestId {
                scheduleCreationTimeout(
                    requestID: requestID,
                    after: 90_000_000_000,
                    message: "Mac 已收到请求，但 Codex 创建任务超过 90 秒，请重试"
                )
                return
            }
            guard let threadId = event.threadId else { return }
            if event.value == "created", event.requestId == creationRequestID {
                creationTimeoutTask?.cancel()
                creationTimeoutTask = nil
                let prompt = queuedPrompt
                queuedPrompt = nil
                creationRequestID = nil
                isCreatingTask = false
                isSubmittingNewTask = false
                let workspace = creationWorkspace ?? ""
                let projectID = creationProjectID
                creationWorkspace = nil
                creationProjectID = nil
                transientThreadIDs.insert(threadId)
                if !tasks.contains(where: { $0.id == threadId }) {
                    tasks.insert(
                        RemoteTaskSummary(
                            id: threadId,
                            title: "新任务",
                            preview: "",
                            cwd: workspace,
                            updatedAt: Date().timeIntervalSince1970,
                            status: "active",
                            projectId: projectID,
                            projectOrder: 0
                        ),
                        at: 0
                    )
                }
                selectedTaskID = threadId
                isLoadingTask = true
                if let prompt, items.isEmpty {
                    items = [RemoteTranscriptItem(id: "draft-\(threadId)", kind: "user", text: prompt)]
                }
                scheduleCacheSave()
            } else if event.value == "pinned" || event.value == "unpinned" {
                if let index = tasks.firstIndex(where: { $0.id == threadId }) {
                    tasks[index].pinned = event.value == "pinned"
                    tasks[index].pinOrder = event.value == "pinned" ? 0 : nil
                }
                scheduleCacheSave()
            } else if event.value == "archived" || event.value == "unarchived" || event.value == "deleted" {
                discardPendingInterrupts(threadID: threadId)
                interruptsAwaitingRuntimeConfirmation.remove(threadId)
                tasks.removeAll { $0.id == threadId }
                transientThreadIDs.remove(threadId)
                cachedItemsByThread.removeValue(forKey: threadId)
                cachedPlansByThread.removeValue(forKey: threadId)
                cachedPlanExplanationsByThread.removeValue(forKey: threadId)
                failedDeliveries.removeValue(forKey: ComposerDraftState.taskContextID(threadId))
                if selectedTaskID == threadId {
                    selectedTaskID = nil
                    items = []
                    isBusy = false
                    isInterrupting = false
                    activeTurnID = nil
                    taskSettings = nil
                    diff = ""
                    plan = []
                    planExplanation = nil
                    isLoadingTask = false
                    if let first = tasks.first { selectTask(first.id) }
                }
                scheduleCacheSave()
            }
        case RemoteMessage.commandAck:
            handleCommandAcknowledgement(event)
        case RemoteMessage.approval:
            pendingApproval = event.approval
            if let approval = event.approval, approval.id != lastApprovalFeedbackID {
                lastApprovalFeedbackID = approval.id
                approvalFeedbackToken &+= 1
            }
            if let approval = event.approval,
               approval.threadId == nil || approval.threadId == selectedTaskID {
                upsertItem(RemoteTranscriptItem(
                    id: "approval-\(approval.id)",
                    kind: "approval",
                    text: approval.detail,
                    status: "pending",
                    toolName: approval.title
                ))
            }
        case RemoteMessage.error:
            if let threadId = event.threadId, threadId != selectedTaskID { return }
            recordFeedbackFailure()
            if isBusy {
                activeTurnFailed = true
                activeTurnErrorFeedbackEmitted = true
            }
            if let requestID = event.requestId, requestID == creationRequestID {
                lastMessage = "\(event.message ?? "Codex 请求失败")，正在等待创建结果确认"
            } else {
                lastMessage = event.message ?? "Codex 请求失败"
            }
            errorFeedbackToken &+= 1
        default:
            break
        }
    }

    private func handleResource(_ event: RemoteEvent) {
        guard let requestID = event.requestId,
              let expected = pendingResourceRequests.removeValue(forKey: requestID) else { return }
        loadingResourcePaths.remove(expected.path)
        guard event.message == nil, let payload = event.resource else {
            lastMessage = event.message ?? "无法读取这个文件"
            return
        }
        guard payload.resource.path == expected.path,
              payload.resource.sizeBytes <= 24 * 1024 * 1024,
              let data = Data(base64Encoded: payload.dataBase64),
              data.count == payload.resource.sizeBytes else {
            lastMessage = "收到的文件数据无效"
            return
        }
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexRemotePreview", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let safeName = (payload.resource.name as NSString).lastPathComponent
            let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(safeName)")
            try data.write(to: destination, options: .atomic)
            previewURL = destination
        } catch {
            lastMessage = "无法打开文件：\(error.localizedDescription)"
        }
    }

    private func handleCommandAcknowledgement(_ event: RemoteEvent) {
        guard let messageID = event.messageId,
              let command = outbox[messageID] else { return }
        let interruptAlreadyInactive = command.type == RemoteMessage.interrupt
            && event.code == RemoteEventCode.noActiveTurn
        if event.accepted == true || interruptAlreadyInactive {
            let acknowledgedMessageIDs: [String]
            if command.type == RemoteMessage.interrupt {
                acknowledgedMessageIDs = outbox.compactMap { queuedMessageID, queuedCommand in
                    guard queuedCommand.type == RemoteMessage.interrupt,
                          queuedCommand.threadId == command.threadId,
                          queuedCommand.turnId == command.turnId else { return nil }
                    return queuedMessageID
                }
            } else {
                acknowledgedMessageIDs = [messageID]
            }
            for acknowledgedMessageID in acknowledgedMessageIDs {
                outbox.removeValue(forKey: acknowledgedMessageID)
                outboxRetrySchedule.acknowledge(messageID: acknowledgedMessageID)
            }
            persistOutbox()
            scheduleOutboxRetry()
            if command.type == RemoteMessage.interrupt {
                let wasBusy = isBusy
                let wasInterrupting = isInterrupting
                var runtime = MobileTaskRuntimeState(
                    isBusy: isBusy,
                    isInterrupting: isInterrupting,
                    activeTurnID: activeTurnID
                )
                let cleared = runtime.reconcileInterruptAcknowledgement(
                    commandTurnID: command.turnId,
                    accepted: event.accepted == true,
                    code: event.code
                )
                isBusy = runtime.isBusy
                isInterrupting = runtime.isInterrupting
                activeTurnID = runtime.activeTurnID
                if cleared {
                    if let threadID = command.threadId {
                        discardPendingInterrupts(threadID: threadID)
                    }
                    activeTurnFailed = false
                    activeTurnErrorFeedbackEmitted = false
                    cancelPendingCompletionFeedback()
                    if wasBusy && wasInterrupting { interruptionFeedbackToken &+= 1 }
                }
                if interruptAlreadyInactive,
                   let threadID = command.threadId,
                   threadID == selectedTaskID {
                    send(RemoteCommand(type: RemoteMessage.taskOpen, threadId: threadID))
                }
            }
            if command.type == RemoteMessage.taskCreate, let threadID = event.threadId {
                recoverCreatedTask(command: command, threadID: threadID)
            }
            if command.type == RemoteMessage.automationRun, let threadID = event.threadId {
                latestAutomationRunThreadID = threadID
                send(RemoteCommand(type: RemoteMessage.tasksRequest, archived: false))
            }
            if lastMessage == "消息已安全保存，连接恢复后自动发送" {
                lastMessage = nil
            }
            if command.type.hasPrefix("automation") {
                send(RemoteCommand(type: RemoteMessage.automationsRequest))
            }
            if command.type == RemoteMessage.interrupt, let threadID = command.threadId {
                replayOutbox(threadID: threadID)
            }
            return
        }

        if event.retryable == true,
           !(command.type == RemoteMessage.taskCreate && event.threadId != nil) {
            lastMessage = event.message ?? "Mac 暂未接受消息，正在自动重试"
            scheduleOutboxRetry()
            return
        }

        recordFeedbackFailure()
        if command.type == RemoteMessage.interrupt {
            var runtime = MobileTaskRuntimeState(
                isBusy: isBusy,
                isInterrupting: isInterrupting,
                activeTurnID: activeTurnID
            )
            _ = runtime.reconcileInterruptAcknowledgement(
                commandTurnID: command.turnId,
                accepted: false,
                code: event.code
            )
            isBusy = runtime.isBusy
            isInterrupting = runtime.isInterrupting
            activeTurnID = runtime.activeTurnID
        }
        var retainedCommand = command
        if command.type == RemoteMessage.taskCreate, let threadID = event.threadId {
            retainedCommand.threadId = threadID
            outbox[messageID] = retainedCommand
            recoverCreatedTask(command: command, threadID: threadID)
        }
        if let index = items.firstIndex(where: { $0.id == "draft-\(messageID)" }) {
            items[index].status = "failed"
        }
        cacheCurrentItems()
        let recovery = persistFailedDelivery(command, acknowledgedThreadID: event.threadId)
        guard RecoveryPersistenceGate.mayRemoveOutbox(
            recoveryRequired: recovery.required,
            recoveryPersisted: recovery.persisted
        ) else {
            _ = persistOutbox()
            outboxRetrySchedule.markAttempted(
                messageID: messageID,
                now: Date().timeIntervalSince1970
            )
            scheduleOutboxRetry()
            lastMessage = "无法安全保存失败提交，原请求仍保留在待发送队列"
            errorFeedbackToken &+= 1
            return
        }

        outbox.removeValue(forKey: messageID)
        guard persistOutbox() else {
            outbox[messageID] = retainedCommand
            pendingCommandCount = outbox.count
            _ = persistOutbox()
            outboxRetrySchedule.markAttempted(
                messageID: messageID,
                now: Date().timeIntervalSince1970
            )
            scheduleOutboxRetry()
            lastMessage = "失败提交已恢复，但队列更新失败，原请求仍会安全重试"
            errorFeedbackToken &+= 1
            return
        }
        outboxRetrySchedule.acknowledge(messageID: messageID)
        scheduleOutboxRetry()
        if command.type == RemoteMessage.interrupt, let threadID = command.threadId {
            replayOutbox(threadID: threadID)
        }
        if command.type == RemoteMessage.taskCreate {
            creationTimeoutTask?.cancel()
            creationTimeoutTask = nil
            if event.threadId == nil,
               creationRequestID == messageID || creationRequestID == command.requestId {
                creationRequestID = nil
                queuedPrompt = nil
                isSubmittingNewTask = false
            }
        }
        if command.type.hasPrefix("automation") {
            send(RemoteCommand(type: RemoteMessage.automationsRequest))
        }
        let baseMessage = event.message ?? "Mac 拒绝了这次操作"
        lastMessage = recovery.required ? "\(baseMessage)，原提交已恢复" : baseMessage
        errorFeedbackToken &+= 1
    }

    private func persistFailedDelivery(
        _ command: RemoteCommand,
        acknowledgedThreadID: String?
    ) -> (required: Bool, persisted: Bool) {
        guard command.type == RemoteMessage.prompt
                || command.type == RemoteMessage.steer
                || command.type == RemoteMessage.taskCreate else { return (false, true) }
        let value = command.value ?? ""
        let attachments = command.attachments ?? []
        let skills = command.skills ?? []
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty
                || !skills.isEmpty else { return (false, true) }
        guard let plan = FailedDeliveryRecoveryPlan.resolve(
            commandType: command.type,
            commandThreadID: command.threadId,
            acknowledgedThreadID: acknowledgedThreadID,
            projectID: command.projectId,
            cwd: command.cwd
        ) else { return (false, true) }
        let contextID = plan.contextID
        var delivery = FailedDelivery(
            id: command.messageId ?? command.requestId ?? UUID().uuidString,
            contextID: contextID,
            commandType: command.type,
            text: value,
            attachments: attachments,
            skills: skills,
            createdAt: command.createdAt ?? Date().timeIntervalSince1970
        )
        var updated = failedDeliveries
        if let existing = updated[contextID] {
            delivery.text = ComposerDraftState.merged(existing: existing.text, recovered: delivery.text)
            delivery.attachments = Self.mergedAttachments(existing.attachments, delivery.attachments)
            delivery.skills = Self.mergedSkills(existing.skills, delivery.skills)
            delivery.createdAt = min(existing.createdAt, delivery.createdAt)
        }
        updated[contextID] = delivery
        guard persistCache(failedDeliveriesOverride: updated) else { return (true, false) }
        failedDeliveries = updated
        return (true, true)
    }

    private static func mergedAttachments(
        _ existing: [RemoteAttachment],
        _ recovered: [RemoteAttachment]
    ) -> [RemoteAttachment] {
        var result = existing
        var ids = Set(existing.map(\.id))
        for attachment in recovered where ids.insert(attachment.id).inserted {
            result.append(attachment)
        }
        return result
    }

    private static func mergedSkills(_ existing: [RemoteSkill], _ recovered: [RemoteSkill]) -> [RemoteSkill] {
        var result = existing
        var paths = Set(existing.map(\.path))
        for skill in recovered where paths.insert(skill.path).inserted {
            result.append(skill)
        }
        return result
    }

    private func recoverCreatedTask(command: RemoteCommand, threadID: String) {
        creationTimeoutTask?.cancel()
        creationTimeoutTask = nil
        let wasCurrentCreation = creationRequestID == command.messageId || creationRequestID == command.requestId
        if wasCurrentCreation {
            creationRequestID = nil
            queuedPrompt = nil
            isCreatingTask = false
            isSubmittingNewTask = false
            creationWorkspace = nil
            creationProjectID = nil
        }
        transientThreadIDs.insert(threadID)
        if !tasks.contains(where: { $0.id == threadID }) {
            tasks.insert(RemoteTaskSummary(
                id: threadID,
                title: "新任务",
                preview: command.value ?? "",
                cwd: command.cwd ?? "",
                updatedAt: Date().timeIntervalSince1970,
                status: "active",
                projectId: command.projectId,
                projectOrder: 0
            ), at: 0)
        }
        if wasCurrentCreation || selectedTaskID == nil {
            selectedTaskID = threadID
            isLoadingTask = true
            send(RemoteCommand(type: RemoteMessage.taskOpen, threadId: threadID))
        }
        send(RemoteCommand(type: RemoteMessage.tasksRequest, archived: false))
        scheduleCacheSave()
    }

    private func resumePendingTaskCreation(_ command: RemoteCommand) {
        let requestID = command.messageId ?? command.requestId ?? ""
        guard !requestID.isEmpty else { return }
        if creationRequestID != requestID || !isCreatingTask {
            flushPendingDeltas()
            cacheCurrentItems()
            if showingArchived { showingArchived = false }
            creationWorkspace = command.cwd
            creationProjectID = command.projectId
            isCreatingTask = true
            selectedTaskID = nil
            isLoadingTask = false
            isBusy = false
            isInterrupting = false
            activeTurnID = nil
            activeTurnFailed = false
            activeTurnErrorFeedbackEmitted = false
            taskSettings = nil
            diff = ""
            plan = []
            planExplanation = nil
            pendingApproval = nil
        }
        creationRequestID = requestID
        isSubmittingNewTask = true
        let text = command.value ?? ""
        var displayParts = text.isEmpty ? [] : [text]
        displayParts.append(contentsOf: (command.attachments ?? []).map { "附件：\($0.name)" })
        displayParts.append(contentsOf: (command.skills ?? []).map { "插件：\($0.name)" })
        queuedPrompt = displayParts.joined(separator: "\n")
        items = [RemoteTranscriptItem(id: "draft-\(requestID)", kind: "user", text: queuedPrompt ?? "")]
        scheduleCreationTimeout(
            requestID: requestID,
            after: 20_000_000_000,
            message: "Mac 尚未确认创建请求，仍在使用原请求自动重试"
        )
        ensureModelSelection()
        scheduleCacheSave()
    }

    private func scheduleCreationTimeout(requestID: String, after nanoseconds: UInt64, message: String) {
        creationTimeoutTask?.cancel()
        creationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self, self.creationRequestID == requestID else { return }
            self.creationTimeoutTask = nil
            self.lastMessage = message
            self.scheduleOutboxRetry()
        }
    }

    private func scheduleCompletionFeedback() {
        completionFeedbackTask?.cancel()
        let token = feedbackCoordinator.scheduleCompletion()
        completionFeedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, let self,
                  self.feedbackCoordinator.consumeCompletion(token) else { return }
            self.completionFeedbackTask = nil
            self.completionFeedbackToken &+= 1
        }
    }

    private func cancelPendingCompletionFeedback() {
        completionFeedbackTask?.cancel()
        completionFeedbackTask = nil
        feedbackCoordinator.cancelCompletion()
    }

    private func recordFeedbackFailure() {
        completionFeedbackTask?.cancel()
        completionFeedbackTask = nil
        feedbackCoordinator.recordFailure()
    }

    private func upsertTask(_ task: RemoteTaskSummary) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.insert(task, at: 0)
        }
        scheduleCacheSave()
    }

    private func upsertItem(_ item: RemoteTranscriptItem) {
        if item.kind == "user" {
            items.removeAll { $0.id.hasPrefix("draft-") }
        }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        if items.count > 300 { items = Array(items.suffix(300)) }
        if let selectedTaskID { cachedItemsByThread[selectedTaskID] = items }
        scheduleCacheSave()
    }

    private func upsertCachedItem(_ item: RemoteTranscriptItem, threadID: String) {
        var cached = cachedItemsByThread[threadID] ?? []
        if item.kind == "user" {
            cached.removeAll { $0.id.hasPrefix("draft-") }
        }
        if let index = cached.firstIndex(where: { $0.id == item.id }) {
            cached[index] = item
        } else {
            cached.append(item)
        }
        if cached.count > 300 { cached = Array(cached.suffix(300)) }
        cachedItemsByThread[threadID] = cached
        scheduleCacheSave()
    }

    private func scheduleDeltaFlush() {
        guard deltaFlushTask == nil else { return }
        deltaFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard !Task.isCancelled, let self else { return }
            self.deltaFlushTask = nil
            self.flushPendingDeltas()
        }
    }

    private func flushPendingDeltas() {
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        guard !pendingDeltas.isEmpty else { return }
        let deltas = pendingDeltas
        pendingDeltas.removeAll()
        for (itemID, delta) in deltas where !delta.isEmpty {
            if let index = items.firstIndex(where: { $0.id == itemID }) {
                items[index].text += delta
            } else {
                items.append(RemoteTranscriptItem(id: itemID, kind: "assistant", text: delta))
            }
        }
        if let selectedTaskID { cachedItemsByThread[selectedTaskID] = items }
        scheduleCacheSave()
    }

    private func fail(_ message: String) {
        closeTransport()
        codexReady = false
        guard reconnectEnabled else {
            state = .failed(message)
            return
        }
        state = .failed("\(message)，正在自动重连")
        connectionMessage = message
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectEnabled, connectionURL != nil else { return }
        reconnectTask?.cancel()
        let delays: [UInt64] = [1, 2, 4, 8, 10]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt += 1
        connectionMessage = "\(connectionMessage) · \(delay) 秒后重试"
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled, let self, self.reconnectEnabled,
                  self.state != .connected else { return }
            self.reconnectTask = nil
            self.openConnection()
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled, let self, self.state == .connected else { return }
                self.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() {
        guard let socket, state == .connected, pendingHeartbeatID == nil else { return }
        let heartbeatID = UUID()
        let heartbeatStartedAt = DispatchTime.now().uptimeNanoseconds
        pendingHeartbeatID = heartbeatID
        heartbeatTimeoutTask?.cancel()
        heartbeatTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self,
                  self.pendingHeartbeatID == heartbeatID else { return }
            self.fail("Mac 心跳超时")
        }
        socket.sendPing { [weak self, weak socket] error in
            Task { @MainActor in
                guard let self, let socket, self.socket === socket,
                      self.pendingHeartbeatID == heartbeatID else { return }
                self.pendingHeartbeatID = nil
                self.heartbeatTimeoutTask?.cancel()
                self.heartbeatTimeoutTask = nil
                if let error {
                    self.fail(self.friendlyMessage(for: error))
                } else {
                    let elapsed = DispatchTime.now().uptimeNanoseconds - heartbeatStartedAt
                    self.roundTripLatencyMs = max(1, Int(elapsed / 1_000_000))
                    self.lastHeartbeatAt = Date()
                }
            }
        }
    }

    private func closeTransport() {
        timeoutTask?.cancel()
        timeoutTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        heartbeatTimeoutTask?.cancel()
        heartbeatTimeoutTask = nil
        interruptConfirmationFallbackTask?.cancel()
        interruptConfirmationFallbackTask = nil
        pendingHeartbeatID = nil
        let oldSocket = socket
        socket = nil
        oldSocket?.cancel()
    }

    private func connectionSession() -> URLSession {
        if let session { return session }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 120
        let created = URLSession(configuration: configuration)
        session = created
        return created
    }

    private func resetSession() {
        let oldSession = session
        session = nil
        oldSession?.invalidateAndCancel()
    }

    private func friendlyMessage(for error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorCannotConnectToHost:
            return "Mac companion 未运行或端口不可达"
        case NSURLErrorTimedOut:
            return "连接超时，请检查 Tailscale 网络"
        case NSURLErrorBadServerResponse, NSURLErrorUserAuthenticationRequired:
            return "配对密钥失效或 Mac 拒绝了连接"
        case NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet:
            return "网络连接已断开"
        case 57:
            return "Mac 已断开连接"
        default:
            return "连接失败：\(error.localizedDescription)"
        }
    }

    private func cacheCurrentItems() {
        guard let selectedTaskID else { return }
        cachedItemsByThread[selectedTaskID] = items
        cachedPlansByThread[selectedTaskID] = plan
        if let planExplanation {
            cachedPlanExplanationsByThread[selectedTaskID] = planExplanation
        } else {
            cachedPlanExplanationsByThread.removeValue(forKey: selectedTaskID)
        }
    }

    private func scheduleCacheSave() {
        cacheSaveTask?.cancel()
        cacheSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.persistCache()
        }
    }

    private func restoreCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? RemoteJSON.decoder.decode(CacheEnvelope.self, from: data) else { return }
        projects = cache.projects
        tasks = cache.tasks
        models = cache.models ?? []
        automations = cache.automations ?? []
        showingArchived = cache.showingArchived
        composerDraftState = cache.composerDraftState ?? ComposerDraftState()
        failedDeliveries = cache.failedDeliveries ?? [:]
        cachedItemsByThread = cache.itemsByThread ?? [:]
        cachedPlansByThread = cache.plansByThread ?? [:]
        cachedPlanExplanationsByThread = cache.planExplanationsByThread ?? [:]
        if let id = cache.selectedTaskID, tasks.contains(where: { $0.id == id }) {
            selectedTaskID = id
            items = cachedItemsByThread[id] ?? cache.selectedItems
            plan = cachedPlansByThread[id] ?? []
            planExplanation = cachedPlanExplanationsByThread[id]
            if let settings = cache.selectedSettings { apply(settings) }
            cachedItemsByThread[id] = items
        }
        ensureModelSelection()
    }

    private func apply(_ settings: RemoteTaskSettings) {
        taskSettings = settings
        if !settings.model.isEmpty { selectedModel = settings.model }
        if let effort = settings.effort, !effort.isEmpty { selectedEffort = effort }
        if let mode = settings.permissionMode, RemotePermissionMode(rawValue: mode) != nil {
            permissionMode = mode
        }
        if let enabled = settings.planMode { planMode = enabled }
    }

    private func ensureModelSelection() {
        guard !models.isEmpty else {
            selectedModel = ""
            selectedEffort = ""
            return
        }
        if let selected = models.first(where: { $0.model == selectedModel || $0.id == selectedModel }) {
            selectedModel = selected.model
            if selectedEffort.isEmpty || !selected.efforts.contains(where: { $0.value == selectedEffort }) {
                selectedEffort = selected.defaultEffort
            }
            return
        }
        let fallback = models.first(where: \.isDefault) ?? models[0]
        selectedModel = fallback.model
        selectedEffort = fallback.defaultEffort
    }

    @discardableResult
    private func persistCache(
        failedDeliveriesOverride: [String: FailedDelivery]? = nil
    ) -> Bool {
        cacheCurrentItems()
        let retainedThreadIDs = Set(
            tasks.sorted { $0.updatedAt > $1.updatedAt }
                .prefix(24)
                .map(\.id)
        ).union(selectedTaskID.map { [$0] } ?? [])
        let retainedItems = cachedItemsByThread.filter { retainedThreadIDs.contains($0.key) }
        cachedItemsByThread = retainedItems
        let retainedPlans = cachedPlansByThread.filter { retainedThreadIDs.contains($0.key) }
        let retainedPlanExplanations = cachedPlanExplanationsByThread.filter { retainedThreadIDs.contains($0.key) }
        cachedPlansByThread = retainedPlans
        cachedPlanExplanationsByThread = retainedPlanExplanations
        let persistedItems = retainedItems.mapValues { threadItems in
            Array(threadItems.suffix(300)).map { item in
                var capped = item
                if capped.text.count > 80_000 {
                    capped.text = "…已省略较早输出…\n" + String(capped.text.suffix(80_000))
                }
                return capped
            }
        }
        let envelope = CacheEnvelope(
            projects: projects,
            tasks: tasks,
            models: models,
            automations: automations,
            selectedTaskID: selectedTaskID,
            selectedItems: selectedTaskID.flatMap { persistedItems[$0] } ?? items,
            itemsByThread: persistedItems,
            plansByThread: retainedPlans,
            planExplanationsByThread: retainedPlanExplanations,
            selectedSettings: taskSettings,
            showingArchived: showingArchived,
            composerDraftState: composerDraftState,
            failedDeliveries: failedDeliveriesOverride ?? failedDeliveries
        )
        guard let data = try? RemoteJSON.encoder.encode(envelope) else { return false }
        let directory = cacheURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: cacheURL.path
            )
            return true
        } catch {
            return false
        }
    }

    private func restoreOutbox() {
        guard let data = try? Data(contentsOf: outboxURL),
              let envelope = try? RemoteJSON.decoder.decode(OutboxEnvelope.self, from: data),
              envelope.version == 1 else { return }
        var restored: [String: RemoteCommand] = [:]
        var restoredInterruptKeys = Set<String>()
        let commands = envelope.commands.sorted {
            let left = $0.createdAt ?? 0
            let right = $1.createdAt ?? 0
            if left == right { return ($0.messageId ?? "") < ($1.messageId ?? "") }
            return left < right
        }
        for command in commands {
            guard let messageID = command.messageId,
                  Self.reliableCommandTypes.contains(command.type) else { continue }
            if command.type == RemoteMessage.interrupt {
                let key = "\(command.threadId ?? "")\u{0}\(command.turnId ?? "")"
                guard restoredInterruptKeys.insert(key).inserted else { continue }
            }
            restored[messageID] = command
        }
        outbox = restored
        let now = Date().timeIntervalSince1970
        for (messageID, command) in outbox {
            outboxRetrySchedule.enqueue(
                messageID: messageID,
                now: min(command.createdAt ?? now, now)
            )
        }
        pendingCommandCount = outbox.count
    }

    @discardableResult
    private func persistOutbox() -> Bool {
        pendingCommandCount = outbox.count
        let commands = outbox.values.sorted {
            let left = $0.createdAt ?? 0
            let right = $1.createdAt ?? 0
            if left == right { return ($0.messageId ?? "") < ($1.messageId ?? "") }
            return left < right
        }
        let envelope = OutboxEnvelope(version: 1, commands: commands)
        guard let data = try? RemoteJSON.encoder.encode(envelope) else { return false }
        let directory = outboxURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: outboxURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: outboxURL.path
            )
            return true
        } catch {
            lastMessage = "无法安全保存待发送消息：\(error.localizedDescription)"
            return false
        }
    }

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.networkAvailable = path.status == .satisfied
                if path.status == .satisfied {
                    self?.networkBecameAvailable()
                } else {
                    self?.connectionMessage = "手机当前没有可用网络"
                }
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func networkBecameAvailable() {
        guard reconnectEnabled else { return }
        if state == .connected {
            sendHeartbeat()
            return
        }
        guard state != .connecting else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        openConnection()
    }

    private static func loadOrCreateClientID() -> String {
        let fallbackKey = "codexRemote.clientID"
        if let fallback = UserDefaults.standard.string(forKey: fallbackKey),
           !fallback.isEmpty {
            persistSecretWithFallback(
                fallback,
                account: "client-id",
                fallbackKey: fallbackKey
            )
            return fallback
        }
        if let existing = readSecret(account: "client-id"), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        persistSecretWithFallback(
            generated,
            account: "client-id",
            fallbackKey: fallbackKey
        )
        return generated
    }

    @discardableResult
    private static func persistSecretWithFallback(
        _ value: String,
        account: String,
        fallbackKey: String
    ) -> Bool {
        let defaults = UserDefaults.standard
        return SecretFallbackStore.persist(
            value: value,
            persistSecurely: { storeSecret($0, account: account) },
            storeFallback: { defaults.set($0, forKey: fallbackKey) },
            removeFallback: { defaults.removeObject(forKey: fallbackKey) }
        )
    }

    private static func readSecret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.jiac78390-alt.CodexRemote",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func storeSecret(_ value: String, account: String) -> Bool {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.jiac78390-alt.CodexRemote",
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var item = key
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            return SecItemUpdate(key as CFDictionary, attributes as CFDictionary) == errSecSuccess
        }
        return addStatus == errSecSuccess
    }

    private var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CodexRemote", isDirectory: true)
            .appendingPathComponent("workspace-cache.json")
    }

    private var outboxURL: URL {
        cacheURL.deletingLastPathComponent().appendingPathComponent("reliable-outbox-v1.json")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
