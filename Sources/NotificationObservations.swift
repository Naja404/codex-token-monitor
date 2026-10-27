import Foundation

extension ProviderReadError {
    var isNotificationCredentialFailure: Bool {
        switch self {
        case .missingCredentials, .credentialsExpired, .credentialAccessDenied, .permissionDenied: true
        case .http(let status): status == 401 || status == 403
        default: false
        }
    }
}

@MainActor extension ProviderStore {
    var localNotificationActiveSources: Set<String> {
        var ids = Set(availableMenuSources.map(\.rawValue))
        if antigravityEnabled {
            ids.formUnion(["antigravity", MenuQuotaSource.antigravityArgon.rawValue])
        }
        return ids
    }

    var localNotificationObservations: [NotificationObservation] {
        var result: [NotificationObservation] = []
        func levels(_ metrics: [QuotaMetric]) -> [NotificationLevel] {
            metrics.map { .init(id: $0.id, title: $0.title, value: $0.remainingPercent) }
        }
        func append(_ source: String, _ title: String, _ stamp: Date?, _ value: NotificationObservation.Result,
                    failure: Bool = false) {
            guard let stamp else { return }
            result.append(.init(source: source, title: title, sample: (failure ? "error:" : "success:") + String(stamp.timeIntervalSince1970), result: value))
        }
        func provider(_ source: MenuQuotaSource, _ refreshing: Bool, _ stamp: Date?,
                      _ error: ProviderReadError?, _ metrics: [QuotaMetric], attempt: Date?) {
            guard !refreshing else { return }
            if let error {
                append(source.rawValue, source.title, attempt,
                       .failure(credentials: error.isNotificationCredentialFailure, terminal: error.stopsAutomaticRefresh), failure: true)
            } else { append(source.rawValue, source.title, stamp, .success(levels(metrics))) }
        }
        if codexEnabled, codex.rateLimitStatus != .loading, codex.rateLimitStatus != .manual {
            let metrics = [("5h", codex.fiveHour), ("weekly", codex.weekly)].compactMap { window, value in
                value.map { QuotaMetric(id: window, window: window, remainingPercent: $0.remainingPercent, resetsAt: $0.resetsAt) }
            }
            provider(.codex, false, codex.lastSuccessAt, codex.readError, metrics, attempt: codex.lastRefreshAt)
        }
        if antigravityEnabled, !isRefreshingAntigravity {
            if let error = antigravityError {
                append("antigravity", "Antigravity", antigravityLastAttemptAt,
                       .failure(credentials: error.isNotificationCredentialFailure, terminal: error.stopsAutomaticRefresh), failure: true)
            } else {
                append("antigravity", "Antigravity", antigravityLastSuccessAt, .success([]))
                for source in MenuQuotaSource.allCases {
                    guard let group = antigravityGroups.first(where: { $0.id == source.antigravityGroupID }) else { continue }
                    append(source.rawValue, source.title, antigravityLastSuccessAt, .success(levels(group.metrics)))
                }
            }
        }
        if claudeEnabled {
            provider(.claude, isRefreshingClaude, claudeLastSuccessAt, claudeError, claudeMetrics, attempt: claudeLastAttemptAt)
        }
        if warpEnabled, !isRefreshingWarp {
            if let error = warpError {
                let credentials = [.missingKey, .keychain, .unauthorized].contains(error)
                append(MenuQuotaSource.warp.rawValue, "Warp", nextWarpRefresh,
                       .failure(credentials: credentials, terminal: error.stopsAutomaticRefresh), failure: true)
            } else {
                append(MenuQuotaSource.warp.rawValue, "Warp", warpLastSuccessAt,
                       .success(warpSnapshot?.metric.map { levels([$0]) } ?? []))
            }
        }
        if teamoEnabled, !isRefreshingTeamo {
            if let error = teamoError {
                let credentials = [.missingConfiguration, .keychain, .unauthorized].contains(error)
                append(MenuQuotaSource.teamo.rawValue, "TeamoRouter", nextTeamoRefresh,
                       .failure(credentials: credentials, terminal: error.stopsAutomaticRefresh), failure: true)
            } else if let value = teamoSnapshot, value.currency.uppercased() == "USD" {
                append(MenuQuotaSource.teamo.rawValue, "TeamoRouter", teamoLastSuccessAt,
                       .success([.init(id: "balance", title: L10n.text("余额"),
                                       value: NSDecimalNumber(decimal: value.balance).doubleValue, unit: .dollars)]))
            }
        }
        return result
    }
}
