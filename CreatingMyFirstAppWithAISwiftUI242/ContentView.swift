import SwiftUI
import Combine
import AVFoundation

struct Position: Hashable {
    let row: Int
    let col: Int
}

struct TowerLevelStats {
    let damage: Int
    let range: Int
    let cooldownTicks: Int
    let slowTicks: Int
}

enum TowerType: String, CaseIterable, Identifiable {
    case archer
    case frost
    case blaze

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .archer: return "弓箭塔"
        case .frost: return "冰霜塔"
        case .blaze: return "火焰塔"
        }
    }

    var emoji: String {
        switch self {
        case .archer: return "🏹"
        case .frost: return "❄️"
        case .blaze: return "🔥"
        }
    }

    var buildCost: Int {
        switch self {
        case .archer: return 5
        case .frost: return 7
        case .blaze: return 9
        }
    }

    private var levelStats: [TowerLevelStats] {
        switch self {
        case .archer:
            return [
                TowerLevelStats(damage: 1, range: 2, cooldownTicks: 2, slowTicks: 0),
                TowerLevelStats(damage: 2, range: 2, cooldownTicks: 2, slowTicks: 0),
                TowerLevelStats(damage: 3, range: 3, cooldownTicks: 1, slowTicks: 0)
            ]
        case .frost:
            return [
                TowerLevelStats(damage: 0, range: 2, cooldownTicks: 2, slowTicks: 2),
                TowerLevelStats(damage: 1, range: 2, cooldownTicks: 2, slowTicks: 3),
                TowerLevelStats(damage: 1, range: 3, cooldownTicks: 1, slowTicks: 4)
            ]
        case .blaze:
            return [
                TowerLevelStats(damage: 3, range: 2, cooldownTicks: 3, slowTicks: 0),
                TowerLevelStats(damage: 4, range: 2, cooldownTicks: 3, slowTicks: 0),
                TowerLevelStats(damage: 6, range: 3, cooldownTicks: 2, slowTicks: 0)
            ]
        }
    }

    private var upgradeCosts: [Int] {
        switch self {
        case .archer: return [6, 8]
        case .frost: return [7, 10]
        case .blaze: return [10, 14]
        }
    }

    var maxLevel: Int {
        levelStats.count
    }

    func stats(for level: Int) -> TowerLevelStats {
        let clampedLevel = min(max(level, 1), maxLevel)
        return levelStats[clampedLevel - 1]
    }

    func upgradeCost(from level: Int) -> Int? {
        guard level < maxLevel else { return nil }
        return upgradeCosts[level - 1]
    }
}

enum EnemyType: CaseIterable {
    case small
    case medium
    case large

    var emoji: String {
        switch self {
        case .small: return "👾"
        case .medium: return "👹"
        case .large: return "🐲"
        }
    }

    var baseHealth: Int {
        switch self {
        case .small: return 3
        case .medium: return 6
        case .large: return 10
        }
    }

    var displayName: String {
        switch self {
        case .small: return "小型敵人"
        case .medium: return "中型敵人"
        case .large: return "大型敵人"
        }
    }
}

/// Handles background music playback for the game using a bundled audio file.
final class GameAudioManager {
    static let shared = GameAudioManager()
    private var player: AVAudioPlayer?
    private var prepared = false
    private(set) var isMuted = false

    private init() {}

    private func ensureSetup() {
        guard !prepared else { return }
        guard let url = Bundle.main.url(forResource: "music", withExtension: "mp3") else {
            print("⚠️ Background music file music.mp3 not found in bundle.")
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.prepareToPlay()
            self.player = player
            applyVolume()
            prepared = true
        } catch {
            print("⚠️ Failed to load background music:", error)
        }
    }

    func playBackgroundLoop() {
        ensureSetup()
        guard prepared, let player = player else { return }
        if !player.isPlaying {
            applyVolume()
            player.play()
        }
    }

    func stopBackgroundMusic() {
        player?.stop()
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        applyVolume()
    }

    private func applyVolume() {
        player?.volume = isMuted ? 0 : 0.8
    }
}

@MainActor
final class GameViewModel: ObservableObject {
    struct Enemy: Identifiable {
        let id = UUID()
        let type: EnemyType
        var pathIndex: Int
        var health: Int
        let maxHealth: Int
        var slowTicksRemaining: Int
    }

    struct Tower: Identifiable {
        let id = UUID()
        let position: Position
        let type: TowerType
        var level: Int
        var cooldown: Int
    }

    let rows = 7
    let columns = 5
    let tickDuration = 0.6

    @Published private(set) var enemies: [Enemy] = []
    @Published private(set) var towers: [Tower] = []
    @Published private(set) var hitMarkers: [Position: Int] = [:]
    @Published var coins = 8
    @Published var lives = 10
    @Published var wave = 1
    @Published var isPlacingTower = false
    @Published var isRunning = false
    @Published var isGameOver = false
    @Published var statusMessage = "點擊開始防禦！"
    @Published var selectedTowerType: TowerType = .archer
    @Published private(set) var focusedTowerID: Tower.ID?

    private var ticker: AnyCancellable?
    private var tickCount = 0
    private var enemiesToSpawn = 0
    private var enemiesSpawned = 0
    private var spawnInterval = 4

    private(set) var pathPositions: [Position]
    private let pathSet: Set<Position>

    init() {
        let path = GameViewModel.buildPath()
        self.pathPositions = path
        self.pathSet = Set(path)
    }

    deinit {
        ticker?.cancel()
    }

    var focusedTower: Tower? {
        guard let id = focusedTowerID, let index = towers.firstIndex(where: { $0.id == id }) else { return nil }
        return towers[index]
    }

    var canRemoveFocusedTower: Bool {
        focusedTower != nil
    }

    var canUpgradeFocusedTower: Bool {
        guard let tower = focusedTower, let cost = tower.type.upgradeCost(from: tower.level) else { return false }
        return coins >= cost
    }

    func startOrResumeGame() {
        if isGameOver {
            resetStateForNewGame()
        }
        if enemiesToSpawn == 0 && enemiesSpawned == 0 && enemies.isEmpty {
            prepareWave(for: wave)
        }
        statusMessage = "第 \(wave) 波來襲！"
        isRunning = true
        isGameOver = false
        startTicker()
    }

    func pauseGame() {
        guard isRunning else { return }
        isRunning = false
        statusMessage = "遊戲暫停"
        stopTicker()
    }

    func resetGame() {
        resetStateForNewGame()
        statusMessage = "已重置，點擊開始防禦！"
    }

    func selectTowerType(_ type: TowerType) {
        selectedTowerType = type
        if isPlacingTower {
            statusMessage = "選擇草地放置\(type.displayName) (💰\(type.buildCost))"
        } else {
            statusMessage = "已選擇 \(type.displayName)，點擊放置按鈕開始建造"
        }
    }

    func togglePlacementMode() {
        guard !isGameOver else { return }
        if isPlacingTower {
            isPlacingTower = false
            statusMessage = "取消放塔"
            return
        }
        let cost = selectedTowerType.buildCost
        guard coins >= cost else {
            statusMessage = "金幣不足，無法放置\(selectedTowerType.displayName)"
            return
        }
        focusedTowerID = nil
        isPlacingTower = true
        statusMessage = "選擇草地放置\(selectedTowerType.displayName) (💰\(cost))"
    }

    func canPlaceTower(at position: Position) -> Bool {
        guard !pathSet.contains(position) else { return false }
        return towers.first(where: { $0.position == position }) == nil
    }

    func handleTap(on position: Position) {
        guard isPlacingTower else { return }
        let cost = selectedTowerType.buildCost
        guard coins >= cost else {
            statusMessage = "金幣不足，無法放塔"
            isPlacingTower = false
            return
        }
        guard canPlaceTower(at: position) else {
            statusMessage = pathSet.contains(position) ? "道路上不能放塔" : "這裡已經有塔了"
            return
        }
        coins -= cost
        let newTower = Tower(position: position, type: selectedTowerType, level: 1, cooldown: 0)
        towers.append(newTower)
        focusedTowerID = newTower.id
        isPlacingTower = false
        statusMessage = "成功放置\(selectedTowerType.displayName)！"
    }

    func inspectTile(at position: Position) {
        if let towerIndex = towers.firstIndex(where: { $0.position == position }) {
            let tower = towers[towerIndex]
            focusedTowerID = tower.id
            let stats = stats(for: tower)
            let interval = formattedSeconds(Double(stats.cooldownTicks + 1) * tickDuration)
            let remaining = formattedSeconds(Double(tower.cooldown) * tickDuration)
            let slowText = stats.slowTicks > 0 ? "｜緩速 \(stats.slowTicks) 回合" : ""
            statusMessage = "\(tower.type.emoji) \(tower.type.displayName) Lv\(tower.level)｜攻擊力 \(stats.damage)｜射程 \(stats.range) 格｜攻速 每 \(interval) 秒｜冷卻剩 \(remaining) 秒\(slowText)"
            return
        }
        focusedTowerID = nil
        if let enemy = enemy(at: position) {
            let slowText = enemy.slowTicksRemaining > 0 ? "｜被冰凍 \(enemy.slowTicksRemaining) 回合" : ""
            statusMessage = "\(enemy.type.emoji) \(enemy.type.displayName) 生命 \(enemy.health)/\(enemy.maxHealth)\(slowText)"
            return
        }
        if pathSet.contains(position) {
            statusMessage = "這是敵人行走的道路"
        } else {
            statusMessage = coins >= selectedTowerType.buildCost ? "空地，點擊放置可建造\(selectedTowerType.displayName)" : "空地，但金幣不足以建造"
        }
    }

    func helpText(for position: Position) -> String {
        if let towerIndex = towers.firstIndex(where: { $0.position == position }) {
            let tower = towers[towerIndex]
            let stats = stats(for: tower)
            let interval = formattedSeconds(Double(stats.cooldownTicks + 1) * tickDuration)
            let remaining = formattedSeconds(Double(tower.cooldown) * tickDuration)
            let slowText = stats.slowTicks > 0 ? "\n緩速：敵人停滯 \(stats.slowTicks) 回合" : ""
            let upgradeText: String
            if let cost = tower.type.upgradeCost(from: tower.level) {
                upgradeText = "\n升級費用：💰\(cost)"
            } else {
                upgradeText = "\n已達最高等級"
            }
            return "\(tower.type.emoji) \(tower.type.displayName) Lv\(tower.level)\n攻擊力：\(stats.damage)\n射程：\(stats.range) 格\n攻擊頻率：每 \(interval) 秒\n冷卻剩餘：\(remaining) 秒\(slowText)\(upgradeText)"
        }
        if let enemy = enemy(at: position) {
            let slowText = enemy.slowTicksRemaining > 0 ? "\n狀態：被冰凍 \(enemy.slowTicksRemaining) 回合" : ""
            return "\(enemy.type.emoji) \(enemy.type.displayName)\n生命：\(enemy.health)/\(enemy.maxHealth)\(slowText)"
        }
        if pathSet.contains(position) {
            return "敵人路線"
        }
        let cost = selectedTowerType.buildCost
        return coins >= cost ? "空地\n可建造：\(selectedTowerType.displayName) (💰\(cost))" : "空地\n金幣不足以建造"
    }

    func enemyHealth(at position: Position) -> Int? {
        enemy(at: position)?.health
    }

    func towerLevel(at position: Position) -> Int? {
        towers.first(where: { $0.position == position })?.level
    }

    func isHitFlashing(position: Position) -> Bool {
        hitMarkers[position] != nil
    }

    func tileSymbol(for position: Position) -> String? {
        if let enemy = enemy(at: position) {
            return enemyEmoji(for: enemy)
        }
        if let tower = towers.first(where: { $0.position == position }) {
            return tower.type.emoji
        }
        return nil
    }

    func upgradeButtonLabel() -> String {
        guard let tower = focusedTower else { return "選取塔升級" }
        if let cost = tower.type.upgradeCost(from: tower.level) {
            return "升級至 Lv\(tower.level + 1) (💰\(cost))"
        }
        return "已達最高等"
    }

    func upgradeFocusedTower() {
        guard let id = focusedTowerID, let index = towers.firstIndex(where: { $0.id == id }) else {
            statusMessage = "請先點擊想升級的塔"
            return
        }
        let tower = towers[index]
        guard let cost = tower.type.upgradeCost(from: tower.level) else {
            statusMessage = "\(tower.type.displayName) 已達最高等級"
            return
        }
        guard coins >= cost else {
            statusMessage = "金幣不足，升級需要 \(cost) 金幣"
            return
        }
        coins -= cost
        towers[index].level += 1
        statusMessage = "\(tower.type.displayName) 升級到 Lv\(tower.level + 1)!"
    }

    func removeFocusedTower() {
        guard let id = focusedTowerID, let index = towers.firstIndex(where: { $0.id == id }) else {
            statusMessage = "請先點擊想拆除的塔"
            return
        }
        let tower = towers.remove(at: index)
        focusedTowerID = nil
        let refund = refundValue(for: tower)
        if refund > 0 {
            coins += refund
            statusMessage = "已拆除\(tower.type.displayName)，返還 \(refund) 金幣"
        } else {
            statusMessage = "已拆除\(tower.type.displayName)"
        }
    }

    private func resetStateForNewGame() {
        stopTicker()
        enemies = []
        towers = []
        coins = 8
        lives = 10
        wave = 1
        isPlacingTower = false
        isRunning = false
        isGameOver = false
        statusMessage = "點擊開始防禦！"
        tickCount = 0
        enemiesToSpawn = 0
        enemiesSpawned = 0
        spawnInterval = 4
        selectedTowerType = .archer
        focusedTowerID = nil
        hitMarkers = [:]
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Timer.publish(every: tickDuration, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        guard isRunning else { return }
        tickCount += 1
        spawnEnemyIfNeeded()
        advanceEnemies()
        towersAttack()
        cleanupDefeatedEnemies()
        decayHitMarkers()
        checkWaveProgress()
        if lives <= 0 {
            handleGameOver()
        }
    }

    private func spawnEnemyIfNeeded() {
        guard enemiesSpawned < enemiesToSpawn else { return }
        if tickCount == 1 || tickCount % spawnInterval == 0 {
            let type = enemyTypeForCurrentWave()
            let baseHealth = type.baseHealth + max(wave - 1, 0)
            enemies.append(Enemy(type: type,
                                 pathIndex: -1,
                                 health: baseHealth,
                                 maxHealth: baseHealth,
                                 slowTicksRemaining: 0))
            enemiesSpawned += 1
        }
    }

    private func advanceEnemies() {
        var escaped = 0
        enemies = enemies.compactMap { enemy in
            var updated = enemy
            if updated.slowTicksRemaining > 0 {
                updated.slowTicksRemaining -= 1
                return updated
            }
            updated.pathIndex += 1
            if updated.pathIndex >= pathPositions.count {
                escaped += 1
                return nil
            }
            return updated
        }
        if escaped > 0 {
            lives -= escaped
            statusMessage = "有 \(escaped) 個敵人突破防線！"
        }
    }

    private func towersAttack() {
        guard !enemies.isEmpty else { return }
        for index in towers.indices {
            if towers[index].cooldown > 0 {
                towers[index].cooldown -= 1
                continue
            }
            let tower = towers[index]
            guard let targetIndex = targetEnemyIndex(for: tower) else { continue }
            let stats = stats(for: tower)
            enemies[targetIndex].health -= stats.damage
            if stats.slowTicks > 0 {
                enemies[targetIndex].slowTicksRemaining = max(enemies[targetIndex].slowTicksRemaining, stats.slowTicks)
            }
            if let position = enemyPosition(for: enemies[targetIndex]) {
                registerHit(at: position)
            }
            towers[index].cooldown = stats.cooldownTicks
        }
    }

    private func stats(for tower: Tower) -> TowerLevelStats {
        tower.type.stats(for: tower.level)
    }

    private func refundValue(for tower: Tower) -> Int {
        var total = tower.type.buildCost
        if tower.level > 1 {
            for lvl in 1..<(tower.level) {
                if let cost = tower.type.upgradeCost(from: lvl) {
                    total += cost
                }
            }
        }
        return Int(Double(total) * 0.6)
    }

    private func targetEnemyIndex(for tower: Tower) -> Int? {
        let stats = stats(for: tower)
        var bestIndex: Int?
        var bestProgress = -1

        for (index, enemy) in enemies.enumerated() {
            guard let position = enemyPosition(for: enemy) else { continue }
            let distance = abs(position.row - tower.position.row) + abs(position.col - tower.position.col)
            guard distance <= stats.range else { continue }
            if enemy.pathIndex > bestProgress {
                bestProgress = enemy.pathIndex
                bestIndex = index
            }
        }
        return bestIndex
    }

    private func enemyTypeForCurrentWave() -> EnemyType {
        if wave < 4 {
            return .small
        } else if wave < 7 {
            return Bool.random() ? .small : .medium
        } else {
            let roll = Int.random(in: 0..<10)
            switch roll {
            case 0...3: return .small
            case 4...7: return .medium
            default: return .large
            }
        }
    }

    private func cleanupDefeatedEnemies() {
        var reward = 0
        var defeated = 0
        enemies.removeAll { enemy in
            if enemy.health <= 0 {
                reward += 2
                defeated += 1
                return true
            }
            return false
        }

        if reward > 0 {
            coins += reward
            statusMessage = "擊退 \(defeated) 名敵人，獲得 \(reward) 金幣！"
        }
    }

    private func decayHitMarkers() {
        guard !hitMarkers.isEmpty else { return }
        var updated: [Position: Int] = [:]
        for (position, ttl) in hitMarkers {
            let next = ttl - 1
            if next > 0 {
                updated[position] = next
            }
        }
        withAnimation(.easeOut(duration: 0.25)) {
            hitMarkers = updated
        }
    }

    private func checkWaveProgress() {
        guard enemiesSpawned >= enemiesToSpawn, enemies.isEmpty else { return }
        let completedWave = wave
        coins += 3 + completedWave
        statusMessage = "第 \(completedWave) 波守住了！"
        wave += 1
        prepareWave(for: wave)
    }

    private func handleGameOver() {
        isRunning = false
        isGameOver = true
        stopTicker()
        let cleared = max(wave - 1, 0)
        statusMessage = "遊戲結束！共抵擋 \(cleared) 波。"
    }

    private func prepareWave(for wave: Int) {
        tickCount = 0
        enemiesSpawned = 0
        enemiesToSpawn = 5 + (wave - 1) * 2
        spawnInterval = max(4 - (wave / 3), 1)
    }

    private func enemy(at position: Position) -> Enemy? {
        enemies.first { enemyPosition(for: $0) == position }
    }

    private func enemyPosition(for enemy: Enemy) -> Position? {
        guard enemy.pathIndex >= 0 && enemy.pathIndex < pathPositions.count else { return nil }
        return pathPositions[enemy.pathIndex]
    }

    private func registerHit(at position: Position) {
        withAnimation(.easeOut(duration: 0.25)) {
            hitMarkers[position] = 3
        }
    }

    private func formattedSeconds(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func enemyEmoji(for enemy: Enemy) -> String {
        enemy.type.emoji
    }

    /// Predefined winding path the enemies will use.
    private static func buildPath() -> [Position] {
        [
            Position(row: 3, col: 0),
            Position(row: 3, col: 1),
            Position(row: 3, col: 2),
            Position(row: 2, col: 2),
            Position(row: 1, col: 2),
            Position(row: 1, col: 3),
            Position(row: 1, col: 4),
            Position(row: 2, col: 4),
            Position(row: 3, col: 4),
            Position(row: 4, col: 4),
            Position(row: 5, col: 4),
            Position(row: 6, col: 4)
        ]
    }
}

struct ContentView: View {
    @StateObject private var viewModel = GameViewModel()
    @State private var isMuted = false

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: viewModel.columns)

        return VStack(spacing: 18) {
            Text("🏯 Emoji 塔防 🧠")
                .font(.title)
                .fontWeight(.semibold)

            HStack(spacing: 20) {
                Text("❤️ \(viewModel.lives)")
                Text("💰 \(viewModel.coins)")
                Text("Wave \(viewModel.wave)")
            }
            .font(.headline)

            Text(viewModel.statusMessage)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            towerSelector

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(0..<viewModel.rows, id: \.self) { row in
                    ForEach(0..<viewModel.columns, id: \.self) { column in
                        let position = Position(row: row, col: column)
                        tileView(at: position)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.white.opacity(0.12))
            )
            .padding(.horizontal)

            controls
        }
        .padding(.top, 32)
        .padding([.horizontal, .bottom])
        .onAppear {
            GameAudioManager.shared.playBackgroundLoop()
            GameAudioManager.shared.setMuted(isMuted)
        }
        .onDisappear {
            GameAudioManager.shared.stopBackgroundMusic()
        }
        .background(
            LinearGradient(colors: [.mint.opacity(0.2), .blue.opacity(0.15)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private var towerSelector: some View {
        HStack(spacing: 16) {
            ForEach(TowerType.allCases) { type in
                Button(action: {
                    viewModel.selectTowerType(type)
                }) {
                    VStack(spacing: 6) {
                        Text(type.emoji)
                            .font(.title2)
                        Text(type.displayName)
                            .font(.caption)
                        Text("💰\(type.buildCost)")
                            .font(.caption2)
                    }
                    .padding(12)
                    .frame(width: 90)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(viewModel.selectedTowerType == type ? Color.orange.opacity(0.35) : Color.white.opacity(0.08))
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal)
    }

    @ViewBuilder
    private func tileView(at position: Position) -> some View {
        let isPath = viewModel.pathPositions.contains(position)
        let highlight = viewModel.isPlacingTower && viewModel.canPlaceTower(at: position)
        let symbol = viewModel.tileSymbol(for: position)

        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(isPath ? Color.brown.opacity(0.28) : Color.green.opacity(0.28))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(highlight ? Color.blue : Color.clear, lineWidth: 3)
                        .animation(.easeInOut(duration: 0.2), value: highlight)
                )
            if let symbol {
                Text(symbol)
                    .font(.system(size: 30))
            }
            if let level = viewModel.towerLevel(at: position) {
                Text("Lv\(level)")
                    .font(.caption2)
                    .padding(4)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(6)
                    .foregroundStyle(.white)
                    .offset(y: -18)
            }
            if let health = viewModel.enemyHealth(at: position) {
                Text("❤️\(health)")
                    .font(.caption2)
                    .padding(4)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(6)
                    .foregroundStyle(.white)
                    .offset(y: 20)
            }
            if viewModel.isHitFlashing(position: position) {
                Text("💥")
                    .font(.system(size: 26))
                    .transition(.scale)
            }
        }
        .frame(width: 58, height: 58)
        .contentShape(Rectangle())
        .onTapGesture {
            if viewModel.isPlacingTower {
                viewModel.handleTap(on: position)
            } else {
                viewModel.inspectTile(at: position)
            }
        }
        .help(viewModel.helpText(for: position))
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Button(action: {
                    if viewModel.isRunning {
                        viewModel.pauseGame()
                    } else {
                        viewModel.startOrResumeGame()
                    }
                }) {
                    Text(viewModel.isRunning ? "暫停" : (viewModel.isGameOver ? "再玩一次" : "開始"))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.accentColor.opacity(0.25))
                        .cornerRadius(12)
                }

                Button(action: {
                    viewModel.togglePlacementMode()
                }) {
                    Text("放置\(viewModel.selectedTowerType.emoji)塔 (💰\(viewModel.selectedTowerType.buildCost))")
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(viewModel.isPlacingTower ? Color.blue.opacity(0.25) : Color.orange.opacity(0.25))
                        .cornerRadius(12)
                }
                .disabled(viewModel.coins < viewModel.selectedTowerType.buildCost && !viewModel.isPlacingTower)

                Button(action: {
                    viewModel.resetGame()
                }) {
                    Text("重置")
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.gray.opacity(0.25))
                        .cornerRadius(12)
                }

                Button(action: {
                    isMuted.toggle()
                    GameAudioManager.shared.setMuted(isMuted)
                }) {
                    Text(isMuted ? "🔇" : "🔊")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.purple.opacity(0.25))
                        .cornerRadius(12)
                }
            }

            HStack(spacing: 14) {
                Button(action: {
                    viewModel.upgradeFocusedTower()
                }) {
                    Text(viewModel.upgradeButtonLabel())
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.yellow.opacity(0.25))
                        .cornerRadius(12)
                }
                .disabled(!viewModel.canUpgradeFocusedTower)

                Button(action: {
                    viewModel.removeFocusedTower()
                }) {
                    Text("拆除塔 (返還60%)")
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.25))
                        .cornerRadius(12)
                }
                .disabled(!viewModel.canRemoveFocusedTower)

                if let tower = viewModel.focusedTower {
                    Text("已選塔：\(tower.type.displayName) Lv\(tower.level)")
                        .font(.caption)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
