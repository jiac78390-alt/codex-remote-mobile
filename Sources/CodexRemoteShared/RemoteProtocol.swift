import Foundation

public struct SpeechInputSessionGate: Sendable {
    private var generation: UInt64 = 0

    public init() {}

    public mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    public mutating func invalidate() {
        generation &+= 1
    }

    public func accepts(_ session: UInt64) -> Bool {
        session == generation
    }
}

public enum RemoteMessage {
    public static let hello = "hello"
    public static let tasksRequest = "tasksRequest"
    public static let tasks = "tasks"
    public static let projectsRequest = "projectsRequest"
    public static let projects = "projects"
    public static let taskOpen = "taskOpen"
    public static let taskSnapshot = "taskSnapshot"
    public static let taskCreate = "taskCreate"
    public static let taskRename = "taskRename"
    public static let taskPin = "taskPin"
    public static let taskArchive = "taskArchive"
    public static let taskUnarchive = "taskUnarchive"
    public static let taskDelete = "taskDelete"
    public static let taskAction = "taskAction"
    public static let taskSettings = "taskSettings"
    public static let taskSettingsUpdate = "taskSettingsUpdate"
    public static let prompt = "prompt"
    public static let steer = "steer"
    public static let interrupt = "interrupt"
    public static let refresh = "refresh"
    public static let modelsRequest = "modelsRequest"
    public static let models = "models"
    public static let pluginsRequest = "pluginsRequest"
    public static let plugins = "plugins"
    public static let automationsRequest = "automationsRequest"
    public static let automations = "automations"
    public static let automationSave = "automationSave"
    public static let automationSetEnabled = "automationSetEnabled"
    public static let automationRun = "automationRun"
    public static let automationDelete = "automationDelete"
    public static let resourceRequest = "resourceRequest"
    public static let resourceData = "resourceData"
    public static let taskItem = "taskItem"
    public static let taskDelta = "taskDelta"
    public static let taskState = "taskState"
    public static let taskDiff = "taskDiff"
    public static let taskPlan = "taskPlan"
    public static let approval = "approval"
    public static let approvalDecision = "approvalDecision"
    public static let commandAck = "commandAck"
    public static let error = "error"
}

public enum RemotePermissionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask
    case auto
    case full
    case custom

    public var id: String { rawValue }
}

public struct RemoteResource: Codable, Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var kind: String
    public var mimeType: String
    public var sizeBytes: Int

    public init(name: String, path: String, kind: String, mimeType: String, sizeBytes: Int) {
        self.name = name
        self.path = path
        self.kind = kind
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
    }
}

public struct RemoteResourcePayload: Codable, Hashable, Sendable {
    public var resource: RemoteResource
    public var dataBase64: String

    public init(resource: RemoteResource, dataBase64: String) {
        self.resource = resource
        self.dataBase64 = dataBase64
    }
}

public struct RemoteAttachment: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var mimeType: String
    public var dataBase64: String
    public var sizeBytes: Int

    public init(id: String, name: String, kind: String, mimeType: String, dataBase64: String, sizeBytes: Int) {
        self.id = id
        self.name = name
        self.kind = kind
        self.mimeType = mimeType
        self.dataBase64 = dataBase64
        self.sizeBytes = sizeBytes
    }
}

public struct RemoteSkill: Codable, Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var detail: String
    public var pluginName: String

    public init(name: String, path: String, detail: String, pluginName: String) {
        self.name = name
        self.path = path
        self.detail = detail
        self.pluginName = pluginName
    }
}

public struct FailedDelivery: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var contextID: String
    public var commandType: String
    public var text: String
    public var attachments: [RemoteAttachment]
    public var skills: [RemoteSkill]
    public var createdAt: Double

    public init(
        id: String,
        contextID: String,
        commandType: String,
        text: String,
        attachments: [RemoteAttachment],
        skills: [RemoteSkill],
        createdAt: Double
    ) {
        self.id = id
        self.contextID = contextID
        self.commandType = commandType
        self.text = text
        self.attachments = attachments
        self.skills = skills
        self.createdAt = createdAt
    }
}

public struct FailedDeliveryRecoveryPlan: Equatable, Sendable {
    public var contextID: String
    public var createdThreadID: String?

    public init(contextID: String, createdThreadID: String?) {
        self.contextID = contextID
        self.createdThreadID = createdThreadID
    }

    public static func resolve(
        commandType: String,
        commandThreadID: String?,
        acknowledgedThreadID: String?,
        projectID: String?,
        cwd: String?
    ) -> FailedDeliveryRecoveryPlan? {
        if commandType == RemoteMessage.taskCreate {
            let createdThreadID = acknowledgedThreadID?.isEmpty == false
                ? acknowledgedThreadID
                : (commandThreadID?.isEmpty == false ? commandThreadID : nil)
            if let createdThreadID {
                return FailedDeliveryRecoveryPlan(
                    contextID: "task:\(createdThreadID)",
                    createdThreadID: createdThreadID
                )
            }
            if let projectID, !projectID.isEmpty {
                return FailedDeliveryRecoveryPlan(contextID: "new:project:\(projectID)", createdThreadID: nil)
            }
            if let cwd, !cwd.isEmpty {
                return FailedDeliveryRecoveryPlan(contextID: "new:cwd:\(cwd)", createdThreadID: nil)
            }
            return FailedDeliveryRecoveryPlan(contextID: "new:default", createdThreadID: nil)
        }
        guard let commandThreadID, !commandThreadID.isEmpty else { return nil }
        return FailedDeliveryRecoveryPlan(contextID: "task:\(commandThreadID)", createdThreadID: nil)
    }
}

public struct RemotePlugin: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var displayName: String
    public var detail: String
    public var skills: [RemoteSkill]

    public init(id: String, name: String, displayName: String, detail: String, skills: [RemoteSkill]) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.detail = detail
        self.skills = skills
    }
}

public struct RemoteAutomation: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: String
    public var name: String
    public var prompt: String
    public var status: String
    public var schedule: String
    public var model: String?
    public var reasoningEffort: String?
    public var targetThreadId: String?
    public var cwd: String?
    public var projectId: String?
    public var updatedAt: Double

    public init(
        id: String,
        kind: String,
        name: String,
        prompt: String,
        status: String,
        schedule: String,
        model: String? = nil,
        reasoningEffort: String? = nil,
        targetThreadId: String? = nil,
        cwd: String? = nil,
        projectId: String? = nil,
        updatedAt: Double = 0
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.prompt = prompt
        self.status = status
        self.schedule = schedule
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.targetThreadId = targetThreadId
        self.cwd = cwd
        self.projectId = projectId
        self.updatedAt = updatedAt
    }
}

public struct RemoteProject: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public var isDefault: Bool

    public init(id: String, name: String, path: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.isDefault = isDefault
    }
}

public struct RemoteCommand: Codable, Sendable {
    public var type: String
    public var threadId: String?
    public var turnId: String?
    public var value: String?
    public var cwd: String?
    public var requestId: String?
    public var decision: String?
    public var model: String?
    public var effort: String?
    public var archived: Bool?
    public var projectId: String?
    public var pinned: Bool?
    public var permissionMode: String?
    public var planMode: Bool?
    public var afterInterrupt: Bool?
    public var attachments: [RemoteAttachment]?
    public var skills: [RemoteSkill]?
    public var automation: RemoteAutomation?
    public var messageId: String?
    public var clientId: String?
    public var createdAt: Double?

    public init(
        type: String,
        threadId: String? = nil,
        turnId: String? = nil,
        value: String? = nil,
        cwd: String? = nil,
        requestId: String? = nil,
        decision: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        archived: Bool? = nil,
        projectId: String? = nil,
        pinned: Bool? = nil,
        permissionMode: String? = nil,
        planMode: Bool? = nil,
        afterInterrupt: Bool? = nil,
        attachments: [RemoteAttachment]? = nil,
        skills: [RemoteSkill]? = nil,
        automation: RemoteAutomation? = nil,
        messageId: String? = nil,
        clientId: String? = nil,
        createdAt: Double? = nil
    ) {
        self.type = type
        self.threadId = threadId
        self.turnId = turnId
        self.value = value
        self.cwd = cwd
        self.requestId = requestId
        self.decision = decision
        self.model = model
        self.effort = effort
        self.archived = archived
        self.projectId = projectId
        self.pinned = pinned
        self.permissionMode = permissionMode
        self.planMode = planMode
        self.afterInterrupt = afterInterrupt
        self.attachments = attachments
        self.skills = skills
        self.automation = automation
        self.messageId = messageId
        self.clientId = clientId
        self.createdAt = createdAt
    }
}

public struct RemoteTaskSummary: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var preview: String
    public var cwd: String
    public var updatedAt: Double
    public var status: String
    public var archived: Bool
    public var projectId: String?
    public var projectOrder: Int?
    public var pinned: Bool
    public var pinOrder: Int?

    public init(
        id: String,
        title: String,
        preview: String,
        cwd: String,
        updatedAt: Double,
        status: String,
        archived: Bool = false,
        projectId: String? = nil,
        projectOrder: Int? = nil,
        pinned: Bool = false,
        pinOrder: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.preview = preview
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.status = status
        self.archived = archived
        self.projectId = projectId
        self.projectOrder = projectOrder
        self.pinned = pinned
        self.pinOrder = pinOrder
    }
}

public struct RemoteReasoningEffort: Codable, Identifiable, Hashable, Sendable {
    public var id: String { value }
    public var value: String
    public var detail: String

    public init(value: String, detail: String) {
        self.value = value
        self.detail = detail
    }
}

public struct RemoteModel: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var model: String
    public var displayName: String
    public var detail: String
    public var isDefault: Bool
    public var defaultEffort: String
    public var efforts: [RemoteReasoningEffort]

    public init(id: String, model: String, displayName: String, detail: String, isDefault: Bool, defaultEffort: String, efforts: [RemoteReasoningEffort]) {
        self.id = id
        self.model = model
        self.displayName = displayName
        self.detail = detail
        self.isDefault = isDefault
        self.defaultEffort = defaultEffort
        self.efforts = efforts
    }
}

public struct RemoteTaskSettings: Codable, Hashable, Sendable {
    public var threadId: String
    public var model: String
    public var effort: String?
    public var cwd: String
    public var permissionMode: String?
    public var planMode: Bool?

    public init(
        threadId: String,
        model: String,
        effort: String?,
        cwd: String,
        permissionMode: String? = nil,
        planMode: Bool? = nil
    ) {
        self.threadId = threadId
        self.model = model
        self.effort = effort
        self.cwd = cwd
        self.permissionMode = permissionMode
        self.planMode = planMode
    }
}

public struct RemotePlanStep: Codable, Hashable, Sendable {
    public var step: String
    public var status: String

    public init(step: String, status: String) {
        self.step = step
        self.status = status
    }
}

public struct RemoteFileChange: Codable, Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var kind: String
    public var diff: String

    public init(path: String, kind: String, diff: String = "") {
        self.path = path
        self.kind = kind
        self.diff = diff
    }
}

public struct RemoteTranscriptItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: String
    public var text: String
    public var status: String?
    public var command: String?
    public var output: String?
    public var files: [RemoteFileChange]?
    public var toolName: String?
    public var resources: [RemoteResource]?

    public init(
        id: String,
        kind: String,
        text: String,
        status: String? = nil,
        command: String? = nil,
        output: String? = nil,
        files: [RemoteFileChange]? = nil,
        toolName: String? = nil,
        resources: [RemoteResource]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.status = status
        self.command = command
        self.output = output
        self.files = files
        self.toolName = toolName
        self.resources = resources
    }
}

public struct RemoteApproval: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var threadId: String?
    public var title: String
    public var detail: String
    public var allowsSessionApproval: Bool

    public init(id: String, threadId: String?, title: String, detail: String, allowsSessionApproval: Bool) {
        self.id = id
        self.threadId = threadId
        self.title = title
        self.detail = detail
        self.allowsSessionApproval = allowsSessionApproval
    }
}

public struct RemoteEvent: Codable, Equatable, Sendable {
    public var type: String
    public var name: String?
    public var version: String?
    public var codexReady: Bool?
    public var projects: [RemoteProject]?
    public var tasks: [RemoteTaskSummary]?
    public var models: [RemoteModel]?
    public var plugins: [RemotePlugin]?
    public var automations: [RemoteAutomation]?
    public var resource: RemoteResourcePayload?
    public var task: RemoteTaskSummary?
    public var settings: RemoteTaskSettings?
    public var items: [RemoteTranscriptItem]?
    public var item: RemoteTranscriptItem?
    public var approval: RemoteApproval?
    public var requestId: String?
    public var threadId: String?
    public var turnId: String?
    public var itemId: String?
    public var delta: String?
    public var busy: Bool?
    public var runtimeAuthoritative: Bool?
    public var code: String?
    public var message: String?
    public var value: String?
    public var archived: Bool?
    public var diff: String?
    public var plan: [RemotePlanStep]?
    public var planExplanation: String?
    public var messageId: String?
    public var accepted: Bool?
    public var retryable: Bool?
    public var serverTime: Double?

    public init(
        type: String,
        name: String? = nil,
        version: String? = nil,
        codexReady: Bool? = nil,
        projects: [RemoteProject]? = nil,
        tasks: [RemoteTaskSummary]? = nil,
        models: [RemoteModel]? = nil,
        plugins: [RemotePlugin]? = nil,
        automations: [RemoteAutomation]? = nil,
        resource: RemoteResourcePayload? = nil,
        task: RemoteTaskSummary? = nil,
        settings: RemoteTaskSettings? = nil,
        items: [RemoteTranscriptItem]? = nil,
        item: RemoteTranscriptItem? = nil,
        approval: RemoteApproval? = nil,
        requestId: String? = nil,
        threadId: String? = nil,
        turnId: String? = nil,
        itemId: String? = nil,
        delta: String? = nil,
        busy: Bool? = nil,
        runtimeAuthoritative: Bool? = nil,
        code: String? = nil,
        message: String? = nil,
        value: String? = nil,
        archived: Bool? = nil,
        diff: String? = nil,
        plan: [RemotePlanStep]? = nil,
        planExplanation: String? = nil,
        messageId: String? = nil,
        accepted: Bool? = nil,
        retryable: Bool? = nil,
        serverTime: Double? = nil
    ) {
        self.type = type
        self.name = name
        self.version = version
        self.codexReady = codexReady
        self.projects = projects
        self.tasks = tasks
        self.models = models
        self.plugins = plugins
        self.automations = automations
        self.resource = resource
        self.task = task
        self.settings = settings
        self.items = items
        self.item = item
        self.approval = approval
        self.requestId = requestId
        self.threadId = threadId
        self.turnId = turnId
        self.itemId = itemId
        self.delta = delta
        self.busy = busy
        self.runtimeAuthoritative = runtimeAuthoritative
        self.code = code
        self.message = message
        self.value = value
        self.archived = archived
        self.diff = diff
        self.plan = plan
        self.planExplanation = planExplanation
        self.messageId = messageId
        self.accepted = accepted
        self.retryable = retryable
        self.serverTime = serverTime
    }
}

public enum RemoteJSON {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static let decoder = JSONDecoder()
}
