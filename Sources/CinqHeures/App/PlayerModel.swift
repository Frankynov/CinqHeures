import AVFoundation
import CinqHeuresCore
import MediaPlayer
import Observation

/// Plays an episode, starting exactly where a film's review begins.
///
/// The website starts the audio first and seeks afterwards, so on a slow connection it often plays
/// from the start. Here nothing plays until the file is ready *and* the seek has landed.
@MainActor @Observable
final class PlayerModel {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var episode: Episode?
    /// The segment the user asked for, shown in the player bar until playback moves past it.
    private(set) var requestedSegment: Segment?
    private(set) var phase: Phase = .idle
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    /// True while 5heures.be's server is slow to hand over the part being played (it can take a
    /// minute the first time a file's later part is asked for, then it's fast).
    private(set) var serverIsSlow = false
    /// When the server started being slow, for the elapsed time in the status line.
    private(set) var slowSince: Date?
    /// Changes only when playback crosses into another segment, so the lists can follow it without
    /// redrawing twice a second.
    private(set) var currentSegmentID: Int?
    /// Bumped when saved positions are forgotten, so "Continuer l'écoute" redraws (the positions
    /// themselves live in UserDefaults, which views can't observe).
    private(set) var progressRevision = 0
    var rate: Float = 1 {
        didSet { if isPlaying { player.rate = rate }; UserDefaults.standard.set(rate, forKey: "rate") }
    }

    /// Remembered between launches, like the speed.
    var volume: Float = 1 {
        didSet { player.volume = volume; UserDefaults.standard.set(volume, forKey: "volume") }
    }

    static let speeds: [Float] = [0.8, 1, 1.15, 1.25, 1.5, 1.75, 2]
    static let jump: Double = 15

    private let player = AVPlayer()
    private let loader = RangeLoader()
    private var loadTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var lastSaved = 0.0
    private var stalledSince: Date?
    private var recoveries = 0
    /// Bumped by every new request to play. A seek still finishing for an older request checks it
    /// and stays silent, so clicking a second review quickly can't start the audio in the wrong place.
    private var generation = 0

    init() {
        let saved = UserDefaults.standard.float(forKey: "rate")
        if saved > 0 { rate = saved }
        if UserDefaults.standard.object(forKey: "volume") != nil {
            volume = UserDefaults.standard.float(forKey: "volume")
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        setUpRemoteCommands()
        loader.onSlowChange = { [weak self] slow in
            Task { @MainActor in
                self?.serverIsSlow = slow
                self?.slowSince = slow ? (self?.slowSince ?? Date()) : nil
            }
        }
    }

    // MARK: Starting

    /// Plays `episode` from `segment` (or, with none, from where it was left, or the start).
    func play(_ episode: Episode, from segment: Segment? = nil) {
        let start = segment.map { $0.start ?? 0 } ?? resumePoint(for: episode)
        requestedSegment = segment
        recoveries = 0
        serverIsSlow = false
        slowSince = nil
        if self.episode?.id == episode.id, phase == .ready {
            generation += 1
            let current = generation
            Task { await jumpAndPlay(to: start, generation: current) }
            return
        }
        load(episode, start: start)
    }

    /// Stops and unloads whatever is playing (the player bar goes back to "Rien en lecture").
    func stop() {
        loadTask?.cancel()
        generation += 1
        player.pause()
        player.replaceCurrentItem(with: nil)
        loader.clear()
        episode = nil
        requestedSegment = nil
        phase = .idle
        isPlaying = false
        currentTime = 0
        duration = 0
        currentSegmentID = nil
        serverIsSlow = false
        slowSince = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func retry() {
        guard let episode else { return }
        load(episode, start: requestedSegment.map { $0.start ?? 0 } ?? currentTime)
    }

    private func load(_ episode: Episode, start: Double) {
        loadTask?.cancel()
        generation += 1
        let current = generation
        player.pause()
        self.episode = episode
        phase = .loading
        isPlaying = false
        currentTime = start
        duration = 0
        currentSegmentID = nil
        loadTask = Task {
            var lastError = "Le fichier audio n'a pas pu être chargé."
            for attempt in 0..<3 {
                if Task.isCancelled { return }
                if attempt > 0 { try? await Task.sleep(for: .seconds(Double(attempt) * 1.5)) }
                // 5heures.be's own audio server needs the patient loader; Ausha's doesn't.
                let item = AVPlayerItem(asset: episode.series.isOnSite ? loader.asset(for: episode.audioURL)
                                                                       : AVURLAsset(url: episode.audioURL))
                player.replaceCurrentItem(with: item)
                do {
                    try await Self.waitUntilReady(item)
                } catch {
                    lastError = error.localizedDescription
                    continue
                }
                if Task.isCancelled { return }
                observeEnd(of: item)
                duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
                phase = .ready
                await jumpAndPlay(to: start, generation: current)
                return
            }
            if !Task.isCancelled { phase = .failed(lastError) }
        }
    }

    /// Waits for the file's header to be read. A request that stalls is given up after 15 seconds
    /// so the caller can ask again, which is what fixes the CDN's occasional 503.
    private static func waitUntilReady(_ item: AVPlayerItem) async throws {
        for _ in 0..<300 {
            try Task.checkCancellation()
            switch item.status {
            case .readyToPlay: return
            case .failed: throw item.error ?? CocoaError(.fileReadUnknown)
            default: try await Task.sleep(for: .milliseconds(50))
            }
        }
        throw URLError(.timedOut)
    }

    /// Seeks, checks it landed, and only then plays, unless a newer request came in meanwhile.
    private func jumpAndPlay(to seconds: Double, generation requested: Int) async {
        if seconds > 0.5 {
            for _ in 0..<2 {
                await seekExactly(to: seconds)
                if abs(player.currentTime().seconds - seconds) < 5 { break }
            }
        } else if player.currentTime().seconds > 0.5 {
            await seekExactly(to: 0)
        }
        guard requested == generation else { return }
        tick(player.currentTime().seconds)
        player.playImmediately(atRate: rate)
        isPlaying = true
        updateNowPlaying()
    }

    private func seekExactly(to seconds: Double) async {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Controls

    func togglePlayPause() {
        guard phase == .ready else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            save()
        } else {
            // Finished: play again from the start rather than doing nothing.
            if duration > 0, currentTime >= duration - 1 { seek(to: 0) }
            player.playImmediately(atRate: rate)
            isPlaying = true
        }
        updateNowPlaying()
    }

    func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    func seek(to seconds: Double) {
        guard phase == .ready else { return }
        let target = min(max(0, seconds), duration > 0 ? duration : seconds)
        currentTime = target
        Task {
            await seekExactly(to: target)
            tick(player.currentTime().seconds)
            updateNowPlaying()
        }
    }

    // MARK: Following playback

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        watchForStall()
        loader.playhead(seconds: seconds, duration: duration)
        currentTime = seconds
        if let item = player.currentItem, item.duration.seconds.isFinite, item.duration.seconds != duration {
            duration = item.duration.seconds
        }
        let segment = episode?.segments.last { ($0.start ?? .infinity) <= seconds + 0.5 }
        if segment?.id != currentSegmentID {
            currentSegmentID = segment?.id
            updateNowPlaying()      // the title in Control Centre follows the film being discussed
        }
        if let requested = requestedSegment, let segment, segment.id != requested.id, seconds > (requested.start ?? 0) + 5 {
            requestedSegment = nil
        }
        if isPlaying, seconds - lastSaved > 5 || seconds < lastSaved { save() }
    }

    /// If playback is stuck for no reason the loader knows about (it reports a slow server itself),
    /// load the file again and carry on from here.
    private func watchForStall() {
        guard isPlaying, phase == .ready, let item = player.currentItem else { stalledSince = nil; return }
        let stuck = (player.timeControlStatus == .waitingToPlayAtSpecifiedRate && !serverIsSlow) || item.status == .failed
        guard stuck else { stalledSince = nil; recoveries = 0; return }
        let since = stalledSince ?? Date()
        stalledSince = since
        guard Date().timeIntervalSince(since) > 20, let episode else { return }
        stalledSince = nil
        guard recoveries < 3 else {
            phase = .failed("La lecture est bloquée : le serveur ne répond pas.")
            isPlaying = false
            player.pause()
            return
        }
        recoveries += 1
        load(episode, start: player.currentTime().seconds.isFinite ? player.currentTime().seconds : currentTime)
    }

    var currentSegment: Segment? {
        guard let id = currentSegmentID else { return nil }
        return episode?.segments.first { $0.id == id }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.forget()
                self.updateNowPlaying()
            }
        }
    }

    // MARK: Remembering where you were

    private static let positionsKey = "positions"

    private func resumePoint(for episode: Episode) -> Double {
        let positions = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Double] ?? [:]
        guard let saved = positions[String(episode.id)], saved > 10 else { return 0 }
        return saved
    }

    func hasProgress(_ episode: Episode) -> Bool { resumePoint(for: episode) > 0 }

    private static let datesKey = "positionDates"

    private func save() {
        guard let episode, phase == .ready else { return }
        lastSaved = currentTime
        var positions = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Double] ?? [:]
        positions[String(episode.id)] = currentTime
        UserDefaults.standard.set(positions, forKey: Self.positionsKey)
        var dates = UserDefaults.standard.dictionary(forKey: Self.datesKey) as? [String: Double] ?? [:]
        dates[String(episode.id)] = Date().timeIntervalSince1970
        UserDefaults.standard.set(dates, forKey: Self.datesKey)
        if duration > 0 {
            var lengths = UserDefaults.standard.dictionary(forKey: Self.lengthsKey) as? [String: Double] ?? [:]
            lengths[String(episode.id)] = duration
            UserDefaults.standard.set(lengths, forKey: Self.lengthsKey)
        }
    }

    private static let lengthsKey = "episodeLengths"

    /// The length of an episode that has been played here (the site doesn't say how long they are).
    func duration(of episode: Episode) -> Double? {
        (UserDefaults.standard.dictionary(forKey: Self.lengthsKey) as? [String: Double])?[String(episode.id)]
    }

    /// Episodes started and not finished: (episode id, seconds in), most recently listened first.
    func unfinished() -> [(id: Int, seconds: Double)] {
        let positions = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Double] ?? [:]
        let dates = UserDefaults.standard.dictionary(forKey: Self.datesKey) as? [String: Double] ?? [:]
        return positions.compactMap { key, seconds in Int(key).map { ($0, seconds) } }
            .filter { $0.1 > 60 }      // a minute in: a brief sample isn't "in progress"
            .sorted { (dates[String($0.0)] ?? 0) > (dates[String($1.0)] ?? 0) }
            .map { (id: $0.0, seconds: $0.1) }
    }

    /// Forgets where every episode was left (and their lengths): "Continuer l'écoute" empties.
    func forgetAllProgress() {
        for key in [Self.positionsKey, Self.datesKey, Self.lengthsKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        lastSaved = 0
        progressRevision += 1
    }

    private func forget() {
        guard let episode else { return }
        var positions = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Double] ?? [:]
        positions[String(episode.id)] = nil
        UserDefaults.standard.set(positions, forKey: Self.positionsKey)
        progressRevision += 1
    }

    // MARK: Media keys and the Now Playing widget

    /// The command centre doesn't promise which thread a handler runs on, so each one hops to the main actor.
    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == false { self?.togglePlayPause() } }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == true { self?.togglePlayPause() } }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        for (command, seconds) in [(center.skipBackwardCommand, -Self.jump), (center.skipForwardCommand, Self.jump)] {
            command.preferredIntervals = [NSNumber(value: Self.jump)]
            command.addTarget { [weak self] _ in
                Task { @MainActor in self?.skip(by: seconds) }
                return .success
            }
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let episode else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: (currentSegment?.title ?? episode.title),
            MPMediaItemPropertyArtist: episode.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
        ]
    }
}
