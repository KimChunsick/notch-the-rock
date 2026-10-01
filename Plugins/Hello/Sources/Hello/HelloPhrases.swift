import Foundation

/// One greeting: the phrase the pen writes, the hand that writes it and when.
struct HelloGreeting {
    /// The widest a greeting may be, about two and a half times the handwritten "hello", so a
    /// greeting never widens the notch past it: a phrase longer than that wraps at word boundaries.
    static let maxWidth: CGFloat = 360
    /// Room the takeover leaves around the writing.
    static let padding: CGFloat = 8

    /// The hand that writes a phrase.
    enum Writing {
        /// "hello", in its one cursive stroke.
        case hello
        /// Any Korean phrase, in the Hangul hand.
        case hangul(HangulHandwriting)
    }

    let phrase: String
    let writing: Writing
    /// When the pen writes, holds and fades; the takeover lasts its `total`.
    let timeline: HelloTimeline

    init(phrase: String) {
        self.phrase = phrase
        if phrase == HelloPhrases.hello {
            writing = .hello
            timeline = .hello
        } else {
            let handwriting = HangulHandwriting(phrase)
            writing = .hangul(handwriting)
            timeline = HelloTimeline(writing: handwriting.duration, syllables: handwriting.syllableCount)
        }
    }

    /// A greeting for `date`: one phrase picked at random from the ones that suit the hour and the
    /// day, "hello" and "안녕하세요" among them.
    static func random(for date: Date, calendar: Calendar, using generator: inout some RandomNumberGenerator) -> HelloGreeting {
        HelloGreeting(phrase: HelloPhrases.phrase(for: date, calendar: calendar, using: &generator))
    }
}

/// Which greeting to write, chosen by the time of day and the day of the week. Handwritten
/// greetings carry no punctuation, so the phrases have none.
enum HelloPhrases {
    /// The one phrase written in the cursive "hello" stroke; every other phrase is Korean.
    static let hello = "hello"

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

    /// The greetings every slot offers alongside its own phrases, whatever the hour.
    static let everyday = [hello, "안녕하세요"]

    /// Every phrase that suits `date`: the slot's own phrases plus `everyday`. Saturday and Sunday
    /// are the weekend; Monday mornings and Friday evenings get a phrase of their own.
    static func phrases(for date: Date, calendar: Calendar) -> [String] {
        // Foundation numbers weekdays from Sunday (1) to Saturday (7).
        let weekday = calendar.component(.weekday, from: date)
        let weekend = weekday == 1 || weekday == 7
        let own: [String]
        switch slot(for: date, calendar: calendar) {
        case .dawn:
            own = weekend
                ? ["고요한 주말 새벽이에요", "고요한 새벽이에요"]
                : ["고요한 새벽이에요", "새벽까지 수고 많아요"]
        case .morning:
            own = weekend
                ? ["좋은 아침이에요", "여유로운 주말 아침이에요"]
                : ["좋은 아침이에요"] + (weekday == 2 ? ["힘찬 한 주 보내세요"] : [])
        case .afternoon:
            own = weekend ? ["편안한 주말 오후 되세요"] : ["오후도 힘내세요"]
        case .evening:
            own = weekend
                ? ["즐거운 주말 저녁 보내세요", "편안한 저녁 보내세요"]
                : ["오늘 하루 수고했어요", "편안한 저녁 보내세요"] + (weekday == 6 ? ["한 주 동안 수고했어요"] : [])
        case .night:
            own = weekend
                ? ["좋은 밤이에요", "느긋한 주말 밤이에요"]
                : ["좋은 밤이에요", "오늘 밤도 푹 쉬세요"]
        }
        return own + everyday
    }

    /// One phrase for `date`, picked at random from `phrases(for:calendar:)`.
    static func phrase(for date: Date, calendar: Calendar, using generator: inout some RandomNumberGenerator) -> String {
        let pool = phrases(for: date, calendar: calendar)
        return pool[Int.random(in: pool.indices, using: &generator)]
    }
}
