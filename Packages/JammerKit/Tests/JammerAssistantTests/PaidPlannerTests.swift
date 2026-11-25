import Foundation
import Testing
@testable import JammerAssistant

/// SIBLINGS, "Betalt kräver alltid en fråga": the assistant (and the omnibar, which sends through it) asks before
/// every request to a cloud model, because every cloud planner says it is paid; only the Mac's own models are free.
@Suite("The assistant's paid planners")
struct PaidPlannerTests {
    @Test("Every cloud provider's planner is paid, Berget included; the on-device planner is not")
    func cloudIsPaid() {
        #expect(TextProvider.all.contains { $0.id == "berget" })
        for p in TextProvider.all {
            #expect(CloudPlanner(provider: p, model: "m", key: { nil }).paid, "\(p.id)")
        }
        #expect(!OnDevicePlanner().paid)
    }
}
