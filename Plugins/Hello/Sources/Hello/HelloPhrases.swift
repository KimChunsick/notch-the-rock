import Foundation

/// What one greeting shows: a handwritten word and, under it, a phrase for the time and day.
struct HelloGreeting {
    /// The widest a greeting may be, about two and a half times the handwritten "hello", so a
    /// greeting never widens the notch past it: a phrase longer than that wraps at word boundaries.
    static let maxWidth: CGFloat = 360

    var word: HelloArtwork
    var subtitle: String

    /// A greeting for `date`: "hello" or "안녕하세요" at random, over a phrase picked at random from
    /// the ones that suit the hour and the day.
    static func random(for date: Date, calendar: Calendar, using generator: inout some RandomNumberGenerator) -> HelloGreeting {
        let words = HelloArtwork.words
        return HelloGreeting(
            word: words[Int.random(in: words.indices, using: &generator)],
            subtitle: HelloPhrases.phrase(for: date, calendar: calendar, using: &generator)
        )
    }
}

/// The phrase under the handwritten word, chosen by the time of day and the day of the week.
enum HelloPhrases {
    /// Parts of the day, by the hour on the calendar's clock.
    enum Slot {
        /// 새벽, 0:00 to 5:59.
        case dawn
        /// 아침, 6:00 to 11:59.
        case morning
        /// 오후, 12:00 to 17:59.
        case afternoon
        /// 저녁, 18:00 to 20:59.
        case evening
        /// 밤, 21:00 to 23:59.
        case night
    }

    static func slot(for date: Date, calendar: Calendar) -> Slot {
        switch calendar.component(.hour, from: date) {
        case ..<6: .dawn
        case ..<12: .morning
        case ..<18: .afternoon
        case ..<21: .evening
        default: .night
        }
    }

    /// Every phrase that suits `date`. Saturday and Sunday are the weekend; Monday mornings and
    /// Friday evenings get a phrase of their own.
    static func phrases(for date: Date, calendar: Calendar) -> [String] {
        // Foundation numbers weekdays from Sunday (1) to Saturday (7).
        let weekday = calendar.component(.weekday, from: date)
        let weekend = weekday == 1 || weekday == 7
        switch slot(for: date, calendar: calendar) {
        case .dawn:
            return weekend
                ? ["고요한 주말 새벽이에요.", "고요한 새벽이에요."]
                : ["고요한 새벽이에요.", "새벽까지 수고 많아요."]
        case .morning:
            return weekend
                ? ["좋은 아침이에요.", "여유로운 주말 아침이에요."]
                : ["좋은 아침이에요."] + (weekday == 2 ? ["힘찬 한 주 보내세요."] : [])
        case .afternoon:
            return weekend ? ["편안한 주말 오후 되세요."] : ["오후도 힘내세요."]
        case .evening:
            return weekend
                ? ["즐거운 주말 저녁 보내세요.", "편안한 저녁 보내세요."]
                : ["오늘 하루 수고했어요.", "편안한 저녁 보내세요."] + (weekday == 6 ? ["한 주 동안 수고했어요."] : [])
        case .night:
            return weekend
                ? ["좋은 밤이에요.", "느긋한 주말 밤이에요."]
                : ["좋은 밤이에요.", "오늘 밤도 푹 쉬세요."]
        }
    }

    /// One phrase for `date`, picked at random from `phrases(for:calendar:)`.
    static func phrase(for date: Date, calendar: Calendar, using generator: inout some RandomNumberGenerator) -> String {
        let pool = phrases(for: date, calendar: calendar)
        return pool[Int.random(in: pool.indices, using: &generator)]
    }
}
