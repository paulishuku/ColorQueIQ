import Foundation

/// Bitmap silhouettes centered in an 8×8 grid (row-major indices 0…63). Same UTC day → same glyph index for everyone.
enum DailyGlyphLibrary {
    private static var glyphs: [[String]] {
        digitGlyphs + letterGlyphs + iconGlyphs
    }

    private static var digitGlyphs: [[String]] {
        (0...9).map { n in Self.digitPattern(n) }
    }

    /// 3×5 block digits, readable when centered in 8×8.
    private static func digitPattern(_ d: Int) -> [String] {
        switch d {
        case 0: return ["###", "#.#", "#.#", "#.#", "###"]
        case 1: return [".#.", "##.", ".#.", ".#.", "###"]
        case 2: return ["###", "..#", "###", "#..", "###"]
        case 3: return ["###", "..#", "###", "..#", "###"]
        case 4: return ["#.#", "#.#", "###", "..#", "..#"]
        case 5: return ["###", "#..", "###", "..#", "###"]
        case 6: return ["###", "#..", "###", "#.#", "###"]
        case 7: return ["###", "..#", "..#", "..#", "..#"]
        case 8: return ["###", "#.#", "###", "#.#", "###"]
        case 9: return ["###", "#.#", "###", "..#", "###"]
        default: return ["###", "#.#", "###", "#.#", "###"]
        }
    }

    /// 5×7 block letters (classic LCD-style).
    private static let letterGlyphs: [[String]] = [
        ["..#..", ".#.#.", "#...#", "#...#", "#####", "#...#", "#...#"], // A
        ["####.", "#...#", "####.", "#...#", "#...#", "#...#", "####."], // B
        [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."], // C
        ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."], // D
        ["#####", "#....", "#....", "####.", "#....", "#....", "#####"], // E
        ["#####", "#....", "#....", "####.", "#....", "#....", "#...."], // F
        [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".###."], // G
        ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"], // H
        ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "#####"], // I
        ["..###", "...#.", "...#.", "...#.", "#..#.", "#..#.", ".##.."], // J
        ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"], // K
        ["#....", "#....", "#....", "#....", "#....", "#....", "#####"], // L
        ["#...#", "##.##", "#.#.#", "#...#", "#...#", "#...#", "#...#"], // M
        ["#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#", "#...#"], // N
        [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."], // O
        ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."], // P
        [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"], // Q
        ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"], // R
        [".####", "#....", "#....", ".###.", "...#.", "...#.", "####."], // S
        ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."], // T
        ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."], // U
        ["#...#", "#...#", "#...#", "#...#", ".#.#.", ".#.#.", "..#.."], // V
        ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#."], // W
        ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"], // X
        ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."], // Y
        ["#####", "...#.", "..#..", ".#...", "#....", "#....", "#####"], // Z
    ]

    private static let iconGlyphs: [[String]] = [
        ["..#..", ".#.#.", "#...#", "#####", "#...#", ".###.", "..#.."], // heart-ish
        ["..#..", "..#..", "#####", ".###.", "#.#.#", "..#..", ".#.#."], // star-ish
        [".###.", "#...#", ".....", ".....", "..#..", ".#.#.", "..#.."], // smile
        ["..#..", "..#..", "#####", "..#..", "..#..", ".#.#.", "#...#"], // arrow up
        ["#####", "#....", "###..", "#....", "#....", "#....", "#####"], // H shape frame
        ["..##.", ".#..#", "#....#", "######", "#....#", "#....#", "#....#"], // house
        [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"], // hash block
    ]

    static var glyphCount: Int { glyphs.count }

    /// Deterministic glyph for a UTC calendar day.
    static func glyphIndex(utcYMDInt: Int) -> Int {
        let seed = dailySeedUInt64(fromYMDInt: utcYMDInt)
        var gen = SeededGenerator(seed: seed)
        return gen.nextIndex(upperBound: glyphCount)
    }

    static func validSlots(forGlyphIndex index: Int, gridSize: Int = 8) -> Set<Int> {
        let i = ((index % glyphCount) + glyphCount) % glyphCount
        return centerInGrid(pattern: glyphs[i], gridSize: gridSize)
    }

    private static func centerInGrid(pattern: [String], gridSize: Int) -> Set<Int> {
        let rows = pattern.count
        let cols = pattern.map { $0.count }.max() ?? 0
        let offY = max(0, (gridSize - rows) / 2)
        let offX = max(0, (gridSize - cols) / 2)
        var out = Set<Int>()
        for (r, row) in pattern.enumerated() {
            let chars = Array(row)
            for (c, ch) in chars.enumerated() where ch != "." && ch != " " {
                let y = r + offY
                let x = c + offX
                guard x >= 0, x < gridSize, y >= 0, y < gridSize else { continue }
                out.insert(y * gridSize + x)
            }
        }
        return out
    }
}
