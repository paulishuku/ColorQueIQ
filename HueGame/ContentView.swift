import SwiftUI
import UniformTypeIdentifiers
import StoreKit
import UIKit
import Combine

// --- DATA MODELS ---
enum Difficulty: String, Codable {
    case easy
    case medium          // Square: Sorted (Hollow)
    case hard            // Square: Sorted (Union Jack)
    case mediumChaos     // Square: Chaos (Hollow + Scatter)
    case hardChaos       // Square: Chaos (Union Jack + Scatter)
}

enum GameMode: String, Codable {
    case linear   // Classic Row
    case pyramid  // Triangle Chaos
    case square   // 8x8 Grid
    case daily    // UTC glyph of the day
    case ai       // Prompt-generated silhouette (server spec)
}

struct ColorTile: Identifiable, Equatable {
    let id = UUID()
    let color: Color
    let correctIndex: Int
    
    // CHAOS STATE
    var currentSlotIndex: Int? = nil      // If set, snaps to grid
    var loosePosition: CGPoint = .zero    // If nil, floats here
    var rotation: Double = 0
}

struct ConfettiParticle: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var color: Color
    var rotation: Double
    var speed: Double
}

// --- SHAPES ---
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

class GameViewModel: ObservableObject {
    
    var totalRounds: Int { return activeMode == .linear ? 10 : 1 }
    
    @AppStorage("useChaosShapes") var useChaosShapes = false
    @AppStorage("chaosModeType") var chaosModeType: String = "pyramid"
    @AppStorage("lastDailyDate") var lastDailyDate: String = ""
    @AppStorage("currentStreak") var currentStreak: Int = 0
    @AppStorage("lastStreakDate") var lastStreakDate: String = ""
    
    @Published var difficulty: Difficulty = .easy
    @Published var gameStarted = false
    @Published var boardRefreshTrigger = UUID()
    @Published var isPreviewMode = false
    
    @Published var isDailyReview = false
    @Published var validDailySlots: Set<Int> = []
    
    @Published var currentRound = 1
    @Published var totalErrors = 0
    @Published var currentScore = 0
    @Published var maxPossibleScore = 0
    @Published var isGameOver = false
    @Published var roundComplete = false
    @Published var roundMessage = ""
    @Published var newRecordAchieved = false
    @Published var timeInvalidated = false
    
    @Published var timeElapsed: TimeInterval = 0
    @Published var timerRunning = false
    private var timerCancellable: AnyCancellable?
    
    @Published var shufflesRemaining = 2
    
    @Published var activeMode: GameMode = .linear
    @Published var fixedStart: Color = .black
    @Published var fixedEnd: Color = .white
    @Published var lockedTiles: [Int: Color] = [:]
    @Published var movableTiles: [ColorTile] = []
    @Published var errorHistory: [String: Int] = [:]
    private var currentRoundColorName: String = "Unknown"

    private var dailyShuffleNonce: UInt32 = 0
    private var aiShuffleNonce: UInt32 = 0
    private var aiPromptSeed: UInt64 = 0
    private var aiLockRatio: Double = 0.6

    private let dailyStatePersistVersion = 2

    // --- PERSISTENCE ---
    func getStorageKey() -> String {
        if activeMode == .daily {
            return "daily_\(DailyCalendar.utcYMDString())"
        }
        if activeMode == .ai { return "ai_challenge" }
        if activeMode == .pyramid { return "pyramid" }
        if activeMode == .square { return "square_\(difficulty.rawValue)" }
        return difficulty.rawValue
    }
    
    // --- DAILY STATE PERSISTENCE (UTC day) ---
    func saveDailyState() {
        let todayString = DailyCalendar.utcYMDString()
        let key = "dailyState_\(todayString)"

        if lastDailyDate != todayString {
            if let yesterdayString = DailyCalendar.utcYMDStringYesterday() {
                if lastStreakDate == yesterdayString {
                    currentStreak += 1
                } else {
                    currentStreak = 1
                }
            } else {
                currentStreak = 1
            }
            lastStreakDate = todayString
        }

        let positions: [Int] = movableTiles.map { $0.currentSlotIndex.map { Int($0) } ?? -1 }
        let data: [String: Any] = [
            "v": dailyStatePersistVersion,
            "positions": positions,
            "score": currentScore,
            "maxScore": maxPossibleScore,
            "time": timeElapsed,
            "errors": totalErrors
        ]

        UserDefaults.standard.set(data, forKey: key)
        lastDailyDate = todayString
    }

    func loadDailyState() -> Bool {
        let key = "dailyState_\(DailyCalendar.utcYMDString())"

        guard let data = UserDefaults.standard.dictionary(forKey: key),
              let score = data["score"] as? Int,
              let maxScore = data["maxScore"] as? Int,
              let time = data["time"] as? TimeInterval,
              let errors = data["errors"] as? Int
        else { return false }

        generateDailyBoard()

        if let intPositions = data["positions"] as? [Int] {
            for (index, slot) in intPositions.enumerated() where index < movableTiles.count {
                movableTiles[index].currentSlotIndex = slot >= 0 ? slot : nil
                movableTiles[index].rotation = 0
            }
        } else if let raw = data["positions"] as? [Any] {
            applyLoadedPositions(from: raw)
        } else {
            return false
        }

        self.currentScore = score
        self.maxPossibleScore = maxScore
        self.timeElapsed = time
        self.totalErrors = errors
        self.isDailyReview = true
        self.roundComplete = true

        return true
    }

    private func applyLoadedPositions(from raw: [Any]) {
        for (index, any) in raw.enumerated() where index < movableTiles.count {
            let slot: Int?
            if any is NSNull {
                slot = nil
            } else if let i = any as? Int {
                slot = i
            } else if let n = any as? NSNumber {
                slot = n.intValue
            } else {
                slot = nil
            }
            movableTiles[index].currentSlotIndex = slot
            movableTiles[index].rotation = 0
        }
    }
    // --- MAGNET FUNCTION ---
    func activateMagnet() {
        guard activeMode == .square || activeMode == .daily || activeMode == .ai else { return }
        
        let looseTiles = movableTiles.filter { $0.currentSlotIndex == nil }
        guard !looseTiles.isEmpty else { return }
        
        var occupiedSlots = Set(lockedTiles.keys)
        for tile in movableTiles {
            if let slot = tile.currentSlotIndex { occupiedSlots.insert(slot) }
        }
        
        var emptySlots: [Int] = []
        for i in 0..<64 {
            if (activeMode == .daily || activeMode == .ai) && !validDailySlots.contains(i) { continue }
            if !occupiedSlots.contains(i) { emptySlots.append(i) }
        }
        
        emptySlots.shuffle()
        let impact = UIImpactFeedbackGenerator(style: .heavy); impact.impactOccurred()
        
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
            let countToMove = min(looseTiles.count, emptySlots.count)
            for i in 0..<countToMove {
                let tileID = looseTiles[i].id
                let targetSlot = emptySlots[i]
                if let realIndex = movableTiles.firstIndex(where: { $0.id == tileID }) {
                    movableTiles[realIndex].currentSlotIndex = targetSlot
                    movableTiles[realIndex].rotation = 0
                }
            }
        }
    }
    
    func getBestStats(for key: String) -> (time: String, score: String)? {
        let timeKey = "bestTime_\(key)"; let scoreKey = "bestScore_\(key)"
        let savedTime = UserDefaults.standard.double(forKey: timeKey)
        let savedScore = UserDefaults.standard.integer(forKey: scoreKey)
        if savedTime == 0 && savedScore == 0 { return nil }
        return (formatTime(savedTime), "\(savedScore)")
    }
    
    func resetBestTime(for key: String) {
        UserDefaults.standard.removeObject(forKey: "bestTime_\(key)")
        UserDefaults.standard.removeObject(forKey: "bestScore_\(key)")
        objectWillChange.send()
    }
    
    func saveTimeIfBest() {
        if isPreviewMode { return }
        
        if activeMode == .daily {
            saveDailyState()
        }
        
        let maxErrors = activeMode == .square ? 20 : (activeMode == .pyramid ? 5 : ((activeMode == .daily || activeMode == .ai) ? 10 : 34))
        
        if totalErrors > maxErrors {
            timeInvalidated = true; newRecordAchieved = false; return
        }
        timeInvalidated = false
        
        let key = getStorageKey()
        let timeKey = "bestTime_\(key)"; let scoreKey = "bestScore_\(key)"
        let currentBestTime = UserDefaults.standard.double(forKey: timeKey)
        let savedScore = UserDefaults.standard.integer(forKey: scoreKey)
        
        var isNewBest = false
        if currentScore > savedScore { isNewBest = true }
        else if currentScore == savedScore {
            if currentBestTime == 0 || timeElapsed < currentBestTime { isNewBest = true }
        }
        
        if isNewBest {
            UserDefaults.standard.set(timeElapsed, forKey: timeKey)
            UserDefaults.standard.set(currentScore, forKey: scoreKey)
            newRecordAchieved = true
        } else {
            newRecordAchieved = false
        }
    }
    
    // --- GAME LOGIC ---
    func startGame(selectedDifficulty: Difficulty) {
        self.difficulty = selectedDifficulty
        self.activeMode = .linear
        self.gameStarted = true
        self.currentRound = 1
        self.currentScore = 0
        self.maxPossibleScore = 0
        self.totalErrors = 0
        self.errorHistory = [:]
        self.isGameOver = false
        self.shufflesRemaining = 2
        self.newRecordAchieved = false
        self.timeInvalidated = false
        self.timeElapsed = 0
        self.isPreviewMode = false
        self.isDailyReview = false
        
        startTimer()
        startNewRound()
    }
    
    func startDailyChallenge() {
        self.activeMode = .daily
        self.difficulty = .medium
        self.gameStarted = true

        let today = DailyCalendar.utcYMDString()

        if lastDailyDate == today {
            if loadDailyState() { return }
        }

        self.currentRound = 1
        self.currentScore = 0
        self.totalErrors = 0
        self.errorHistory = [:]
        self.isGameOver = false
        self.shufflesRemaining = 2
        self.newRecordAchieved = false
        self.timeInvalidated = false
        self.timeElapsed = 0
        self.isPreviewMode = false
        self.isDailyReview = false
        self.dailyShuffleNonce = 0

        generateDailyBoard()
        self.maxPossibleScore = validDailySlots.count * 2

        startTimer()
    }

    @discardableResult
    func beginAIModeGame(spec: PuzzleSpec, prompt: String) -> Bool {
        let slots = Set(spec.filledCellIndices.filter { $0 >= 0 && $0 < 64 })
        guard slots.count == spec.filledCellIndices.count, slots.count >= 12 else { return false }
        let hb = min(1, max(0, spec.hueBase))
        let ho = min(0.85, max(0.15, spec.hueOffset))
        let lr = min(0.75, max(0.45, spec.lockRatio ?? 0.6))

        activeMode = .ai
        difficulty = .medium
        gameStarted = true
        currentRound = 1
        currentScore = 0
        totalErrors = 0
        errorHistory = [:]
        isGameOver = false
        shufflesRemaining = 2
        newRecordAchieved = false
        timeInvalidated = false
        timeElapsed = 0
        isPreviewMode = false
        isDailyReview = false
        aiShuffleNonce = 0
        aiLockRatio = lr
        aiPromptSeed = Self.fnv1a64(prompt)
        var gen = SeededGenerator(seed: aiPromptSeed)
        applyGradientMaskedPuzzle(slots: slots, gen: &gen, hueBase: hb, hueOffset: ho, lockRatio: lr)
        maxPossibleScore = validDailySlots.count * 2
        startTimer()
        boardRefreshTrigger = UUID()
        return true
    }

    private static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        for b in string.utf8 {
            hash ^= UInt64(b)
            hash = hash &* 1099511628211
        }
        return hash == 0 ? 0xC0FFEEBABEBABE : hash
    }
    
    func startPreview() {
        self.isPreviewMode = true
        self.difficulty = .medium
        self.activeMode = .square
        self.chaosModeType = "square"
        self.currentRound = 1
        self.timeElapsed = 60
        self.shufflesRemaining = 2
        self.roundComplete = false
        self.roundMessage = ""
        self.isDailyReview = false
        
        generateSquareBoard()
        startTimer()
        self.boardRefreshTrigger = UUID()
    }
    
    func startTimer() {
        stopTimer()
        timerRunning = true
        timerCancellable = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { _ in
            if self.timerRunning {
                if self.isPreviewMode {
                    self.timeElapsed -= 1
                    if self.timeElapsed <= 0 { self.stopTimer(); self.isGameOver = true }
                } else {
                    self.timeElapsed += 1
                }
            }
        }
    }
    
    func stopTimer() {
        timerRunning = false
        timerCancellable?.cancel()
        timerCancellable = nil
    }
    
    func useShuffle() {
        guard shufflesRemaining > 0 else { return }
        shufflesRemaining -= 1
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        if activeMode == .daily && !isDailyReview {
            reshuffleDailyGradient()
            return
        }
        if activeMode == .ai && !isDailyReview {
            reshuffleAIGradient()
            return
        }
        startNewRound(isShuffle: true)
    }
    
    func startNewRound(isShuffle: Bool = false) {
        roundComplete = false
        roundMessage = ""
        
        if isPreviewMode {
            generateSquareBoard()
        } else if activeMode == .daily {
            if !isDailyReview && !isShuffle { generateDailyBoard() }
        } else if activeMode == .ai {
            // Silhouette is fixed for this session; shuffle uses reshuffleAIGradient.
        } else if useChaosShapes && difficulty != .easy {
            if chaosModeType == "square" { activeMode = .square; generateSquareBoard() }
            else { activeMode = .pyramid; generatePyramidBoard() }
        } else {
            activeMode = .linear; generateLinearBoard()
        }
        
        if !isShuffle {
            let roundPoints = activeMode == .linear ? 10 : ((activeMode == .daily || activeMode == .ai) ? (validDailySlots.count * 2) : 100)
            maxPossibleScore += roundPoints
        }
        
        self.boardRefreshTrigger = UUID()
    }
    
    // --- GENERATORS ---
    func generateLinearBoard() {
        let movableCount = 8
        let hueStart = Double.random(in: 0...1)
        var hueDiff: Double = 0.0
        self.currentRoundColorName = getColorName(hue: hueStart)
        
        switch difficulty {
        case .easy: hueDiff = Double.random(in: 0.25...0.4)
        case .medium, .mediumChaos: hueDiff = Double.random(in: 0.1...0.2)
        case .hard, .hardChaos: hueDiff = Double.random(in: 0.08...0.12)
        }
        
        let hueEnd = (hueStart + hueDiff).truncatingRemainder(dividingBy: 1.0)
        let sat = Double.random(in: 0.6...0.9); let bri = Double.random(in: 0.7...0.95)
        fixedStart = Color(hue: hueStart, saturation: sat, brightness: bri)
        fixedEnd = Color(hue: hueEnd, saturation: sat, brightness: bri)
        var newTiles: [ColorTile] = []
        let totalSteps = movableCount + 2
        for i in 1...movableCount {
            let ratio = Double(i) / Double(totalSteps - 1)
            let color = interpolateColor(c1: fixedStart, c2: fixedEnd, ratio: ratio)
            newTiles.append(ColorTile(color: color, correctIndex: i - 1, currentSlotIndex: i-1))
        }
        movableTiles = newTiles.shuffled()
    }
    
    func generatePyramidBoard() {
        lockedTiles = [:]
        let totalTiles = 16
        let hueStart = Double.random(in: 0...1)
        let hueDiff = Double.random(in: 0.5...0.6)
        self.currentRoundColorName = getColorName(hue: hueStart)
        let hueEnd = (hueStart + hueDiff).truncatingRemainder(dividingBy: 1.0)
        let sat = Double.random(in: 0.6...0.9); let bri = Double.random(in: 0.7...0.95)
        let startColor = Color(hue: hueStart, saturation: sat, brightness: bri)
        let endColor = Color(hue: hueEnd, saturation: sat, brightness: bri)
        var newMovable: [ColorTile] = []
        let lockedIndices = [0, 9, 15]
        for i in 0..<totalTiles {
            let ratio = Double(i) / Double(totalTiles - 1)
            let color = interpolateColor(c1: startColor, c2: endColor, ratio: ratio)
            if lockedIndices.contains(i) { lockedTiles[i] = color }
            else { newMovable.append(ColorTile(color: color, correctIndex: i, currentSlotIndex: nil, loosePosition: .zero)) }
        }
        movableTiles = newMovable.shuffled()
    }
    
    func generateDailyBoard() {
        dailyShuffleNonce = 0
        let ymd = DailyCalendar.utcYMDInt()
        let gIdx = DailyGlyphLibrary.glyphIndex(utcYMDInt: ymd)
        let slots = DailyGlyphLibrary.validSlots(forGlyphIndex: gIdx)
        var gen = SeededGenerator(seed: dailySeedUInt64(fromYMDInt: ymd))
        let hueBase = gen.nextDouble()
        let hueOffset = 0.3 + gen.nextDouble() * 0.4
        applyGradientMaskedPuzzle(slots: slots, gen: &gen, hueBase: hueBase, hueOffset: hueOffset, lockRatio: 0.6)
    }

    private func reshuffleDailyGradient() {
        dailyShuffleNonce &+= 1
        let base = dailySeedUInt64(fromYMDInt: DailyCalendar.utcYMDInt())
        var gen = SeededGenerator(seed: base &+ UInt64(dailyShuffleNonce))
        let hueBase = gen.nextDouble()
        let hueOffset = 0.3 + gen.nextDouble() * 0.4
        applyGradientMaskedPuzzle(slots: validDailySlots, gen: &gen, hueBase: hueBase, hueOffset: hueOffset, lockRatio: 0.6)
    }

    private func reshuffleAIGradient() {
        aiShuffleNonce &+= 1
        var gen = SeededGenerator(seed: aiPromptSeed &+ UInt64(aiShuffleNonce))
        let hueBase = gen.nextDouble()
        let hueOffset = 0.25 + gen.nextDouble() * 0.5
        applyGradientMaskedPuzzle(slots: validDailySlots, gen: &gen, hueBase: hueBase, hueOffset: hueOffset, lockRatio: aiLockRatio)
    }

    /// Fills `validDailySlots`, `lockedTiles`, and `movableTiles` for masked 8×8 puzzles (daily / AI).
    private func applyGradientMaskedPuzzle(slots: Set<Int>, gen: inout SeededGenerator, hueBase: Double, hueOffset: Double, lockRatio: Double) {
        guard !slots.isEmpty else { return }
        lockedTiles = [:]
        validDailySlots = slots
        let gridSize = 8
        currentRoundColorName = getColorName(hue: hueBase)
        let hueSecondary = (hueBase + hueOffset).truncatingRemainder(dividingBy: 1.0)
        let tl = Color(hue: hueBase, saturation: 0.8, brightness: 0.9)
        let tr = Color(hue: hueSecondary, saturation: 0.7, brightness: 0.9)
        let bl = Color(hue: hueSecondary, saturation: 0.9, brightness: 0.6)
        let br = Color(hue: hueBase, saturation: 0.8, brightness: 0.7)

        var allSlots = Array(validDailySlots).sorted()
        gen.shuffleInPlace(&allSlots)

        let totalCount = allSlots.count
        let rawLock = Int(Double(totalCount) * lockRatio)
        let lockCount = min(max(0, totalCount - 1), max(0, rawLock))
        let lockedIndices = Set(allSlots.prefix(lockCount))

        var newMovable: [ColorTile] = []
        let denom = max(gridSize - 1, 1)
        for y in 0..<gridSize {
            for x in 0..<gridSize {
                let index = y * gridSize + x
                if !validDailySlots.contains(index) { continue }

                let xRatio = Double(x) / Double(denom)
                let yRatio = Double(y) / Double(denom)
                let topColor = interpolateColor(c1: tl, c2: tr, ratio: xRatio)
                let bottomColor = interpolateColor(c1: bl, c2: br, ratio: xRatio)
                let finalColor = interpolateColor(c1: topColor, c2: bottomColor, ratio: yRatio)

                if lockedIndices.contains(index) {
                    lockedTiles[index] = finalColor
                } else {
                    newMovable.append(ColorTile(color: finalColor, correctIndex: index, currentSlotIndex: nil, loosePosition: .zero))
                }
            }
        }
        gen.shuffleInPlace(&newMovable)
        movableTiles = newMovable
        boardRefreshTrigger = UUID()
    }
    func generateSquareBoard() {
        lockedTiles = [:]
        let gridSize = 8
        let hueBase = Double.random(in: 0...1)
        let tl = Color(hue: hueBase, saturation: 0.8, brightness: 0.9)
        let tr = Color(hue: (hueBase + 0.2).truncatingRemainder(dividingBy: 1.0), saturation: 0.6, brightness: 0.9)
        let bl = Color(hue: (hueBase + 0.4).truncatingRemainder(dividingBy: 1.0), saturation: 0.9, brightness: 0.7)
        let br = Color(hue: (hueBase + 0.6).truncatingRemainder(dividingBy: 1.0), saturation: 0.7, brightness: 0.8)
        self.currentRoundColorName = getColorName(hue: hueBase)
        var newMovable: [ColorTile] = []
        
        for y in 0..<gridSize {
            for x in 0..<gridSize {
                let index = y * gridSize + x
                let xRatio = Double(x) / Double(gridSize - 1); let yRatio = Double(y) / Double(gridSize - 1)
                let topColor = interpolateColor(c1: tl, c2: tr, ratio: xRatio)
                let bottomColor = interpolateColor(c1: bl, c2: br, ratio: xRatio)
                let finalColor = interpolateColor(c1: topColor, c2: bottomColor, ratio: yRatio)
                
                var isLocked = false
                let isCorner = (x == 0 || x == 7) && (y == 0 || y == 7)
                if isCorner { isLocked = true }
                
                if !isLocked {
                    let isBorder = (x == 0 || x == 7 || y == 0 || y == 7)
                    let isDiagonal = (x == y) || (x == 7 - y)
                    switch difficulty {
                    case .easy, .medium, .mediumChaos: if !isBorder { isLocked = true }
                    case .hard, .hardChaos: if !isBorder && !isDiagonal { isLocked = true }
                    }
                }
                
                if isLocked { lockedTiles[index] = finalColor }
                else { newMovable.append(ColorTile(color: finalColor, correctIndex: index, currentSlotIndex: nil, loosePosition: .zero)) }
            }
        }
        movableTiles = newMovable.shuffled()
    }
    
    func randomizeLoosePositions(in size: CGSize, safeZoneCenter: CGPoint, safeRadius: CGFloat) {
        guard size.width > 0 else { return }
        let looseTiles = movableTiles.filter { $0.currentSlotIndex == nil }
        guard !looseTiles.isEmpty else { return }
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        
        let isSquareSorted = activeMode == .daily || activeMode == .ai || (activeMode == .square && (difficulty == .medium || difficulty == .hard))
        
        if isSquareSorted {
            let tileSize: CGFloat = isPad ? 72 : 36
            let itemSpacing: CGFloat = isPad ? 80 : 40
            let gridHeight = 8 * tileSize
            let gridBottomY = (size.height * 0.30) + (gridHeight / 2)
            let dockTop = gridBottomY + (isPad ? 60 : 30)
            let dockLeft: CGFloat = isPad ? 100 : 20
            let dockRight = size.width - (isPad ? 100 : 20)
            var currentX = dockLeft
            var currentY = dockTop
            
            for (i, _) in looseTiles.enumerated() {
                guard let realIndex = movableTiles.firstIndex(where: { $0.id == looseTiles[i].id }) else { continue }
                movableTiles[realIndex].loosePosition = CGPoint(x: currentX, y: currentY)
                movableTiles[realIndex].rotation = 0
                currentX += itemSpacing
                if currentX + (itemSpacing / 2) > dockRight {
                    currentX = dockLeft; currentY += itemSpacing
                }
            }
        } else {
            let minX: CGFloat = 50; let maxX: CGFloat = size.width - 50
            let minY: CGFloat = 120; let maxY: CGFloat = size.height - 120
            for (i, _) in looseTiles.enumerated() {
                guard let realIndex = movableTiles.firstIndex(where: { $0.id == looseTiles[i].id }) else { continue }
                let randX = CGFloat.random(in: minX...maxX)
                let randY = CGFloat.random(in: minY...maxY)
                movableTiles[realIndex].loosePosition = CGPoint(x: randX, y: randY)
                movableTiles[realIndex].rotation = activeMode == .pyramid ? Double.random(in: 0...360) : 0
            }
        }
    }
    
    func interpolateColor(c1: Color, c2: Color, ratio: Double) -> Color {
        let u = UIColor(c1); let v = UIColor(c2)
        var h1: CGFloat=0, s1: CGFloat=0, b1: CGFloat=0, a1: CGFloat=0
        var h2: CGFloat=0, s2: CGFloat=0, b2: CGFloat=0, a2: CGFloat=0
        u.getHue(&h1, saturation: &s1, brightness: &b1, alpha: &a1)
        v.getHue(&h2, saturation: &s2, brightness: &b2, alpha: &a2)
        if abs(h2 - h1) > 0.5 { if h1 < h2 { h1 += 1.0 } else { h2 += 1.0 } }
        let h = h1 + (h2 - h1) * CGFloat(ratio)
        let s = s1 + (s2 - s1) * CGFloat(ratio)
        let b = b1 + (b2 - b1) * CGFloat(ratio)
        return Color(hue: h.truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
    }
    
    func swapLinearTiles(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            let item = movableTiles.remove(at: sourceIndex)
            movableTiles.insert(item, at: destinationIndex)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    
    func dropChaosTile(tileId: UUID, targetSlot: Int?, dropLocation: CGPoint) {
        // Prevent moving in review mode
        if isDailyReview { return }
        
        guard let draggingIndex = movableTiles.firstIndex(where: { $0.id == tileId }) else { return }
        var draggingTile = movableTiles[draggingIndex]
        let originalSlot = draggingTile.currentSlotIndex
        let originalLoosePos = draggingTile.loosePosition
        
        if let targetSlot = targetSlot {
            if let occupiedIndex = movableTiles.firstIndex(where: { $0.currentSlotIndex == targetSlot && $0.id != tileId }) {
                var occupant = movableTiles[occupiedIndex]
                occupant.currentSlotIndex = originalSlot
                occupant.loosePosition = originalLoosePos
                if originalSlot == nil && activeMode == .pyramid { occupant.rotation = Double.random(in: 0...360) }
                movableTiles[occupiedIndex] = occupant
            }
            draggingTile.currentSlotIndex = targetSlot
            draggingTile.rotation = 0
        } else {
            let isSortedMode = activeMode == .daily || activeMode == .ai || (activeMode == .square && (difficulty == .medium || difficulty == .hard))
            if isSortedMode {
                draggingTile.currentSlotIndex = nil
                draggingTile.loosePosition = originalLoosePos
                draggingTile.rotation = 0
                DispatchQueue.main.async { self.boardRefreshTrigger = UUID() }
            } else {
                draggingTile.currentSlotIndex = nil
                draggingTile.loosePosition = dropLocation
                draggingTile.rotation = activeMode == .pyramid ? Double.random(in: 0...360) : 0
            }
        }
        movableTiles[draggingIndex] = draggingTile
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    
    func submitRound() {
        stopTimer()
        let generator = UINotificationFeedbackGenerator(); var roundErrors = 0
        if activeMode == .linear {
            for (index, tile) in movableTiles.enumerated() { if tile.correctIndex != index { roundErrors += 1 } }
        } else {
            for tile in movableTiles { if tile.currentSlotIndex != tile.correctIndex { roundErrors += 1 } }
        }
        
        // Update Max Score if needed (for Daily)
        if activeMode == .daily || activeMode == .ai {
            maxPossibleScore = validDailySlots.count * 2
        }

        let roundMax = activeMode == .linear ? 10 : ((activeMode == .daily || activeMode == .ai) ? (validDailySlots.count * 2) : 100)
        let pointsEarned = max(0, roundMax - roundErrors)
        currentScore += pointsEarned
        totalErrors += roundErrors
        roundComplete = true
        roundMessage = (roundErrors == 0) ? "Perfect! +\(pointsEarned)" : "Errors: \(roundErrors) (+\(pointsEarned) pts)"
        if roundErrors > 0 { let currentCount = errorHistory[currentRoundColorName] ?? 0; errorHistory[currentRoundColorName] = currentCount + roundErrors }
        if roundErrors == 0 { generator.notificationOccurred(.success) } else { generator.notificationOccurred(.warning) }
    }
    
    func nextRound(isPro: Bool) {
        if currentRound < totalRounds {
            currentRound += 1; startNewRound(); startTimer()
        } else {
            if activeMode == .linear && difficulty == .easy && !isPro {
                startPreview()
            } else {
                stopTimer()
                if activeMode == .daily {
                    let k = "completedDailyCount"
                    UserDefaults.standard.set(UserDefaults.standard.integer(forKey: k) + 1, forKey: k)
                }
                saveTimeIfBest()

                if activeMode == .daily || activeMode == .ai {
                    isDailyReview = true
                } else {
                    isGameOver = true
                }
            }
        }
    }
    
    func getAnalysisMessage() -> String {
        if totalErrors == 0 { return "Status: Perfect Color Vision!\nYou have a Superior ColorHueIQ." }
        let sortedWeaknesses = errorHistory.sorted { $0.value > $1.value }
        if let worstColor = sortedWeaknesses.first { return "Analysis: You struggle most with \(worstColor.key) hues." }
        return "Status: Great job! Just a few minor slips."
    }
    func getColorName(hue: Double) -> String {
        switch hue {
        case 0.0...0.05, 0.95...1.0: return "Red"; case 0.05...0.12: return "Orange"; case 0.12...0.17: return "Yellow"; case 0.17...0.45: return "Green"; case 0.45...0.55: return "Teal"; case 0.55...0.75: return "Blue"; case 0.75...0.95: return "Purple"; default: return "Color"
        }
    }
    func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60; let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    func quitGame() { stopTimer(); gameStarted = false }
    func restartGame() { stopTimer(); gameStarted = false }
}

// --- CONFETTI VIEW ---
struct ConfettiView: View {
    @State private var particles: [ConfettiParticle] = []
    @State private var tick: Timer?
    let colors: [Color] = [.red, .blue, .green, .yellow, .pink, .purple, .orange]
    var body: some View {
        GeometryReader { geo in
            ZStack { ForEach(particles) { p in Circle().fill(p.color).frame(width: 10, height: 10).position(x: p.x, y: p.y).opacity(p.y > geo.size.height - 50 ? 0 : 1) } }
                .onAppear { createParticles(in: geo.size) }
                .onDisappear { tick?.invalidate(); tick = nil }
        }.edgesIgnoringSafeArea(.all)
    }
    func createParticles(in size: CGSize) {
        tick?.invalidate()
        particles = (0..<100).map { _ in ConfettiParticle(x: CGFloat.random(in: 0...size.width), y: -CGFloat.random(in: 0...size.height), color: colors.randomElement()!, rotation: Double.random(in: 0...360), speed: Double.random(in: 3...8)) }
        tick = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            for i in 0..<particles.count {
                particles[i].y += particles[i].speed
                if particles[i].y > size.height + 20 {
                    particles[i].y = -20
                    particles[i].x = CGFloat.random(in: 0...size.width)
                }
            }
        }
    }
}

struct ContentView: View {
    @StateObject var game = GameViewModel()
    @StateObject var store = TipStore()
    
    var body: some View {
        ZStack {
            Color(UIColor.systemGroupedBackground).edgesIgnoringSafeArea(.all)
            
            if !game.gameStarted {
                StartScreenView(game: game, store: store)
            } else {
                // GamePlayView now handles Playing, Daily Review, AND Game Over
                GamePlayView(game: game, store: store)
                
                if game.newRecordAchieved && game.activeMode != .daily && game.activeMode != .ai && game.isGameOver {
                    ConfettiView().zIndex(100).allowsHitTesting(false)
                }
            }
        }
    }
}

struct StartScreenView: View {
    @ObservedObject var game: GameViewModel
    @ObservedObject var store: TipStore
    
    @State private var showSettings = false
    @State private var showHallOfFame = false
    @State private var showLockAlert = false
    @State private var showDailyAlert = false
    @State private var showAIModeSheet = false
    @State private var aiPrompt = ""
    @State private var aiLoading = false
    @State private var aiError: String?

    @AppStorage("launchCount") var launchCount = 0
    @AppStorage("neverAskReview") var neverAskReview = false
    @AppStorage("lastReviewPromptTime") private var lastReviewPromptTime: Double = 0
    @State private var showReviewAlert = false
    
    func selectMode(_ mode: String) {
        let generator = UIImpactFeedbackGenerator(style: .light); generator.impactOccurred()
        withAnimation {
            if mode == "linear" { game.useChaosShapes = false }
            else { game.useChaosShapes = true; game.chaosModeType = mode }
        }
    }
    
    func handleStart(difficulty: Difficulty) {
        if !game.useChaosShapes && difficulty == .easy { game.startGame(selectedDifficulty: .easy); return }
        if store.hasUnlockedPro { game.startGame(selectedDifficulty: difficulty) }
        else { showLockAlert = true }
    }
    
    func handleDailyTap() {
        if store.hasUnlockedPro {
            // No alerts needed; ViewModel checks date and loads review mode if needed
            game.startDailyChallenge()
        } else {
            showDailyAlert = true
        }
    }
    
    func checkForReviewPrompt() {
        if neverAskReview { return }
        launchCount += 1
        let minLaunches = 10
        let interval: TimeInterval = 30 * 24 * 3600
        let now = Date().timeIntervalSince1970
        guard launchCount >= minLaunches else { return }
        let completed = UserDefaults.standard.integer(forKey: "completedDailyCount")
        guard completed >= 1 || launchCount >= 25 else { return }
        if lastReviewPromptTime > 0, (now - lastReviewPromptTime) < interval { return }
        lastReviewPromptTime = now
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { showReviewAlert = true }
    }

    func submitAIPrompt() {
        let trimmed = String(aiPrompt.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            aiError = "Enter a short description (max 200 characters)."
            return
        }
        guard AIModeClientConfig.baseURL != nil else {
            aiError = AIModeClientConfig.baseURLSetupMessage()
            return
        }
        aiError = nil
        aiLoading = true
        Task {
            do {
                let res = try await AIModeClient.shared.generatePuzzle(prompt: trimmed, isPro: store.hasUnlockedPro)
                await MainActor.run {
                    aiLoading = false
                    if game.beginAIModeGame(spec: res.puzzle, prompt: trimmed) {
                        showAIModeSheet = false
                        aiPrompt = ""
                    } else {
                        aiError = "The server returned an invalid puzzle. Try again."
                    }
                }
            } catch {
                await MainActor.run {
                    aiLoading = false
                    aiError = error.localizedDescription
                }
            }
        }
    }
    
    func openAppStoreReview() {
        if let url = URL(string: "https://apps.apple.com/app/id6758524857?action=write-review") { UIApplication.shared.open(url) }
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            
            // --- TOP BAR ---
            HStack {
                Button(action: { showHallOfFame = true }) {
                    Image(systemName: "trophy.fill").font(.title2).foregroundColor(.orange).padding(10).background(Circle().fill(Color(UIColor.systemBackground)).shadow(radius: 2))
                }
                
                Spacer()
                
                // NEW: DAILY CALENDAR BUTTON
                Button(action: { handleDailyTap() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                        Text("Daily")
                    }
                    .font(.headline.bold())
                    .foregroundColor(.white)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .cornerRadius(20)
                    .shadow(radius: 3)
                }
                
                Spacer()
                
                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape.fill").font(.title2).foregroundColor(.secondary).padding(10).background(Circle().fill(Color(UIColor.systemBackground)).shadow(radius: 2))
                }
            }.padding(.horizontal, 20).padding(.top, 10).zIndex(10)
            
            VStack(spacing: 20) {
                Spacer()
                Image("Logo").resizable().scaledToFit().frame(maxWidth: 300, maxHeight: 300).cornerRadius(20).shadow(radius: 10)
                
                // MODE TOGGLE
                VStack(spacing: 10) {
                    Text("Select Mode").font(.caption).fontWeight(.bold).foregroundColor(.secondary)
                    HStack(spacing: 12) {
                        ModeButton(title: "Linear", icon: "line.3.horizontal", isSelected: !game.useChaosShapes) { selectMode("linear") }
                        ModeButton(title: "Pyramid", icon: "triangle.fill", isSelected: game.useChaosShapes && game.chaosModeType == "pyramid") { selectMode("pyramid") }
                        ModeButton(title: "Square", icon: "square.grid.2x2.fill", isSelected: game.useChaosShapes && game.chaosModeType == "square") { selectMode("square") }
                    }
                }.padding(.bottom, 10)

                Button(action: { aiError = nil; showAIModeSheet = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text("AI puzzle")
                    }
                    .font(.headline.bold())
                    .foregroundColor(.white)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 20)
                    .background(LinearGradient(colors: [.pink, .orange], startPoint: .leading, endPoint: .trailing))
                    .cornerRadius(20)
                    .shadow(radius: 3)
                }
                Text("Describe a shape; the server builds an 8×8 puzzle. Free: 1/day · Pro: 10/day (UTC).")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                // DIFFICULTY BUTTONS
                if !game.useChaosShapes {
                    VStack(spacing: 8) {
                        Button("Easy (Warmup)") { handleStart(difficulty: .easy) }.buttonStyle(DifficultyButtonStyle(color: .green))
                        HStack(spacing: 10) {
                            Button("Medium") { handleStart(difficulty: .medium) }.buttonStyle(SmallDifficultyButtonStyle(color: store.hasUnlockedPro ? .blue : .gray))
                            Button("Hard") { handleStart(difficulty: .hard) }.buttonStyle(SmallDifficultyButtonStyle(color: store.hasUnlockedPro ? .red : .gray))
                        }
                    }
                }
                
                if game.useChaosShapes && game.chaosModeType == "pyramid" {
                    Button(action: { handleStart(difficulty: .medium) }) { HStack { Text("Start Puzzle"); if !store.hasUnlockedPro { Image(systemName: "lock.fill") } } }.buttonStyle(DifficultyButtonStyle(color: store.hasUnlockedPro ? .blue : .gray))
                }
                
                if game.useChaosShapes && game.chaosModeType == "square" {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            Button(action: { handleStart(difficulty: .medium) }) { VStack(spacing: 2) { Text("Medium").fontWeight(.bold); Text("(Sorted)").font(.caption2).opacity(0.8); if !store.hasUnlockedPro { Image(systemName: "lock.fill").font(.caption) } } }.buttonStyle(SmallDifficultyButtonStyle(color: store.hasUnlockedPro ? .blue : .gray))
                            Button(action: { handleStart(difficulty: .hard) }) { VStack(spacing: 2) { Text("Hard").fontWeight(.bold); Text("(Sorted)").font(.caption2).opacity(0.8); if !store.hasUnlockedPro { Image(systemName: "lock.fill").font(.caption) } } }.buttonStyle(SmallDifficultyButtonStyle(color: store.hasUnlockedPro ? .red : .gray))
                        }
                        HStack(spacing: 10) {
                            Button(action: { handleStart(difficulty: .mediumChaos) }) { VStack(spacing: 2) { Text("Medium").fontWeight(.bold); Text("(Chaos)").font(.caption2).opacity(0.8); if !store.hasUnlockedPro { Image(systemName: "lock.fill").font(.caption) } } }.buttonStyle(SmallDifficultyButtonStyle(color: store.hasUnlockedPro ? .purple : .gray))
                            Button(action: { handleStart(difficulty: .hardChaos) }) { VStack(spacing: 2) { Text("Hard").fontWeight(.bold); Text("(Chaos)").font(.caption2).opacity(0.8); if !store.hasUnlockedPro { Image(systemName: "lock.fill").font(.caption) } } }.buttonStyle(SmallDifficultyButtonStyle(color: store.hasUnlockedPro ? .orange : .gray))
                        }
                    }
                }
                
                if !store.hasUnlockedPro && game.useChaosShapes { Text("Unlock for Full Experience").font(.caption2).foregroundColor(.secondary).padding(.top, 5) }
                Spacer(); Spacer()
            }.padding()
        }
        .onAppear { checkForReviewPrompt() }
        .sheet(isPresented: $showSettings) { SettingsView(store: store, game: game) }
        .sheet(isPresented: $showHallOfFame) { HallOfFameView(game: game) }
        .alert("Daily Challenge Locked", isPresented: $showDailyAlert) {
            Button("Cancel", role: .cancel) { }
            if let product = store.products.first { Button("Unlock (\(product.displayPrice))") { Task { await store.purchase(product) } } }
        } message: { Text("The Daily Challenge is a unique, procedurally generated puzzle every single day.\n\nUnlock Pro to play!") }
        .alert("Mode Locked", isPresented: $showLockAlert) {
            Button("Cancel", role: .cancel) { }
            if let product = store.products.first { Button("Unlock (\(product.displayPrice))") { Task { await store.purchase(product) } } }
        } message: { Text("Unlock Medium, Hard, and Chaos modes forever!") }
        .alert("Enjoying ColorHueIQ?", isPresented: $showReviewAlert) {
            Button("Rate Now", role: .none) { openAppStoreReview() }
            Button("Later", role: .cancel) { }
            Button("Never Remind Me", role: .destructive) { neverAskReview = true }
        } message: { Text("If you’re enjoying the app, a quick App Store rating helps a lot. No pressure — we won’t ask again for a while.") }
        .sheet(isPresented: $showAIModeSheet) {
            NavigationView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("What should today’s silhouette look like?")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    TextField("e.g. Minion face, rocket ship", text: $aiPrompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...6)
                        .onChange(of: aiPrompt) { _, new in
                            if new.count > 200 { aiPrompt = String(new.prefix(200)) }
                        }
                    Text("\(aiPrompt.count)/200 characters")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if let err = aiError {
                        Text(err).font(.caption).foregroundColor(.red)
                    }
                    Spacer()
                    Button(action: submitAIPrompt) {
                        if aiLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Generate puzzle").font(.headline).frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(aiLoading)
                }
                .padding()
                .navigationTitle("AI puzzle")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showAIModeSheet = false }
                    }
                }
            }
        }
    }
}
// Add this helper for the grid buttons
struct SmallDifficultyButtonStyle: ButtonStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .foregroundColor(.white)
            .padding(.vertical, 12)
            .frame(maxWidth: 140) // Smaller width for side-by-side
            .background(color)
            .cornerRadius(12)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .shadow(radius: 2)
    }
}

// --- HELPER: MODE BUTTON (Keep this file too) ---
struct ModeButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.caption).fontWeight(.bold)
            }
            .frame(width: 80, height: 70)
            .background(isSelected ? Color.blue.opacity(0.15) : Color.gray.opacity(0.1))
            .foregroundColor(isSelected ? .blue : .secondary)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2))
        }
    }
}
// --- SETTINGS VIEW (Cleaned) ---
struct SettingsView: View {
    @ObservedObject var store: TipStore
    @ObservedObject var game: GameViewModel
    @Environment(\.dismiss) var dismiss
    
    @State private var showRestoreAlert = false
    @State private var restoreMessage = ""
    
    var body: some View {
        NavigationView {
            List {
                // 1. STATUS
                Section(header: Text("Status")) {
                    HStack {
                        Image(systemName: store.hasUnlockedPro ? "checkmark.seal.fill" : "lock.fill")
                            .foregroundColor(store.hasUnlockedPro ? .green : .gray).font(.title2)
                        VStack(alignment: .leading) {
                            Text(store.hasUnlockedPro ? "Pro Version Unlocked" : "Free Version").font(.headline)
                            if !store.hasUnlockedPro { Text("Upgrade to unlock all features").font(.caption).foregroundColor(.secondary) }
                        }
                    }.padding(.vertical, 4)
                }
                
                // 2. HOW TO PLAY
                Section(header: Text("How to Play")) {
                    DisclosureGroup("Linear Mode (Classic)") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("• Drag and drop tiles to arrange them in a smooth color gradient.")
                            Text("• Connect the locked start color to the locked end color.")
                            Text("• 10 Rounds. Higher accuracy + Speed = High Score.")
                        }
                        .font(.caption).foregroundColor(.secondary).padding(.vertical, 5)
                    }
                    
                    DisclosureGroup("Pyramid Mode (Chaos)") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("• A 16-piece triangle puzzle.")
                            Text("• Drag triangles from the pile to the board.")
                            Text("• Pieces automatically rotate to fit the slot (Up or Down).")
                            Text("• Match the gradients on all sides!")
                        }
                        .font(.caption).foregroundColor(.secondary).padding(.vertical, 5)
                    }
                    
                    DisclosureGroup("Square Grid (8x8)") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("• A 2D color challenge.")
                            Text("• Colors blend Horizontally AND Vertically.")
                            Text("• Use the 4 locked corners as your guide.")
                            Text("• Tiles snap to the grid or return to the dock if placed incorrectly.")
                        }
                        .font(.caption).foregroundColor(.secondary).padding(.vertical, 5)
                    }
                    
                    DisclosureGroup("Daily Challenge") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("• One puzzle per UTC calendar day, same silhouette for every player.")
                            Text("• Letters, digits, and simple icons — not random blobs.")
                            Text("• Uses square tiles; empty grid cells are ignored.")
                        }
                        .font(.caption).foregroundColor(.secondary).padding(.vertical, 5)
                    }
                    DisclosureGroup("AI puzzle") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("• Describe a shape in text; the server asks AI for a valid puzzle JSON.")
                            Text("• Free: 1 generation per UTC day. Pro: 10 per UTC day.")
                            Text("• Set AIApiBaseURL in HueGame/Info.plist to your .vercel.app URL (see api/README.md).")
                        }
                        .font(.caption).foregroundColor(.secondary).padding(.vertical, 5)
                    }
                }
                
                // 3. PRO FEATURES
                Section(header: Text("Pro Features")) {
                    FeatureRow(icon: "gamecontroller.fill", color: .blue, text: "Unlock Medium Difficulty")
                    FeatureRow(icon: "flame.fill", color: .red, text: "Unlock Hard Difficulty")
                    FeatureRow(icon: "triangle.fill", color: .purple, text: "Chaos Modes (Pyramid & Square)")
                    FeatureRow(icon: "calendar", color: .orange, text: "Daily Challenges (UTC)")
                    FeatureRow(icon: "sparkles", color: .pink, text: "AI puzzles (10/day Pro, 1/day free)")
                }
                
                // 4. STORE
                Section(header: Text("Store")) {
                    if !store.hasUnlockedPro {
                        if let product = store.products.first {
                            Button(action: { Task { await store.purchase(product) } }) {
                                HStack { Text("Unlock All Modes").fontWeight(.semibold); Spacer(); Text(product.displayPrice).foregroundColor(.secondary) }
                            }.foregroundColor(.blue)
                        } else { Text("Loading Store...").foregroundColor(.secondary) }
                    }
                    Button("Restore Purchases") {
                        Task { await store.restorePurchases(); restoreMessage = store.hasUnlockedPro ? "Success! Pro Version restored." : "No purchases found."; showRestoreAlert = true }
                    }.foregroundColor(.primary)
                }
                
                // 5. FOOTER
                Section { HStack { Spacer(); VStack(spacing: 4) { Text("ColorHueIQ v2.0").font(.caption).bold(); Text("Designed for accuracy").font(.caption2).foregroundColor(.secondary) }; Spacer() } }.listRowBackground(Color.clear)
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
            .alert("Restore Purchases", isPresented: $showRestoreAlert) { Button("OK", role: .cancel) { } } message: { Text(restoreMessage) }
        }
    }
}

// --- HALL OF FAME VIEW ---
struct HallOfFameView: View {
    @ObservedObject var game: GameViewModel
    @Environment(\.dismiss) var dismiss
    
    var todayKey: String { "daily_\(DailyCalendar.utcYMDString())" }
    
    func statRow(title: String, key: String) -> some View {
        HStack {
            Text(title)
                .fontWeight(.medium)
                .layoutPriority(1)
            Spacer()
            
            if let stats = game.getBestStats(for: key) {
                HStack(spacing: 6) {
                    HStack(spacing: 2) {
                        Image(systemName: "stopwatch").foregroundColor(.blue)
                        Text(stats.time).monospacedDigit()
                    }
                    HStack(spacing: 2) {
                        Image(systemName: "star.circle").foregroundColor(.orange)
                        Text(stats.score)
                    }
                }
                .font(.caption)
                
                Button(action: { game.resetBestTime(for: key) }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                        .opacity(0.7)
                }
                .padding(.leading, 4)
            } else {
                Text("--")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
    
    var body: some View {
        NavigationView {
            List {
                // NEW: Streak Section
                Section {
                    HStack {
                        Image(systemName: "flame.fill")
                            .font(.title)
                            .foregroundColor(.orange)
                        VStack(alignment: .leading) {
                            Text("\(game.currentStreak) Day Streak")
                                .font(.headline)
                            Text("Keep playing daily!")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
                
                // Section 1: Linear
                Section(header: Text("Linear (Classic)")) {
                    statRow(title: "Easy", key: "easy")
                    statRow(title: "Medium", key: "medium")
                    statRow(title: "Hard", key: "hard")
                }
                
                // Section 2: Square Grid
                Section(header: Text("Square Grid (8x8)")) {
                    statRow(title: "Medium (Sorted)", key: "square_medium")
                    statRow(title: "Hard (Sorted)", key: "square_hard")
                    statRow(title: "Medium (Chaos)", key: "square_mediumChaos")
                    statRow(title: "Hard (Chaos)", key: "square_hardChaos")
                }
                
                // Section 3: Pyramid
                Section(header: Text("Pyramid")) {
                    statRow(title: "Triangle Chaos", key: "pyramid")
                }
                
                // Section 4: Daily
                Section(header: Text("Daily Challenge (UTC)")) {
                    statRow(title: "Today's puzzle", key: todayKey)
                }

                Section(header: Text("AI puzzle")) {
                    statRow(title: "Best run", key: "ai_challenge")
                }
                
                // Footer
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scoring")
                            .font(.headline)
                        Text("Higher Scores are better.\nLower Times are better.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Hall of Fame")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
struct GamePlayView: View {
    @ObservedObject var game: GameViewModel
    var store: TipStore
    
    @State private var draggedItem: ColorTile?
    @State private var dragLocation: CGPoint = .zero
    
    var shareMessage: String {
        return "I scored \(game.currentScore)/\(game.maxPossibleScore) on ColorHueIQ!"
    }
    
    var body: some View {
        VStack(spacing: 15) {
            // --- HEADER ---
            HStack(alignment: .top) {
                Button("Quit") { game.quitGame() }
                    .foregroundColor(.red).padding(.leading)
                
                Spacer()
                
                VStack(spacing: 4) {
                    if game.isPreviewMode {
                        Text("PREVIEW MODE").font(.headline).bold().foregroundColor(.red)
                        Text(game.formatTime(game.timeElapsed)).font(.title3.monospacedDigit()).bold().foregroundColor(.red)
                    } else if game.isDailyReview {
                        Text(game.activeMode == .ai ? "Puzzle complete" : "Daily completed").font(.headline).bold().foregroundColor(.green)
                        Text("Final Time: \(game.formatTime(game.timeElapsed))").font(.subheadline.bold())
                    } else if game.isGameOver {
                        Text("Game Over").font(.headline).bold().foregroundColor(.primary)
                        Text("Final Time: \(game.formatTime(game.timeElapsed))").font(.subheadline.bold())
                    } else {
                        Text(game.activeMode == .daily ? "Daily Challenge" : (game.activeMode == .ai ? "AI Puzzle" : "Round \(game.currentRound) / \(game.totalRounds)")).font(.headline)
                        Text(game.formatTime(game.timeElapsed)).font(.title3.monospacedDigit()).bold().foregroundColor(.blue)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing) {
                    Text("Score").font(.caption).foregroundColor(.secondary)
                    Text("\(game.currentScore) / \(game.maxPossibleScore)").fontWeight(.bold).foregroundColor(.orange)
                }.padding(.trailing)
            }
            .padding(.top)
            
            Spacer()
            
            // --- BOARD RENDERER ---
            if game.activeMode == .linear {
                LinearBoardView(game: game, draggedItem: $draggedItem)
            } else if game.activeMode == .pyramid {
                PyramidBoardView(game: game, draggedItem: $draggedItem, dragLocation: $dragLocation)
            } else {
                SquareBoardView(game: game, draggedItem: $draggedItem, dragLocation: $dragLocation)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            Spacer()
            
            // --- FOOTER / CONTROLS ---
            if game.isDailyReview {
                // DAILY REVIEW FOOTER
                VStack(spacing: 15) {
                    HStack(spacing: 30) {
                        InfoColumn(label: "Score", value: "\(game.currentScore)/\(game.maxPossibleScore)")
                        InfoColumn(label: "Time", value: game.formatTime(game.timeElapsed))
                        InfoColumn(label: "Errors", value: "\(game.totalErrors)", valueColor: game.totalErrors == 0 ? .green : .red)
                    }
                    .padding().background(Color(UIColor.secondarySystemBackground)).cornerRadius(12)
                    
                    Text(game.activeMode == .ai ? "Generate another idea from the main menu." : "Come back tomorrow (UTC) for a new letter or icon!").font(.caption).foregroundColor(.secondary)
                    
                    Button(action: { game.restartGame() }) {
                        Text("Main Menu").font(.headline).foregroundColor(.white).padding().frame(maxWidth: .infinity).background(Color.blue).cornerRadius(12)
                    }
                }.padding(.horizontal)
                
            } else if game.isGameOver {
                // NEW: STANDARD GAME OVER FOOTER (Replaces Overlay)
                VStack(spacing: 12) {
                    // 1. Analysis Box
                    Text(game.getAnalysisMessage())
                        .font(.subheadline).fontWeight(.medium).multilineTextAlignment(.center)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                    
                    // 2. Share Button
                    ShareLink(item: shareMessage) {
                        Label("Share Results", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .foregroundColor(.blue)
                            .padding(.vertical, 5)
                    }
                    
                    // 3. Main Menu Button
                    Button(action: { game.restartGame() }) {
                        Text("Main Menu").font(.headline).foregroundColor(.white).padding().frame(maxWidth: .infinity).background(Color.blue).cornerRadius(12)
                    }
                }.padding(.horizontal)
                
            } else if game.roundComplete {
                // NEXT ROUND BUTTON
                VStack(spacing: 15) {
                    Text(game.roundMessage).font(.title2).bold()
                    Button(action: { game.nextRound(isPro: store.hasUnlockedPro) }) {
                        Text(game.currentRound == game.totalRounds ? (game.isPreviewMode ? "End Preview" : "Finish Game") : "Next Round")
                            .font(.headline).foregroundColor(.white).padding()
                            .frame(maxWidth: .infinity).background(Color.blue).cornerRadius(12).padding(.horizontal)
                    }
                }
            } else {
                // PLAYING CONTROLS (Shuffle, Magnet, Submit)
                HStack(spacing: 15) {
                    if game.shufflesRemaining > 0 {
                        Button(action: { game.useShuffle() }) {
                            HStack { Image(systemName: "shuffle"); Text("New Gradient (\(game.shufflesRemaining))") }
                                .font(.footnote.bold()).padding(10).background(Color.gray.opacity(0.1)).foregroundColor(.primary).cornerRadius(8)
                        }
                    }
                    
                    if (game.activeMode == .square || game.activeMode == .daily || game.activeMode == .ai) && game.difficulty != .mediumChaos && game.difficulty != .hardChaos {
                        Button(action: { game.activateMagnet() }) {
                            HStack { Image(systemName: "arrow.triangle.merge"); Text("Snap to Grid") }
                                .font(.footnote.bold()).padding(10).background(Color.blue.opacity(0.1)).foregroundColor(.blue).cornerRadius(8)
                        }
                    }
                }.padding(.bottom, 8)
                
                Button(action: { let i = UIImpactFeedbackGenerator(style: .medium); i.impactOccurred(); game.submitRound() }) {
                    Text("Submit").font(.headline).foregroundColor(.white).padding().frame(maxWidth: .infinity).background(Color.orange).cornerRadius(12).padding(.horizontal)
                }
            }
            Spacer().frame(height: 20)
        }
    }
}

// Helper View for the Footer Stats
struct InfoColumn: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    
    var body: some View {
        VStack {
            Text(label).font(.caption).foregroundColor(.secondary)
            Text(value).font(.title3).bold().foregroundColor(valueColor)
        }
    }
}

// --- LINEAR BOARD (iPad Scaled) ---
struct LinearBoardView: View {
    @ObservedObject var game: GameViewModel
    @Binding var draggedItem: ColorTile?
    
    // Check for iPad
    let isPad = UIDevice.current.userInterfaceIdiom == .pad
    
    var body: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            // Less padding on iPad to make tiles wider
            let availableWidth = totalWidth - (isPad ? 60 : 32)
            let slotWidth = availableWidth / CGFloat(game.movableTiles.count + 2)
            
            // Taller tiles on iPad
            let tileHeight: CGFloat = isPad ? 140 : 80
            
            HStack(spacing: 0) {
                // START LOCK
                Rectangle().fill(game.fixedStart)
                    .frame(width: slotWidth, height: tileHeight)
                    .overlay(Image(systemName: "lock.fill").foregroundColor(.white.opacity(0.5)))
                
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(0..<game.movableTiles.count, id: \.self) { _ in
                            Rectangle().fill(Color.clear).frame(width: slotWidth, height: tileHeight)
                        }
                    }
                    HStack(spacing: 0) {
                        ForEach(Array(game.movableTiles.enumerated()), id: \.element.id) { index, tile in
                            Rectangle().fill(tile.color)
                                .frame(width: slotWidth, height: tileHeight)
                                .scaleEffect(draggedItem == tile ? 1.1 : 1.0)
                                .zIndex(draggedItem == tile ? 100 : 1)
                                .shadow(radius: draggedItem == tile ? 10 : 0)
                                .overlay(Group {
                                    if game.roundComplete && tile.correctIndex != index {
                                        Image(systemName: "xmark").foregroundColor(.white).font(.headline).shadow(radius: 2)
                                    }
                                })
                                .gesture(
                                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                        .onChanged { value in
                                            if draggedItem == nil { let impact = UIImpactFeedbackGenerator(style: .medium); impact.impactOccurred(); draggedItem = tile }
                                            
                                            // Snap Logic
                                            let startX = geo.frame(in: .global).minX + (isPad ? 30 : 16) + slotWidth
                                            let currentX = value.location.x
                                            let rawIndex = Int((currentX - startX) / slotWidth)
                                            let targetIndex = min(max(rawIndex, 0), game.movableTiles.count - 1)
                                            
                                            if let currentIndex = game.movableTiles.firstIndex(of: tile), currentIndex != targetIndex {
                                                game.swapLinearTiles(from: currentIndex, to: targetIndex)
                                            }
                                        }
                                        .onEnded { _ in draggedItem = nil }
                                )
                        }
                    }
                }
                
                // END LOCK
                Rectangle().fill(game.fixedEnd)
                    .frame(width: slotWidth, height: tileHeight)
                    .overlay(Image(systemName: "lock.fill").foregroundColor(.white.opacity(0.5)))
            }
            .padding(.horizontal, isPad ? 30 : 16)
            .position(x: totalWidth / 2, y: geo.size.height / 2)
        }
        .frame(height: isPad ? 200 : 120) // Taller Frame for iPad
    }
}
// --- PYRAMID BOARD (iPad Scaled) ---
struct PyramidBoardView: View {
    @ObservedObject var game: GameViewModel
    @Binding var draggedItem: ColorTile?
    @Binding var dragLocation: CGPoint
    
    // SCALE CONSTANTS
    let isPad = UIDevice.current.userInterfaceIdiom == .pad
    
    var triangleSize: CGFloat { isPad ? 110 : 60 }
    var visualTileSize: CGFloat { isPad ? 96 : 52 }
    
    func isPointingUp(index: Int) -> Bool {
        if index == 0 { return true }
        if index >= 1 && index <= 3 { return (index - 1) % 2 == 0 }
        if index >= 4 && index <= 8 { return (index - 4) % 2 == 0 }
        if index >= 9 && index <= 15 { return (index - 9) % 2 == 0 }
        return true
    }
    
    func getSlotPosition(index: Int, center: CGPoint) -> CGPoint {
        var row = 0; var indexInRow = 0
        if index < 1 { row = 0; indexInRow = index }
        else if index < 4 { row = 1; indexInRow = index - 1 }
        else if index < 9 { row = 2; indexInRow = index - 4 }
        else { row = 3; indexInRow = index - 9 }
        
        let rowY = center.y - (4 * triangleSize * 0.4) + (CGFloat(row) * triangleSize * 0.866)
        let tilesInThisRow = (row * 2) + 1
        let totalRowWidth = CGFloat(tilesInThisRow) * (triangleSize / 2)
        let rowStartX = center.x - (totalRowWidth / 2) + (triangleSize / 4)
        return CGPoint(x: rowStartX + (CGFloat(indexInRow) * (triangleSize / 2)), y: rowY)
    }
    
    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2 - 50)
            
            ZStack {
                // Outlines
                ForEach(0..<16, id: \.self) { i in
                    let pos = getSlotPosition(index: i, center: center); let pointsUp = isPointingUp(index: i)
                    Triangle()
                        .rotation(Angle(degrees: pointsUp ? 0 : 180))
                        .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                        .frame(width: triangleSize, height: triangleSize).position(pos)
                }
                
                // Locked
                ForEach(game.lockedTiles.keys.sorted(), id: \.self) { i in
                    let color = game.lockedTiles[i]!; let pos = getSlotPosition(index: i, center: center)
                    Triangle()
                        .rotation(Angle(degrees: isPointingUp(index: i) ? 0 : 180))
                        .fill(color)
                        .frame(width: visualTileSize, height: visualTileSize).position(pos)
                        .overlay(Image(systemName: "lock.fill")
                            .font(isPad ? .title : .body) // Bigger Lock
                            .foregroundColor(.white.opacity(0.5)).position(pos))
                }
                
                // Movable
                ForEach(game.movableTiles) { tile in
                    let isBeingDragged = (draggedItem == tile)
                    let pointsUp: Bool = { if let slot = tile.currentSlotIndex { return isPointingUp(index: slot) }; return false }()
                    let targetPosition: CGPoint = {
                        if isBeingDragged { return CGPoint(x: dragLocation.x - geo.frame(in: .global).minX, y: dragLocation.y - geo.frame(in: .global).minY) }
                        if let slot = tile.currentSlotIndex { return getSlotPosition(index: slot, center: center) }
                        return tile.loosePosition
                    }()
                    
                    Triangle()
                        .rotation(Angle(degrees: isBeingDragged ? 0 : (tile.currentSlotIndex != nil ? (pointsUp ? 0 : 180) : tile.rotation)))
                        .fill(tile.color)
                        .frame(width: visualTileSize, height: visualTileSize)
                        .scaleEffect(isBeingDragged ? 1.3 : 1.0)
                        .shadow(radius: isBeingDragged ? 10 : 2)
                        .position(targetPosition)
                        .zIndex(isBeingDragged ? 999 : 1)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                .onChanged { value in
                                    if draggedItem == nil { UIImpactFeedbackGenerator(style: .medium).impactOccurred(); draggedItem = tile }
                                    dragLocation = value.location
                                }
                                .onEnded { value in
                                    let dropPointLocal = CGPoint(x: value.location.x - geo.frame(in: .global).minX, y: value.location.y - geo.frame(in: .global).minY)
                                    var bestSlot: Int? = nil
                                    var minDist: CGFloat = isPad ? 80 : 50 // Bigger drop target
                                    
                                    for i in 0..<16 {
                                        if game.lockedTiles[i] != nil { continue }
                                        let slotPos = getSlotPosition(index: i, center: center)
                                        let dist = hypot(slotPos.x - dropPointLocal.x, slotPos.y - dropPointLocal.y)
                                        if dist < minDist { minDist = dist; bestSlot = i }
                                    }
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { game.dropChaosTile(tileId: tile.id, targetSlot: bestSlot, dropLocation: dropPointLocal) }
                                    draggedItem = nil
                                }
                        )
                        .overlay(Group {
                            if game.roundComplete, let slot = tile.currentSlotIndex, slot != tile.correctIndex {
                                Circle().fill(Color.white).frame(width: isPad ? 12 : 8, height: isPad ? 12 : 8).position(targetPosition)
                            }
                        })
                }
            }
            .onChange(of: game.boardRefreshTrigger) { _ in game.randomizeLoosePositions(in: geo.size, safeZoneCenter: center, safeRadius: 180) }
            .onChange(of: geo.size) { _ in game.randomizeLoosePositions(in: geo.size, safeZoneCenter: center, safeRadius: 180) }
            .onAppear { game.randomizeLoosePositions(in: geo.size, safeZoneCenter: center, safeRadius: 180) }
        }
    }
}

// --- SQUARE BOARD (iPad Scaled) ---
struct SquareBoardView: View {
    @ObservedObject var game: GameViewModel
    @Binding var draggedItem: ColorTile?
    @Binding var dragLocation: CGPoint
    
    // SCALE CONSTANTS
    let isPad = UIDevice.current.userInterfaceIdiom == .pad
    
    var gridSize: Int { 8 }
    
    // Double the size for iPad
    var tileSize: CGFloat { isPad ? 72 : 36 }
    var visualSize: CGFloat { isPad ? 64 : 32 }
    
    func getSlotPosition(index: Int, center: CGPoint) -> CGPoint {
        let col = index % gridSize
        let row = index / gridSize
        
        // Calculate Top-Left start point relative to center
        let totalWidth = CGFloat(gridSize) * tileSize
        let startX = center.x - (totalWidth / 2) + (tileSize / 2)
        let startY = center.y - (totalWidth / 2) + (tileSize / 2)
        
        return CGPoint(x: startX + CGFloat(col) * tileSize, y: startY + CGFloat(row) * tileSize)
    }
    
    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.30)
            
            ZStack {
                // Background Grid
                ForEach(0..<64, id: \.self) { i in
                    // DAILY CHECK: If Daily mode, skip void slots
                    if (game.activeMode != .daily && game.activeMode != .ai) || game.validDailySlots.contains(i) {
                        let pos = getSlotPosition(index: i, center: center)
                        
                        Rectangle()
                            .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                            .frame(width: visualSize, height: visualSize)
                            .position(pos)
                    }
                }
                
                // Locked Tiles
                ForEach(game.lockedTiles.keys.sorted(), id: \.self) { i in
                    let color = game.lockedTiles[i]!
                    let pos = getSlotPosition(index: i, center: center)
                    Rectangle().fill(color)
                        .frame(width: visualSize, height: visualSize).position(pos)
                        .overlay(Image(systemName: "lock.fill")
                            .font(isPad ? .title2 : .caption2) // Bigger Icon
                            .foregroundColor(.white.opacity(0.5)).position(pos))
                }
                
                // Movable Tiles
                ForEach(game.movableTiles) { tile in
                    let isBeingDragged = (draggedItem == tile)
                    let targetPosition: CGPoint = {
                        if isBeingDragged { return CGPoint(x: dragLocation.x - geo.frame(in: .global).minX, y: dragLocation.y - geo.frame(in: .global).minY) }
                        if let slot = tile.currentSlotIndex { return getSlotPosition(index: slot, center: center) }
                        return tile.loosePosition
                    }()
                    
                    Rectangle().fill(tile.color)
                        .frame(width: visualSize, height: visualSize)
                        .scaleEffect(isBeingDragged ? 1.3 : 1.0)
                        .shadow(radius: isBeingDragged ? 5 : 1)
                        .position(targetPosition)
                        .zIndex(isBeingDragged ? 999 : 1)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                .onChanged { value in
                                    if draggedItem == nil { UIImpactFeedbackGenerator(style: .medium).impactOccurred(); draggedItem = tile }
                                    dragLocation = value.location
                                }
                                .onEnded { value in
                                    let dropPoint = CGPoint(x: value.location.x - geo.frame(in: .global).minX, y: value.location.y - geo.frame(in: .global).minY)
                                    var bestSlot: Int? = nil
                                    // Increase drop radius for iPad (easier to hit)
                                    var minDist: CGFloat = isPad ? 60 : 40
                                    
                                    for i in 0..<64 {
                                        // DAILY CHECK: Can't drop into void
                                        if (game.activeMode == .daily || game.activeMode == .ai) && !game.validDailySlots.contains(i) { continue }
                                        
                                        if game.lockedTiles[i] != nil { continue }
                                        let slotPos = getSlotPosition(index: i, center: center)
                                        let dist = hypot(slotPos.x - dropPoint.x, slotPos.y - dropPoint.y)
                                        if dist < minDist { minDist = dist; bestSlot = i }
                                    }
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { game.dropChaosTile(tileId: tile.id, targetSlot: bestSlot, dropLocation: dropPoint) }
                                    draggedItem = nil
                                }
                        )
                        .overlay(Group {
                            if game.roundComplete, let slot = tile.currentSlotIndex, slot != tile.correctIndex {
                                Circle().fill(Color.white).frame(width: isPad ? 12 : 6, height: isPad ? 12 : 6).position(targetPosition)
                            }
                        })
                }
            }
            // Triggers
            .onChange(of: game.boardRefreshTrigger) { _ in game.randomizeLoosePositions(in: geo.size, safeZoneCenter: center, safeRadius: 180) }
            .onChange(of: geo.size) { _ in game.randomizeLoosePositions(in: geo.size, safeZoneCenter: center, safeRadius: 180) }
            .onAppear { game.randomizeLoosePositions(in: geo.size, safeZoneCenter: center, safeRadius: 180) }
        }
    }
}
// --- GAME OVER VIEW ---
struct GameOverView: View {
    @ObservedObject var game: GameViewModel
    @ObservedObject var store: TipStore
    
    var shareMessage: String {
        let appLink = "https://apps.apple.com/app/id6758524857"
        return "I scored \(game.currentScore)/\(game.maxPossibleScore) on ColorHueIQ! \(appLink)"
    }
    
    var body: some View {
        ZStack {
            if game.newRecordAchieved && !game.isPreviewMode { ConfettiView().zIndex(10) }
            
            VStack(spacing: 25) {
                Text(game.isPreviewMode ? "Preview Complete" : "Game Over")
                    .font(.largeTitle).bold()
                
                if game.isPreviewMode {
                    VStack(spacing: 10) {
                        Text("Time's Up!").font(.title2).bold().foregroundColor(.red)
                        Text("You've experienced Chaos Mode.")
                        Text("Unlock the full untimed version\nby purchasing All Modes.").font(.headline).multilineTextAlignment(.center).padding(.top, 5)
                    }.padding().background(Color(UIColor.secondarySystemBackground)).cornerRadius(12).padding(.horizontal)
                } else {
                    VStack(spacing: 5) {
                        Text("Final Score").font(.headline).foregroundColor(.secondary)
                        Text("\(game.currentScore) / \(game.maxPossibleScore)")
                            .font(.system(size: 60, weight: .heavy, design: .rounded))
                            .foregroundColor(game.currentScore == game.maxPossibleScore ? .green : .primary)
                    }
                    
                    VStack(spacing: 4) {
                        Text("Time: \(game.formatTime(game.timeElapsed))").font(.title3.monospacedDigit())
                        if game.newRecordAchieved { Text("🏆 NEW HIGH SCORE! 🏆").font(.headline).bold().foregroundColor(.orange).scaleEffect(1.1) }
                        else if let result = game.getBestStats(for: game.getStorageKey()) {
                            Text("Best: \(result.score) pts | \(result.time)").font(.caption).foregroundColor(.secondary)
                        }
                    }.padding(.bottom, 10)
                }
                
                if !game.isPreviewMode {
                    VStack(spacing: 8) {
                        Text(game.getAnalysisMessage()).font(.title3).fontWeight(.medium).multilineTextAlignment(.center).foregroundColor(.primary).padding()
                    }.background(Color(UIColor.secondarySystemBackground)).cornerRadius(12).padding(.horizontal)
                    ShareLink(item: shareMessage) { Label("Share Results", systemImage: "square.and.arrow.up").font(.headline).padding().frame(maxWidth: .infinity).background(Color.blue.opacity(0.8)).foregroundColor(.white).cornerRadius(12) }.padding(.horizontal)
                }
                
                if !store.hasUnlockedPro {
                    if let product = store.products.first {
                        Button(action: { Task { await store.purchase(product) } }) {
                            HStack { Text("☕️"); Text("Unlock All Modes (\(product.displayPrice))").fontWeight(.medium) }
                                .padding().frame(maxWidth: .infinity).background(Color.orange).foregroundColor(.white).cornerRadius(12)
                        }.padding(.horizontal).scaleEffect(game.isPreviewMode ? 1.1 : 1.0)
                    }
                }
                
                Button("Main Menu") { game.restartGame() }.font(.headline).padding(.top, 10)
            }.padding()
        }
    }
}

// --- HELPERS ---
struct FeatureRow: View { let icon: String; let color: Color; let text: String; var body: some View { HStack { Image(systemName: icon).foregroundColor(color).frame(width: 30); Text(text) } } }
struct DifficultyButtonStyle: ButtonStyle { var color: Color; func makeBody(configuration: Configuration) -> some View { configuration.label.font(.title3.bold()).foregroundColor(.white).padding().frame(maxWidth: 250).background(color).cornerRadius(15).scaleEffect(configuration.isPressed ? 0.95 : 1.0).shadow(radius: 3) } }
