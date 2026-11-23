import Foundation
import SwiftUI

struct CodexResetCredits: Equatable, Sendable, Decodable {
    let availableCount: Int
    var credits: [CodexResetCredit]?

    init(availableCount: Int, credits: [CodexResetCredit]? = nil) {
        self.availableCount = availableCount
        self.credits = credits
    }

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count", applicableAvailableCount = "applicable_available_count", credits
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let count = try c.decodeIfPresent(Int.self, forKey: .applicableAvailableCount)
            ?? c.decode(Int.self, forKey: .availableCount)
        guard count >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .availableCount, in: c, debugDescription: "Invalid reset count")
        }
        availableCount = count
        credits = try c.decodeIfPresent([CodexResetCredit].self, forKey: .credits)?
            .filter { $0.status == "available" && $0.supported && $0.resetType == "codex_rate_limits" }
            .sorted { ($0.expiresAt ?? .distantFuture, $0.id) < ($1.expiresAt ?? .distantFuture, $1.id) }
    }
}

struct CodexResetCredit: Equatable, Identifiable, Sendable, Decodable {
    let id: String
    let resetType: String
    let status: String
    let supported: Bool
    let expiresAt: Date?
    let expiryKnown: Bool

    enum CodingKeys: String, CodingKey {
        case id, status, resetType = "reset_type", supported = "is_supported_by_plan", expiresAt = "expires_at"
    }

    init(id: String, expiresAt: Date?) {
        self.id = id; self.expiresAt = expiresAt
        expiryKnown = true
        resetType = "codex_rate_limits"; status = "available"; supported = true
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        resetType = try c.decode(String.self, forKey: .resetType)
        status = try c.decode(String.self, forKey: .status)
        supported = try c.decodeIfPresent(Bool.self, forKey: .supported) ?? true
        expiryKnown = c.contains(.expiresAt)
        if let text = try c.decodeIfPresent(String.self, forKey: .expiresAt) {
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractional = format.date(from: text)
            format.formatOptions = [.withInternetDateTime]
            guard let date = fractional ?? format.date(from: text) else {
                throw DecodingError.dataCorruptedError(forKey: .expiresAt, in: c, debugDescription: "Invalid reset expiry")
            }
            expiresAt = date
        } else { expiresAt = nil }
    }

    func remainingDescription(now: Date) -> String {
        guard expiryKnown else { return L10n.text("有效期暂不可用") }
        guard let expiresAt else { return L10n.text("无到期限制") }
        let remaining = expiresAt.timeIntervalSince(now)
        if remaining <= 0 { return L10n.text("已到期，等待刷新") }
        if remaining >= 86400 { return L10n.format("%d 天后到期", Int(ceil(remaining / 86400))) }
        if remaining >= 3600 { return L10n.format("%d 小时后到期", Int(ceil(remaining / 3600))) }
        return L10n.format("%d 分钟后到期", max(1, Int(ceil(remaining / 60))))
    }
}

struct CodexResetCreditsSummaryView: View {
    @ObservedObject var model: UsageModel
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "ticket").accessibilityHidden(true)
            Text(model.resetCredits.map { L10n.format("重置券 · %d 次可用", $0.availableCount) }
                 ?? L10n.text("重置券 · 暂不可用"))
            Spacer(minLength: 0)
            if model.resetCredits != nil, !model.resetCreditsCurrent, model.rateLimitStatus != .loading {
                Text(L10n.text("上次读取"))
            }
        }.font(.caption).monitorSecondary().accessibilityElement(children: .combine)
    }
}

struct CodexResetCreditsDetailView: View {
    @ObservedObject var model: UsageModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("可用重置券")).font(.subheadline.weight(.medium))
            if let snapshot = model.resetCredits {
                if let credits = snapshot.credits, !credits.isEmpty {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        ForEach(Array(credits.enumerated()), id: \.element.id) { index, credit in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L10n.format("重置券 %d", index + 1) + " · " + credit.remainingDescription(now: context.date))
                                if let expiry = credit.expiresAt {
                                    Text(L10n.text("到期 ") + L10n.date(expiry)).monitorSecondary()
                                }
                            }.font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !model.resetCreditDetailsCurrent {
                        Text(L10n.text("有效期来自上次成功读取，等待更新。"))
                            .font(.caption2).monitorSecondary()
                    }
                } else {
                    Text(L10n.text(snapshot.availableCount == 0 ? "暂无可用重置券" : "有效期暂不可用"))
                        .font(.caption).monitorSecondary()
                }
            } else {
                Text(L10n.text("尚未读取到重置券信息"))
                    .font(.caption).monitorSecondary()
            }
        }
    }
}
