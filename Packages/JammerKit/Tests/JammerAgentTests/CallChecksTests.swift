import Foundation
import Testing
@testable import JammerAgent

/// SIBLINGS 0e3ae19: schema, then requirements, then price, then the work.
@Suite("A call's checks in one order")
struct CallChecksTests {
    struct Fail: Error, Equatable { let stage: String }

    @Test("Whatever order a route lists them in, schema comes first, then requirements, then price")
    func order() {
        var seen: [String] = []
        try? CallChecks.run("transcribe", [
            (.price, { seen.append("price") }), (.schema, { seen.append("schema") }),
            (.requirements, { seen.append("requirements") }), (.schema, { seen.append("schema 2") }),
        ])
        #expect(seen == ["schema", "schema 2", "requirements", "price"])
        // The first stage that fails is the answer: a missing model is said before a price is asked for.
        do {
            try CallChecks.run("transcribe", [(.price, { throw Fail(stage: "price") }), (.requirements, { throw Fail(stage: "requirements") })])
        } catch { #expect(error as? Fail == Fail(stage: "requirements")) }
    }

    @Test("Every operation with a requirement or a price goes through the checks")
    func everyGatedOperation() {
        let required = Set(Requirements.all.flatMap(\.neededBy))
        let paid = Set((Operations.all + Operations.endpoints).filter(\.paid).map(\.name))
        let choosesPaid: Set<String> = ["transcribe", "batch"]
        #expect(CallChecks.gated == required.union(paid).union(choosesPaid), "\(CallChecks.gated.symmetricDifference(required.union(paid).union(choosesPaid)).sorted())")
    }
}
