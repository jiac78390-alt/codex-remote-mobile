import Foundation

@main
struct SpeechInputRestartRegression {
    static func main() {
        var gate = SpeechInputSessionGate()

        let firstSession = gate.begin()
        precondition(gate.accepts(firstSession), "the first speech session must be current")

        gate.invalidate()
        let secondSession = gate.begin()

        precondition(gate.accepts(secondSession), "the restarted speech session must be current")
        precondition(
            !gate.accepts(firstSession),
            "a delayed callback from the stopped session must not cancel the restarted session"
        )

        print("speech input restart regression passed")
    }
}
