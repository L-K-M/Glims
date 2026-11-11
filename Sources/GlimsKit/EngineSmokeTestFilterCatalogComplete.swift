import Foundation

private struct FilterCatalogCompleteEntry: Equatable {
    let name: String
    let support: EngineSession.FilterOpSupport
}

@MainActor
extension EngineSmokeTest {
    /// This must run immediately after session startup. An earlier native
    /// operation could discover lazy GEGL classes and hide the cold defect.
    static func exerciseFilterCatalogComplete(_ session: EngineSession) throws {
        // Keep the first public request before any warm-up or catalog probe.
        let first = try session.filterOperations()
        let second = try session.filterOperations()
        let third = try session.filterOperations()
        func entries(_ rows: [EngineSession.FilterOperation]) -> [FilterCatalogCompleteEntry] {
            rows.map { .init(name: $0.name, support: $0.support) }
        }
        let firstNames = first.map(\.name), secondNames = second.map(\.name)
        let firstEntries = entries(first), secondEntries = entries(second), thirdEntries = entries(third)
        print("     cold filter catalog counts: first=\(first.count), second=\(second.count), third=\(third.count)")
        check(!first.isEmpty, "Filter catalog complete: the first cold public response is nonempty")
        check(Set(firstNames).count == firstNames.count,
              "Filter catalog complete: the first cold public response has unique operation names")
        check(!second.isEmpty && Set(secondNames).count == secondNames.count && secondEntries == thirdEntries,
              "Filter catalog complete: independent later requests stabilize to the same unique ordered names and support")
        check(firstEntries == secondEntries && firstEntries == thirdEntries,
              "Filter catalog complete: the first response contains every later operation in exact order with identical support")
        print("     filter-catalog-complete checks: 4")
    }
}
