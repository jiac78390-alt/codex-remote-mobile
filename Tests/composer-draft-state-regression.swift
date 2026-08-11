import Foundation

@main
private enum ComposerDraftStateRegression {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() throws {
        var state = ComposerDraftState()
        let taskA = ComposerDraftState.taskContextID("task-a")
        let taskB = ComposerDraftState.taskContextID("task-b")
        let newProject = ComposerDraftState.newTaskContextID(projectID: "project-1", cwd: "/tmp/ignored")
        let newWorkspace = ComposerDraftState.newTaskContextID(projectID: nil, cwd: "/tmp/workspace")

        state.setDraft("检查同步问题", for: taskA)
        state.setDraft("整理发布说明", for: taskB)
        state.setDraft("创建新任务", for: newProject)
        state.setDraft("工作区草稿", for: newWorkspace)

        expect(state.draft(for: taskA) == "检查同步问题", "task A draft must remain isolated")
        expect(state.draft(for: taskB) == "整理发布说明", "task B draft must remain isolated")
        expect(state.draft(for: newProject) == "创建新任务", "new project draft must be recoverable")
        expect(state.draft(for: newWorkspace) == "工作区草稿", "new workspace draft must be recoverable")

        state.setDraft("   \n", for: taskA)
        expect(!state.hasDraft(for: taskA), "blank text must remove the saved draft")
        expect(state.hasDraft(for: taskB), "clearing one draft must not remove another")

        let oversized = String(repeating: "x", count: 60_000)
        state.setDraft(oversized, for: taskA)
        expect(state.draft(for: taskA).count == 50_000, "drafts must be capped before persistence")

        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(ComposerDraftState.self, from: data)
        expect(restored == state, "draft state must survive an encode/decode round trip")

        print("PASS composer draft state: \(restored.drafts.count) isolated contexts")
    }
}
