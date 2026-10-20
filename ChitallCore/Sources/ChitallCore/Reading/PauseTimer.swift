import Foundation

/// "Напомнить о паузе": a quiet reading timer. It only knows when the current stretch of
/// reading ends; the reader shows the time left on its bottom panel and a card when it is due.
public struct PauseTimer: Sendable, Equatable {
    /// The lengths offered on the panel, in minutes.
    public static let choices = [10, 15, 20, 30]

    /// The length of the current stretch (0 while off).
    public private(set) var minutes = 0
    /// When the current stretch ends; `nil` while off.
    public private(set) var end: Date?

    public init() {}

    public var isOn: Bool { end != nil }

    /// Starts a new stretch of `minutes` from `now`; 0 or less turns the timer off.
    public mutating func start(minutes: Int, at now: Date) {
        guard minutes > 0 else { return stop() }
        self.minutes = minutes
        end = now.addingTimeInterval(Double(minutes) * 60)
    }

    public mutating func stop() {
        minutes = 0
        end = nil
    }

    public func secondsLeft(at now: Date) -> TimeInterval? {
        end.map { max(0, $0.timeIntervalSince(now)) }
    }

    public func isDue(at now: Date) -> Bool {
        secondsLeft(at: now) == 0
    }

    /// Whole minutes left, rounded up: "1 мин" until the very end, never "0 мин".
    public func minutesLeft(at now: Date) -> Int? {
        secondsLeft(at: now).map { Int(($0 / 60).rounded(.up)) }
    }

    /// Next to the timer icon on the panel: "12 мин", "пора" once due, `nil` while off.
    public func shortLabel(at now: Date) -> String? {
        guard let left = minutesLeft(at: now) else { return nil }
        return left == 0 ? "пора" : "\(left) мин"
    }

    /// The full sentence for the menu and VoiceOver.
    public func statusLabel(at now: Date) -> String {
        guard let left = minutesLeft(at: now) else { return "Напоминание о паузе выключено" }
        return left == 0 ? "Пора сделать паузу" : "Пауза через \(left) мин"
    }
}
