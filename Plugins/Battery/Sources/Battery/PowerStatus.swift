import IOKit.ps

/// The internal battery as one IOKit power source description reports it.
struct PowerStatus: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case charging
        case discharging
        case charged
        /// On external power without charging, e.g. while macOS holds the charge at 80%.
        case notCharging
    }

    /// A time macOS reports in minutes, or that it is still estimating.
    enum Estimate: Equatable, Sendable {
        case calculating
        case minutes(Int)
    }

    var percentage: Int
    var isExternalPowerConnected: Bool
    var isCharging: Bool
    var isFinishingCharge: Bool
    var isFullyCharged: Bool
    /// nil when macOS reports no time (0) or none at all.
    var timeToEmpty: Estimate?
    var timeToFull: Estimate?

    /// Reads a description from `IOPSGetPowerSourceDescription`; nil for anything but a present
    /// internal battery with a known capacity.
    init?(description: [String: Any]) {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              description[kIOPSIsPresentKey] as? Bool == true,
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
        else { return nil }
        // Integer division like pmset (`_charge*100/_FCCap`): 3030/4000 is 75%, not 76%.
        percentage = current * 100 / max
        isExternalPowerConnected = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
        isFinishingCharge = description[kIOPSIsFinishingChargeKey] as? Bool ?? false
        // IOKit leaves "Is Charged" out until the battery is full.
        isFullyCharged = description[kIOPSIsChargedKey] as? Bool ?? false
        timeToEmpty = Self.estimate(description[kIOPSTimeToEmptyKey])
        timeToFull = Self.estimate(description[kIOPSTimeToFullChargeKey])
    }

    /// IOKit reports -1 while it is still estimating and 0 for a time that does not apply.
    private static func estimate(_ value: Any?) -> Estimate? {
        switch value as? Int {
        case -1: .calculating
        case let minutes? where minutes > 0: .minutes(minutes)
        default: nil
        }
    }

    init(
        percentage: Int,
        isExternalPowerConnected: Bool,
        isCharging: Bool,
        isFinishingCharge: Bool = false,
        isFullyCharged: Bool,
        timeToEmpty: Estimate?,
        timeToFull: Estimate?
    ) {
        self.percentage = percentage
        self.isExternalPowerConnected = isExternalPowerConnected
        self.isCharging = isCharging
        self.isFinishingCharge = isFinishingCharge
        self.isFullyCharged = isFullyCharged
        self.timeToEmpty = timeToEmpty
        self.timeToFull = timeToFull
    }

    /// Checked in the same order as `pmset -g batt`, so both always name the same state.
    var state: State {
        if isFinishingCharge { return .charging }
        if isFullyCharged { return .charged }
        if isCharging { return .charging }
        return isExternalPowerConnected ? .notCharging : .discharging
    }

    /// The time that matters in the current state: to full while charging, to empty on battery.
    var remaining: Estimate? {
        switch state {
        case .charging: timeToFull
        case .discharging: timeToEmpty
        case .charged, .notCharging: nil
        }
    }
}

// MARK: - Text

extension PowerStatus {
    var percentageText: String { "\(percentage)%" }

    /// SF Symbol: a battery with a bolt while charging, otherwise one showing the level.
    var glyph: String {
        if state == .charging { return "battery.100percent.bolt" }
        switch percentage {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var stateTitle: String {
        switch state {
        case .charging: "충전 중"
        case .discharging: "배터리 사용 중"
        case .charged: "완전히 충전됨"
        case .notCharging: "전원 연결됨"
        }
    }

    /// "5시간 22분 남음", "완충까지 1시간 10분", "계산 중", or nil when no time applies.
    var remainingText: String? {
        guard let remaining else { return nil }
        guard case .minutes(let minutes) = remaining else { return "계산 중" }
        let duration = Self.durationText(minutes: minutes)
        return state == .charging ? "완충까지 \(duration)" : "\(duration) 남음"
    }

    /// "5시간 22분", "2시간", "45분".
    static func durationText(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest)분" }
        return rest == 0 ? "\(hours)시간" : "\(hours)시간 \(rest)분"
    }
}
