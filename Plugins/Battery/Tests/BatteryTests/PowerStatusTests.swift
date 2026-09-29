import Testing
@testable import Battery

/// A description as `IOPSGetPowerSourceDescription` returns it for the internal battery.
private func battery(
    current: Int,
    max: Int = 100,
    state: String,
    charging: Bool,
    charged: Bool? = nil,
    timeToEmpty: Int = 0,
    timeToFull: Int = 0
) -> [String: Any] {
    var description: [String: Any] = [
        "Type": "InternalBattery",
        "Is Present": true,
        "Current Capacity": current,
        "Max Capacity": max,
        "Power Source State": state,
        "Is Charging": charging,
        "Time to Empty": timeToEmpty,
        "Time to Full Charge": timeToFull,
    ]
    // IOKit leaves "Is Charged" out until the battery is full.
    if let charged { description["Is Charged"] = charged }
    return description
}

@Test func R10__charging_description_maps_to_charging_status() throws {
    let status = try #require(PowerStatus(description: battery(current: 42, state: "AC Power", charging: true, timeToFull: 70)))
    #expect(status.percentage == 42)
    #expect(status.isExternalPowerConnected)
    #expect(status.state == .charging)
    #expect(status.remaining == .minutes(70))
    #expect(status.stateTitle == "충전 중")
    #expect(status.remainingText == "완충까지 1시간 10분")
    #expect(status.glyph == "battery.100percent.bolt")
}

@Test func R10__discharging_description_maps_to_battery_status() throws {
    // While discharging macOS reports 0 as the time to full; only the time to empty applies.
    let status = try #require(PowerStatus(description: battery(current: 60, state: "Battery Power", charging: false, timeToEmpty: 322)))
    #expect(status.percentage == 60)
    #expect(!status.isExternalPowerConnected)
    #expect(status.state == .discharging)
    #expect(status.remaining == .minutes(322))
    #expect(status.stateTitle == "배터리 사용 중")
    #expect(status.remainingText == "5시간 22분 남음")
    #expect(status.glyph == "battery.50percent")
}

@Test func R10__full_description_maps_to_charged_status() throws {
    let status = try #require(PowerStatus(description: battery(current: 100, state: "AC Power", charging: false, charged: true)))
    #expect(status.percentage == 100)
    #expect(status.isFullyCharged)
    #expect(status.state == .charged)
    #expect(status.remaining == nil)
    #expect(status.stateTitle == "완전히 충전됨")
    #expect(status.remainingText == nil)
    #expect(status.glyph == "battery.100percent")
}

@Test func R10__estimating_times_read_as_calculating() throws {
    let discharging = try #require(PowerStatus(description: battery(current: 55, state: "Battery Power", charging: false, timeToEmpty: -1)))
    #expect(discharging.remaining == .calculating)
    #expect(discharging.remainingText == "계산 중")

    let charging = try #require(PowerStatus(description: battery(current: 55, state: "AC Power", charging: true, timeToFull: -1)))
    #expect(charging.remaining == .calculating)
    #expect(charging.remainingText == "계산 중")
}

@Test func R10__external_power_without_charging_is_its_own_state() throws {
    // pmset prints "AC attached; not charging", e.g. while macOS holds the charge at 80%.
    let status = try #require(PowerStatus(description: battery(current: 80, state: "AC Power", charging: false)))
    #expect(status.state == .notCharging)
    #expect(status.stateTitle == "전원 연결됨")
    #expect(status.remainingText == nil)
    #expect(status.glyph == "battery.75percent")
}

@Test func R10__percentage_is_current_over_max_capacity() throws {
    let status = try #require(PowerStatus(description: battery(current: 3000, max: 4000, state: "Battery Power", charging: false)))
    #expect(status.percentage == 75)
}

// pmset prints `current * 100 / max` in integer arithmetic, so a fractional percentage is cut off
// rather than rounded: 3030/4000 is 75% and 3999/4000 is 99%, never 100%.
@Test(arguments: [
    (3030, 4000, 75),
    (3999, 4000, 99),
])
func R10__fractional_percentage_truncates_like_pmset(current: Int, max: Int, percentage: Int) throws {
    let status = try #require(PowerStatus(description: battery(current: current, max: max, state: "Battery Power", charging: false)))
    #expect(status.percentage == percentage)
}

@Test func R10__descriptions_other_than_a_present_internal_battery_are_ignored() {
    var ups = battery(current: 50, state: "AC Power", charging: false)
    ups["Type"] = "UPS"
    #expect(PowerStatus(description: ups) == nil)

    var absent = battery(current: 50, state: "AC Power", charging: false)
    absent["Is Present"] = false
    #expect(PowerStatus(description: absent) == nil)

    var noCapacity = battery(current: 50, state: "AC Power", charging: false)
    noCapacity["Max Capacity"] = 0
    #expect(PowerStatus(description: noCapacity) == nil)
}

@Test(arguments: [
    (322, "5시간 22분"),
    (70, "1시간 10분"),
    (120, "2시간"),
    (45, "45분"),
    (1, "1분"),
])
func R10__korean_duration_text(minutes: Int, text: String) {
    #expect(PowerStatus.durationText(minutes: minutes) == text)
}
