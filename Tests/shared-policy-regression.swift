import Foundation

@main
private enum SharedPolicyRegression {
    static func main() {
        precondition(
            InterruptTurnTransitionRetryPolicy.shouldRetry(
                errorMessage: "expected active turn id B but found A",
                requestedTurnID: "B",
                currentActiveTurnID: "B",
                hasPendingStartContext: true,
                retryAttempt: 0
            ),
            "a just-started turn should tolerate the backend handoff window"
        )
        precondition(
            !InterruptTurnTransitionRetryPolicy.shouldRetry(
                errorMessage: "expected active turn id B but found A",
                requestedTurnID: "B",
                currentActiveTurnID: "C",
                hasPendingStartContext: true,
                retryAttempt: 0
            ),
            "a retry must not target a newer active turn"
        )

        let merged = SnapshotItemMergePolicy.merge(
            previous: [
                RemoteTranscriptItem(id: "user-live", kind: "user", text: "same prompt"),
                RemoteTranscriptItem(id: "item-1", kind: "user", text: "same prompt")
            ],
            recent: [
                RemoteTranscriptItem(id: "item-1", kind: "user", text: "same prompt")
            ]
        )
        precondition(merged.count == 1, "a summary alias must not duplicate a live item")
        precondition(merged.first?.id == "user-live", "a live item ID must remain stable")

        print("PASS shared interrupt and snapshot policies")
    }
}
