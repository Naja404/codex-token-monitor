import Foundation
import Testing
@testable import CodexTokenMonitor

@Test func keepsAccountWeeklySeparateFromAdditionalModelWindows() throws {
        let data = Data("""
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {
              "used_percent": 12,
              "limit_window_seconds": 604800,
              "reset_at": 1789979708
            },
            "secondary_window": null
          },
          "additional_rate_limits": [{
            "limit_name": "Example model quota",
            "normal_model_slug": "example-model",
            "rate_limit": {
              "primary_window": {
                "used_percent": 27,
                "limit_window_seconds": 18000,
                "reset_at": 1789392967
              },
              "secondary_window": {
                "used_percent": 82,
                "limit_window_seconds": 604800,
                "reset_at": 1789979767
              }
            }
          }]
        }
        """.utf8)

        let payload = try JSONDecoder().decode(CodexWhamUsage.self, from: data)

    #expect(payload.liveRateLimits?.primary == nil)
    #expect(payload.liveRateLimits?.secondary?.usedPercent == 12)
    #expect(payload.liveRateLimits?.planName == "Pro")
    #expect(payload.liveRateLimits?.additional.first?.name == "Example model quota · example-model")
    #expect(payload.liveRateLimits?.additional.first?.fiveHour?.usedPercent == 27)
    #expect(payload.liveRateLimits?.additional.first?.weekly?.usedPercent == 82)
}

@Test(arguments: [
    ("free", "Free"), ("plus", "Plus"), ("pro", "Pro"),
    ("team", "Business（企业工作区）"), ("business", "Business（企业工作区）"),
    ("enterprise", "Enterprise（企业）"), ("edu", "Edu（教育）"),
    ("future_plan", "未知套餐（future_plan）")
])
func identifiesPlanWithoutRequiringQuotaWindows(raw: String, label: String) throws {
    let data = try JSONSerialization.data(withJSONObject: ["plan_type": raw, "rate_limit": NSNull()])
    let payload = try JSONDecoder().decode(CodexWhamUsage.self, from: data)
    #expect(payload.liveRateLimits?.planName == label)
    #expect(payload.liveRateLimits?.primary == nil)
    #expect(payload.liveRateLimits?.secondary == nil)
}

@Test func matchesWindowDurationInsteadOfPosition() throws {
    let data = Data("""
    {"rate_limit": {
      "primary_window": {"used_percent": 20, "limit_window_seconds": 604800, "reset_at": 1800000000},
      "secondary_window": {"used_percent": 40, "limit_window_seconds": 18000, "reset_at": 1799500000}
    }}
    """.utf8)
    let payload = try JSONDecoder().decode(CodexWhamUsage.self, from: data)
    #expect(payload.liveRateLimits?.primary?.usedPercent == 40)
    #expect(payload.liveRateLimits?.secondary?.usedPercent == 20)
    #expect(payload.planName == "套餐未识别")
}

@Test func ignoresUnsupportedOrInvalidWindows() throws {
    let data = Data("""
    {"plan_type": "free", "rate_limit": {
      "primary_window": {"used_percent": 10, "limit_window_seconds": 86400, "reset_at": 1800000000},
      "secondary_window": {"used_percent": 20, "limit_window_seconds": 604800, "reset_at": 0}
    }}
    """.utf8)
    let payload = try JSONDecoder().decode(CodexWhamUsage.self, from: data)
    #expect(payload.liveRateLimits?.primary == nil)
    #expect(payload.liveRateLimits?.secondary == nil)
}

@Test func emptyResponseIsNotLiveUsage() throws {
    let payload = try JSONDecoder().decode(CodexWhamUsage.self, from: Data("{}".utf8))
    #expect(payload.liveRateLimits == nil)
}
