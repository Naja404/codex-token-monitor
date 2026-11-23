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
        case availableCount = "available_count", credits
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let count = try c.decode(Int.self, forKey: .availableCount)
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

    func countdown(now: Date) -> (value: Int, unit: String)? {
        guard let expiresAt, expiresAt > now else { return nil }
        let remaining = expiresAt.timeIntervalSince(now)
        if remaining >= 86400 { return (Int(ceil(remaining / 86400)), L10n.text("天")) }
        if remaining >= 3600 { return (Int(ceil(remaining / 3600)), L10n.text("小时")) }
        return (max(1, Int(ceil(remaining / 60))), L10n.text("分钟"))
    }
}

struct CodexResetCreditsSummaryView: View {
    @ObservedObject var model: UsageModel
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "ticket").accessibilityHidden(true)
            Text(model.resetCredits.map { L10n.format("重置券 · 持有 %d 张", $0.availableCount) }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("重置券明细")).font(.subheadline.weight(.semibold))
                Spacer()
                if let snapshot = model.resetCredits {
                    Text(L10n.format("持有 %d 张", snapshot.availableCount)).font(.caption).monitorSecondary()
                }
            }
            if let snapshot = model.resetCredits {
                if let credits = snapshot.credits, !credits.isEmpty {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        ForEach(Array(credits.enumerated()), id: \.element.id) { index, credit in
                            CodexResetCreditCard(credit: credit, index: index + 1, now: context.date)
                        }
                    }
                    if !model.resetCreditDetailsCurrent {
                        Text(L10n.text("有效期来自上次成功读取，等待更新。"))
                            .font(.caption2).monitorSecondary()
                    }
                } else {
                    Text(L10n.text(snapshot.availableCount == 0 ? "暂无重置券" : "有效期暂不可用"))
                        .font(.caption).monitorSecondary()
                }
            } else {
                Text(L10n.text("尚未读取到重置券信息"))
                    .font(.caption).monitorSecondary()
            }
        }
    }
}

private struct CodexResetCreditCard: View {
    @Environment(\.monitorStyle) private var style
    let credit: CodexResetCredit
    let index: Int
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            creditIcon
            creditDetails
            Spacer(minLength: 4)
            remainingTime
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: style.palette.background).opacity(style.usesGlassMaterial ? 0.4 : 0.75),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: style.palette.secondary).opacity(0.15), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var creditIcon: some View {
        Image(systemName: "ticket")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Color(nsColor: style.palette.accent))
            .frame(width: 30, height: 34)
            .background(Color(nsColor: style.palette.accent).opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }

    private var expiryDescription: String {
        guard let expiry = credit.expiresAt else { return credit.remainingDescription(now: now) }
        return L10n.text("到期 ") + L10n.date(expiry)
    }

    private var creditDetails: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.format("重置券 %d", index)).font(.caption.weight(.semibold))
            Text(expiryDescription).font(.caption2).monitorSecondary().fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var remainingTime: some View {
        if let countdown = credit.countdown(now: now) {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(String(countdown.value)).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(countdown.unit).font(.caption)
                }
                Text(L10n.text("后到期")).font(.caption2).monitorSecondary()
            }.fixedSize()
        } else if let expiry = credit.expiresAt, expiry <= now {
            Text(L10n.text("已到期")).font(.caption).monitorSecondary()
        }
    }

    private var accessibilityDescription: String {
        var parts = [L10n.format("重置券 %d", index), credit.remainingDescription(now: now)]
        if credit.expiresAt != nil { parts.append(expiryDescription) }
        return parts.joined(separator: "，")
    }
}
