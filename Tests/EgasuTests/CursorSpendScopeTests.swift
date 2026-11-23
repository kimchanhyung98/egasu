import XCTest
@testable import Egasu

final class CursorSpendScopeTests: XCTestCase {
    func testCompletePersonalZeroTakesPrecedenceOverTeamUsage() throws {
        let mapped = try map([
            "individualLimit": 1000, "individualUsed": 0, "individualRemaining": 1000,
            "pooledLimit": 10000, "pooledUsed": 6000, "pooledRemaining": 4000
        ])
        guard
            case .progress(_, let used, let limit, .dollars, _, _, _) = mapped.lines.first(where: {
                $0.label == "On-demand"
            })
        else {
            return XCTFail("Expected personal Extra Usage meter")
        }
        XCTAssertEqual(used, 0)
        XCTAssertEqual(limit, 10)
    }

    func testTeamUsageUsesOnlyTeamLimit() throws {
        let mapped = try map(["individualLimit": 1000, "pooledUsed": 6000, "pooledLimit": 10000])
        guard
            case .progress(_, let used, let limit, .dollars, _, _, _) = mapped.lines.first(where: {
                $0.label == "On-demand"
            })
        else {
            return XCTFail("Expected team Extra Usage meter")
        }
        XCTAssertEqual(used, 60)
        XCTAssertEqual(limit, 100)
        XCTAssertEqual(mapped.recoveryScopes["On-demand"], .team)
    }

    func testUsageWithoutLimitFromSameScopeIsUnbounded() throws {
        for usage in [["individualLimit": 1000, "pooledUsed": 6000], ["individualLimit": 1000, "totalSpend": 6000]] {
            let mapped = try map(usage)
            guard case .values(_, let values, _, _, _, _) = mapped.lines.first(where: { $0.label == "On-demand" })
            else {
                return XCTFail("Expected unbounded Extra Usage")
            }
            XCTAssertEqual(values.first?.number, 60)
        }
    }

    private func map(_ usage: [String: Int]) throws -> CursorMappedUsage {
        try CursorUsageMapper.mapUsage(
            usage: ["enabled": true, "planUsage": ["totalPercentUsed": 30], "spendLimitUsage": usage],
            planName: "team", creditGrants: nil, stripeBalanceCents: 0)
    }
}
