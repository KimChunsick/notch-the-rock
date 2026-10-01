import SwiftUI

/// The word "안녕하세요" as one continuous handwritten stroke in the hand of `HelloLettering`: cubic
/// Bézier curves drawn for this plugin (no font outline or traced artwork), the syllables joined the
/// way connected Korean handwriting joins them and leaning forward slightly. Trimming the path from
/// 0 to 1 writes the word the way a pen would, syllable by syllable from left to right.
enum HangulLettering {
    /// The design canvas, as tall as the "hello" canvas so both words share a height and a pen. The
    /// longer word gets a wider canvas: 287 pt at the display height, within the greeting's maximum
    /// width.
    static let canvas = CGRect(x: 0, y: 0, width: 326, height: HelloLettering.canvas.height)
    static let strokeWidth = HelloLettering.strokeWidth
    static let displayHeight = HelloLettering.displayHeight

    /// Stems reach from y 10 to the baseline near y 80, like the loops and baseline of "hello"; ㅇ
    /// is about 26 units across.
    static let stroke: Path = {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        var path = Path()
        path.move(to: p(30, 17))
        // 안: ㅇ counterclockwise from its top, then up from its right side into ㅏ.
        path.addCurve(to: p(12, 31), control1: p(22.5, 16.5), control2: p(14, 23.5))
        path.addCurve(to: p(22, 45), control1: p(10, 37.5), control2: p(15.5, 45))
        path.addCurve(to: p(36, 31), control1: p(28.5, 45), control2: p(32, 37))
        path.addCurve(to: p(39.5, 20), control1: p(38.5, 27.5), control2: p(37.5, 24))
        // ㅏ: over the top into the stem, out and back for the tick, down to the foot.
        path.addCurve(to: p(46, 10), control1: p(41, 16), control2: p(43.5, 13.5))
        path.addCurve(to: p(45, 25), control1: p(45.5, 15.5), control2: p(44.5, 20))
        path.addCurve(to: p(48, 29), control1: p(45.5, 27), control2: p(46.5, 28.5))
        path.addCurve(to: p(58, 29), control1: p(51.5, 30), control2: p(54.5, 29))
        path.addCurve(to: p(48, 31), control1: p(54.5, 29.5), control2: p(51, 29))
        path.addCurve(to: p(44, 38), control1: p(45.5, 32.5), control2: p(45, 35.5))
        path.addCurve(to: p(41.5, 47), control1: p(42.5, 41), control2: p(42.5, 44))
        // ㄴ batchim: its stem slants down from the foot of ㅏ, then the base runs right.
        path.addCurve(to: p(33.5, 61), control1: p(39, 52), control2: p(37, 56))
        path.addCurve(to: p(23, 74), control1: p(30, 66), control2: p(25, 68.5))
        path.addCurve(to: p(27, 79), control1: p(22, 76.5), control2: p(25, 78.5))
        path.addCurve(to: p(42, 79), control1: p(32, 80.5), control2: p(36.5, 79.5))
        path.addCurve(to: p(58.5, 77), control1: p(48, 78.5), control2: p(53, 79.5))
        // 녕: the join meets ㄴ at its corner, runs up the stem and back down, then the base.
        path.addCurve(to: p(72, 64), control1: p(64.5, 74), control2: p(68, 69.5))
        path.addCurve(to: p(79.5, 48), control1: p(76, 59), control2: p(78, 54))
        path.addCurve(to: p(85, 14), control1: p(82.5, 36), control2: p(83, 26))
        path.addCurve(to: p(81.5, 40), control1: p(84, 23.5), control2: p(81.5, 30.5))
        path.addCurve(to: p(85, 45), control1: p(81.5, 42.5), control2: p(83, 44.5))
        path.addCurve(to: p(97, 45), control1: p(89, 46.5), control2: p(93, 47))
        // ㅕ: the lower tick, back up to the upper tick, up and down the stem.
        path.addCurve(to: p(107.5, 33), control1: p(102, 42.5), control2: p(103.5, 37.5))
        path.addCurve(to: p(121.5, 32), control1: p(112.5, 32.5), control2: p(116.5, 32.5))
        path.addCurve(to: p(109.5, 20), control1: p(117.5, 27.5), control2: p(114, 24.5))
        path.addCurve(to: p(123.5, 20), control1: p(114.5, 20), control2: p(118.5, 20))
        path.addCurve(to: p(126, 10), control1: p(124.5, 16.5), control2: p(125, 13.5))
        path.addCurve(to: p(123, 30), control1: p(125, 17), control2: p(124, 23))
        path.addCurve(to: p(120, 52), control1: p(122, 38), control2: p(121, 44))
        // ㅇ batchim, counterclockwise from its top.
        path.addCurve(to: p(109, 57), control1: p(116, 54), control2: p(113.5, 56))
        path.addCurve(to: p(99, 57), control1: p(105.5, 58), control2: p(102.5, 55.5))
        path.addCurve(to: p(86.5, 68), control1: p(94, 59.5), control2: p(87, 62.5))
        path.addCurve(to: p(97, 79), control1: p(86, 74), control2: p(91.5, 79))
        path.addCurve(to: p(111.5, 69), control1: p(103, 79), control2: p(106.5, 73))
        // 하: the join rises into the bar of ㅎ, a short stroke up and back for its top, then its ㅇ.
        path.addCurve(to: p(124.5, 56), control1: p(116.5, 65), control2: p(120.5, 61))
        path.addCurve(to: p(137.5, 35), control1: p(130, 49), control2: p(132, 42))
        path.addCurve(to: p(146.5, 25), control1: p(140, 31), control2: p(142.5, 27.5))
        path.addCurve(to: p(157, 24), control1: p(150, 23), control2: p(153, 24.5))
        path.addCurve(to: p(161, 9), control1: p(158.5, 18.5), control2: p(159.5, 14.5))
        path.addCurve(to: p(160, 24), control1: p(160.5, 14.5), control2: p(160, 18.5))
        path.addCurve(to: p(166, 24), control1: p(162, 24), control2: p(163.5, 24))
        path.addCurve(to: p(156.5, 32), control1: p(162.5, 27), control2: p(160, 29))
        path.addCurve(to: p(145, 43), control1: p(152.5, 36), control2: p(146, 37.5))
        path.addCurve(to: p(154, 53), control1: p(144.5, 48), control2: p(148.5, 53))
        path.addCurve(to: p(165, 43), control1: p(159, 53), control2: p(162.5, 47.5))
        path.addCurve(to: p(170.5, 27), control1: p(168.5, 38), control2: p(168, 32.5))
        // ㅏ, with a hook at the foot that turns into the join.
        path.addCurve(to: p(179, 10), control1: p(173, 20.5), control2: p(176, 16))
        path.addCurve(to: p(177.5, 30), control1: p(178.5, 17), control2: p(178, 23))
        path.addCurve(to: p(177, 41), control1: p(177.5, 34), control2: p(175, 38))
        path.addCurve(to: p(187, 44), control1: p(179, 44), control2: p(183.5, 43))
        path.addCurve(to: p(176, 48), control1: p(183, 45.5), control2: p(178.5, 44.5))
        path.addCurve(to: p(174, 62), control1: p(173, 52.5), control2: p(175, 57))
        path.addCurve(to: p(170.5, 76), control1: p(173, 67), control2: p(171, 71))
        path.addCurve(to: p(173, 81), control1: p(170.5, 78), control2: p(171, 80.5))
        path.addCurve(to: p(181, 79), control1: p(175.5, 82), control2: p(178.5, 80.5))
        // 세: ㅅ, its left leg written upward as the join, back down to the middle, the right leg.
        path.addCurve(to: p(201.5, 63), control1: p(189, 74), control2: p(196.5, 70.5))
        path.addCurve(to: p(223, 16), control1: p(212, 47.5), control2: p(215, 33))
        path.addCurve(to: p(213, 38), control1: p(219.5, 24), control2: p(216.5, 30))
        path.addCurve(to: p(220, 46), control1: p(215.5, 41), control2: p(217, 43.5))
        path.addCurve(to: p(227, 50), control1: p(222, 48), control2: p(224, 50))
        // ㅔ: the tick into the short stem, up and down it, round the bottom into the tall stem.
        path.addCurve(to: p(242, 45), control1: p(232.5, 50), control2: p(236.5, 47))
        path.addCurve(to: p(246, 22), control1: p(243.5, 36.5), control2: p(244.5, 30.5))
        path.addCurve(to: p(239.5, 63), control1: p(243.5, 37), control2: p(241, 48))
        path.addCurve(to: p(241.5, 69), control1: p(239, 65.5), control2: p(239.5, 68))
        path.addCurve(to: p(247, 67), control1: p(243, 70), control2: p(245.5, 69))
        path.addCurve(to: p(253, 50), control1: p(250.5, 61.5), control2: p(252, 56.5))
        path.addCurve(to: p(260, 10), control1: p(256.5, 35.5), control2: p(257.5, 24.5))
        path.addCurve(to: p(255, 45), control1: p(258, 22.5), control2: p(256.5, 32.5))
        path.addCurve(to: p(250.5, 76), control1: p(253.5, 56), control2: p(251, 65))
        path.addCurve(to: p(253, 81), control1: p(250.5, 78), control2: p(251, 81))
        path.addCurve(to: p(260.5, 76), control1: p(256, 81), control2: p(258.5, 78.5))
        // 요: ㅇ counterclockwise from its foot.
        path.addCurve(to: p(274, 53), control1: p(266.5, 68.5), control2: p(268, 60.5))
        path.addCurve(to: p(285, 43), control1: p(277, 48.5), control2: p(280, 43.5))
        path.addCurve(to: p(300, 30), control1: p(292, 42.5), control2: p(298.5, 36.5))
        path.addCurve(to: p(291, 17), control1: p(301.5, 24), control2: p(297, 17))
        path.addCurve(to: p(277, 30), control1: p(284.5, 17), control2: p(278, 23.5))
        path.addCurve(to: p(286, 43), control1: p(276, 36), control2: p(282, 39))
        // ㅛ: the first upright drops from ㅇ, a spur left, the base, the second upright, the exit.
        path.addCurve(to: p(284.5, 56), control1: p(289.5, 46), control2: p(285, 51.5))
        path.addCurve(to: p(281, 74), control1: p(283, 62.5), control2: p(282, 67.5))
        path.addCurve(to: p(272, 74), control1: p(277.5, 74), control2: p(275, 74))
        path.addCurve(to: p(287, 74), control1: p(277, 74), control2: p(281.5, 74))
        path.addCurve(to: p(295, 74), control1: p(289.5, 74), control2: p(292, 74))
        path.addCurve(to: p(298, 57), control1: p(296, 68), control2: p(297, 63))
        path.addCurve(to: p(297, 74), control1: p(297.5, 63), control2: p(297.5, 68))
        path.addCurve(to: p(308, 74), control1: p(301, 74), control2: p(304, 75.5))
        path.addCurve(to: p(318, 67), control1: p(312, 72.5), control2: p(314, 69.5))
        return path
    }()
}
