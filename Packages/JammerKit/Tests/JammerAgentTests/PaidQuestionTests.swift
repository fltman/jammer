import Foundation
import Testing
@testable import JammerAgent
import JammerCore

/// SIBLINGS, "Betalt kräver alltid en fråga" (2026-11-19): nothing paid runs without the user's question answered
/// in the window or an agent's own allowPaid (and allowUnknownPrice where Jämmer can't read the price). Found
/// missing in 0.1.0 for a batch job transcribing at OpenAI.
@Suite("Paid always asks")
struct PaidQuestionTests {
    func body(_ jobs: [[String: Any]], _ extra: [String: Any] = [:]) -> [String: Any] {
        var b: [String: Any] = ["files": ["/tmp/jammer-paid-a.wav"], "output": "/tmp/jammer-paid-out", "jobs": jobs]
        for (k, v) in extra { b[k] = v }
        return b
    }
    let openai: [String: Any] = ["op": "transcribe", "params": ["engine": "openai", "language": "sv-SE"]]

    @Test("A batch with a paid job fails without allowPaid, then without allowUnknownPrice; with both it runs, and only its paid jobs carry the leave")
    func batch() throws {
        #expect(throws: BatchError.self) { try BatchRequest.parse(body([openai]), policy: nil) }
        do { _ = try BatchRequest.parse(body([openai]), policy: nil) } catch let e as BatchError { #expect(e.reason == "paid_not_allowed") }
        do { _ = try BatchRequest.parse(body([openai], ["allowPaid": true]), policy: nil) } catch let e as BatchError { #expect(e.reason == "unknown_price") }
        let ok = try BatchRequest.parse(body([openai, ["op": "transcribe", "params": ["engine": "apple"]]], ["allowPaid": true, "allowUnknownPrice": true]), policy: nil)
        #expect(ok.jobs.map(\.paidAllowed) == [true, false])
        // Free engines need nothing.
        #expect(try BatchRequest.parse(body([["op": "transcribe", "params": ["engine": "parakeet"]]]), policy: nil).jobs.first?.paidAllowed == false)
    }

    @Test("Berget requires payment consent and a mixed batch also requires consent to OpenAI's unknown price")
    func bergetBatch() throws {
        let berget: [String: Any] = ["op": "transcribe", "params": ["engine": "berget_pianissimo", "language": "sv"]]
        do { _ = try BatchRequest.parse(body([berget]), policy: nil); Issue.record("Paid request accepted") }
        catch let error as BatchError { #expect(error.reason == "paid_not_allowed") }
        let allowed = try BatchRequest.parse(body([berget], ["allowPaid": true]), policy: nil)
        #expect(allowed.jobs.first?.paidAllowed == true)
        do { _ = try BatchRequest.parse(body([berget, openai], ["allowPaid": true]), policy: nil); Issue.record("Unknown price accepted") }
        catch let error as BatchError { #expect(error.reason == "unknown_price") }
    }

    @Test("A paid job made any other way than through the request never carries the leave (the runner refuses it)")
    func noBackDoor() {
        let made = BatchRequest.JobStep(op: "transcribe", params: ["engine": .string("openai")])
        #expect(made.isPaid && !made.paidAllowed)
    }

    @Test("No editing step is paid, and every paid endpoint in the registry takes allowPaid and allowUnknownPrice (its route refuses without them)")
    func everyPaidOperation() {
        #expect(Operations.all.filter(\.paid).isEmpty, "a paid editing step would bypass the endpoints' gates")
        let paid = Operations.endpoints.filter(\.paid)
        #expect(!paid.isEmpty)
        for spec in paid {
            guard let call = spec.call else { Issue.record("\(spec.name) has no route"); continue }
            let route = AgentAPI.routes.first { $0.method == call.method && $0.pattern == AgentAPI.RouteParameters(call.method, call.path).pattern }
            #expect(route?.body?.isSuperset(of: ["allowPaid", "allowUnknownPrice"]) == true, "\(spec.name) \(call.path): \(route?.body ?? [])")
        }
        // The transcription endpoint's paid engine has the same two.
        let t = AgentAPI.routes.first { $0.method == "POST" && $0.pattern.last == "transcribe" }
        #expect(t?.body?.isSuperset(of: ["allowPaid", "allowUnknownPrice"]) == true)
    }

    @Test("Every paid transcription engine has a price with its source, date and the provider's words, or is marked unknown and needs allowUnknownPrice")
    func paidPrices() {
        for c in TranscriptionChoice.allCases where c.paid {
            if let p = c.price {
                #expect(p.source.hasPrefix("https://") && p.asOf.count == 10 && !p.quote.isEmpty && p.amount > 0, "\(c.rawValue)")
                #expect(!c.needsUnknownPrice)
            } else {
                #expect(c.needsUnknownPrice, "\(c.rawValue)")
            }
        }
        #expect(TranscriptionChoice.bergetPianissimo.price?.amount == 0.0035)
    }

    @Test("The batch's paid engines are the transcribe engines that send audio away")
    func paidEngines() {
        let engines = Operations.endpoints.first { $0.name == "transcribe" }?.params.first { $0.name == "engine" }?.options ?? []
        #expect(BatchRequest.paidEngines.isSubset(of: Set(engines)), "\(engines)")
        #expect(BatchRequest.paidEngines == ["openai", "berget_pianissimo"])
    }
}
