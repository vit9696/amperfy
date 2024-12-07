//
//  BackendAudioPlayer.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 09.03.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import Foundation
import AVFoundation
import AudioStreaming
import UIKit
import os.log
import PromiseKit

protocol BackendAudioPlayerNotifiable {
    func didElapsedTimeChange()
    func didLyricsTimeChange(time: CMTime) // high refresh count
    func stop()
    func playPrevious()
    func playNext()
    func didItemFinishedPlaying()
    func notifyItemPreparationFinished()
    func notifyErrorOccured(error: Error)
}

enum PlayType {
    case stream
    case cache
}

enum BackendAudioQueueType {
    case play
    case queue
}

typealias NextPlayablePreloadCallback = () -> AbstractPlayable?

public typealias CreateAVPlayerCallback = () -> AudioStreaming.AudioPlayer
public typealias TriggerReinsertPlayableCallback = () -> Void

class BackendAudioPlayer: NSObject {
    
    private let playableDownloader: DownloadManageable
    private let cacheProxy: PlayableFileCachable
    private let backendApi: BackendApi
    private let userStatistics: UserStatistics
    private let createAVPlayerCB: CreateAVPlayerCallback
    private var player: AudioStreaming.AudioPlayer
    private let eventLogger: EventLogger
    private let networkMonitor: NetworkMonitorFacade
    private let updateElapsedTimeInterval = 0.5
    private var elapsedTimeTimer: Timer?
    private var nextPreloadedPlayable: AbstractPlayable?
    public var nextPlayablePreloadCB: NextPlayablePreloadCallback?
    private let updateLyricsTimeInterval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
    private let fileManager = CacheFileManager.shared
    private var audioSessionHandler: AudioSessionHandler
    private var isTriggerReinsertPlayableAllowed = true
    private var wasPlayingBeforeErrorOccured: Bool = false

    private var userDefinedPlaybackRate: PlaybackRate = .one
    
    public var isOfflineMode: Bool = false
    public var isAutoCachePlayedItems: Bool = true
    public var triggerReinsertPlayableCB: TriggerReinsertPlayableCallback?
    public var streamingMaxBitrates: StreamingMaxBitrates = .init() {
        didSet {
            let streamingMaxBitrate = streamingMaxBitrates.getActive(networkMonitor: self.networkMonitor)
            os_log(.default, "Update Streaming Max Bitrate: %s %s", streamingMaxBitrate.description, (self.playType == .stream) ? "(active)" : "")
            if self.playType == .stream {
                //player.currentItem?.preferredPeakBitRate = streamingMaxBitrate.asBitsPerSecondAV
            }
        }
    }
    public private(set) var isPlaying: Bool = false
    public private(set) var isErrorOccured: Bool = false
    public private(set) var playType: PlayType?
    
    var responder: BackendAudioPlayerNotifiable?
    var isStopped: Bool {
        return playType == nil
    }
    var elapsedTime: Double {
        return player.progress
    }
    var duration: Double {
        let duration = player.duration
        guard duration.isFinite else { return 0.0 }
        return duration
    }
    var playbackRate: PlaybackRate {
        return userDefinedPlaybackRate
    }
    var canBeContinued: Bool {
        return player.state == .paused
    }
    
    init(createAVPlayerCB: @escaping CreateAVPlayerCallback, audioSessionHandler: AudioSessionHandler, eventLogger: EventLogger, backendApi: BackendApi, networkMonitor: NetworkMonitorFacade, playableDownloader: DownloadManageable, cacheProxy: PlayableFileCachable, userStatistics: UserStatistics) {
        self.createAVPlayerCB = createAVPlayerCB
        self.player = createAVPlayerCB()
        self.audioSessionHandler = audioSessionHandler
        self.backendApi = backendApi
        self.networkMonitor = networkMonitor
        self.eventLogger = eventLogger
        self.playableDownloader = playableDownloader
        self.cacheProxy = cacheProxy
        self.userStatistics = userStatistics
        
        super.init()
        
        initAVPlayer()
    }
    
    private func initAVPlayer() {
        player = createAVPlayerCB()
        player.delegate = self
    }
    
    @objc private func itemFinishedPlaying() {
        responder?.didItemFinishedPlaying()
    }
    
    @objc private func itemPlaybackStalled(_ notification: Notification) {
        eventLogger.debug(topic: "Playback stalled", message: "Playback stalled")
        player.pause()
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) {
            if self.isPlaying {
                //self.player.play()
            }
        }
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if let item = object as? AVPlayerItem {
            if keyPath == "status" {
                if item.status == .failed,
                   let statusError = item.error {
                    handleError(error: statusError)
                } else {
                    isTriggerReinsertPlayableAllowed = true
                    isErrorOccured = false
                }
            }
        }
    }
    
    private func handleError(error: Error) {
        isErrorOccured = true
        wasPlayingBeforeErrorOccured = isPlaying
        pause()
        initAVPlayer()
        eventLogger.report(topic: "Player Status", error: error)
        responder?.notifyErrorOccured(error: error)
        if isTriggerReinsertPlayableAllowed {
            isTriggerReinsertPlayableAllowed = false
            triggerReinsertPlayableCB?()
        }
    }
    
    func continuePlay() {
        isPlaying = true
        startElapsedTimeTimer()
        player.resume()
    }
    
    func pause() {
        isPlaying = false
        //stopElapsedTimeTimer()
        player.pause()
    }
    
    func stop() {
        isPlaying = false
        stopElapsedTimeTimer()
        clearPlayer()
    }
    
    func setPlaybackRate(_ newValue: PlaybackRate) {
        userDefinedPlaybackRate = newValue
        player.rate = Float(newValue.asDouble)
    }
    
    func seek(toSecond: Double) {
        player.seek(to: toSecond)
    }
    
    func requestToPlay(playable: AbstractPlayable, playbackRate: PlaybackRate, autoStartPlayback: Bool) {
        userDefinedPlaybackRate = playbackRate

        if let nextPreloadedPlayable = nextPreloadedPlayable, nextPreloadedPlayable == playable {
            // Do nothing next preloaded playable has already been queued to player
            self.nextPreloadedPlayable = nil
        } else {
            if let relFilePath = playable.relFilePath,
               fileManager.fileExits(relFilePath: relFilePath) {
                insertCachedPlayable(playable: playable)
                if (!self.isErrorOccured && autoStartPlayback) || (self.isErrorOccured && self.wasPlayingBeforeErrorOccured) {
                    self.continuePlay()
                } else {
                    isPlaying = false
                }
            } else if !isOfflineMode{
                firstly {
                    insertStreamPlayable(playable: playable)
                }.done {
                    if self.isAutoCachePlayedItems {
                        self.playableDownloader.download(object: playable)
                    }
                    if (!self.isErrorOccured && autoStartPlayback) || (self.isErrorOccured && self.wasPlayingBeforeErrorOccured) {
                        self.continuePlay()
                    } else {
                        self.isPlaying = false
                    }
                    self.responder?.notifyItemPreparationFinished()
                }.catch { error in
                    self.responder?.notifyErrorOccured(error: error)
                    self.responder?.notifyItemPreparationFinished()
                    self.eventLogger.report(topic: "Player", error: error)
                }
            } else {
                clearPlayer()
            }
        }
        
        self.responder?.notifyItemPreparationFinished()
        startElapsedTimeTimer()
    }
    
    private func reactToIncompatibleContentType(contentType: String, playableDisplayTitle: String) {
        clearPlayer()
        eventLogger.info(topic: "Player Info", statusCode: .playerError, message: "Content type \"\(contentType)\" of \"\(playableDisplayTitle)\" is not playable via Amperfy. Activating transcoding in Settings could resolve this issue.", displayPopup: true)
        self.responder?.notifyItemPreparationFinished()
    }
    
    private func clearPlayer() {
        playType = nil
        player.stop()
        stopElapsedTimeTimer()
    }
    
    private func insertCachedPlayable(playable: AbstractPlayable, queueType: BackendAudioQueueType = .play) {
        guard let fileURL = cacheProxy.getFileURL(forPlayable: playable) else {
            return
        }
        os_log(.default, "Play item: %s", playable.displayString)
        playType = .cache
        if playable.isSong { userStatistics.playedSong(isPlayedFromCache: true) }
        insert(playable: playable, withUrl: fileURL, queueType: queueType)
    }
    
    private func insertStreamPlayable(playable: AbstractPlayable, queueType: BackendAudioQueueType = .play) -> Promise<Void> {
        let streamingMaxBitrate = streamingMaxBitrates.getActive(networkMonitor: self.networkMonitor)
        return firstly {
            return backendApi.generateUrl(forStreamingPlayable: playable, maxBitrate: streamingMaxBitrate)
        }.get { streamUrl in
            os_log(.default, "Stream item (%s): %s", streamingMaxBitrate.description, playable.displayString)
            self.playType = .stream
            if playable.isSong { self.userStatistics.playedSong(isPlayedFromCache: false) }
            self.insert(playable: playable, withUrl: streamUrl, queueType: queueType, streamingMaxBitrate: streamingMaxBitrate)
        }.asVoid()
    }

    private func insert(playable: AbstractPlayable, withUrl url: URL, queueType: BackendAudioQueueType, streamingMaxBitrate: StreamingMaxBitratePreference = .noLimit) {
        audioSessionHandler.configureBackgroundPlayback()
        switch queueType {
        case .play:
            player.play(url: url)
        case .queue:
            player.queue(url: url)
        }
    }
        
    private func startElapsedTimeTimer() {
        if elapsedTimeTimer == nil {
            os_log(.default, "Player elapsed time start")
            elapsedTimeTimer = Timer.scheduledTimer(timeInterval: updateElapsedTimeInterval, target: self, selector: #selector(elapsedTimeTimerTicked), userInfo: nil, repeats: true)
        }
    }
    
    private func stopElapsedTimeTimer() {
        if let timer = elapsedTimeTimer {
            os_log(.default, "Player elapsed time stop")
            timer.invalidate()
            elapsedTimeTimer = nil
        }
    }
    
    @objc func elapsedTimeTimerTicked() {
        self.responder?.didElapsedTimeChange()
        if nextPreloadedPlayable == nil, elapsedTime.isFinite, elapsedTime > 0, duration.isFinite, duration > 0 {
            let remainingTime = duration - elapsedTime
            if remainingTime > 0, remainingTime < 10 {
                nextPreloadedPlayable = nextPlayablePreloadCB?()
                guard let nextPreloadedPlayable = nextPreloadedPlayable else { return }
                print("Next preload song is: \(nextPreloadedPlayable.displayString)")
                if nextPreloadedPlayable.isCached {
                    insertCachedPlayable(playable: nextPreloadedPlayable, queueType: .queue)
                } else if !isOfflineMode{
                    insertStreamPlayable(playable: nextPreloadedPlayable, queueType: .queue)
                    if isAutoCachePlayedItems {
                        playableDownloader.download(object: nextPreloadedPlayable)
                    }
                }
            }
        }
    }
}

extension BackendAudioPlayer: AudioStreaming.AudioPlayerDelegate {
    func audioPlayerDidStartPlaying(player: AudioStreaming.AudioPlayer, with entryId: AudioEntryId) {
        print("audioPlayerDidStartPlaying")
    }
    
    func audioPlayerDidFinishBuffering(player: AudioStreaming.AudioPlayer, with entryId: AudioEntryId) {
        print("audioPlayerDidFinishBuffering")
    }
    
    func audioPlayerStateChanged(player: AudioStreaming.AudioPlayer, with newState: AudioPlayerState, previous: AudioPlayerState) {
        print("audioPlayerStateChanged \(previous) \(newState)")
        if newState == .stopped {
            itemFinishedPlaying()
        }
    }
    
    func audioPlayerDidFinishPlaying(player: AudioStreaming.AudioPlayer, entryId: AudioEntryId, stopReason: AudioPlayerStopReason, progress: Double, duration: Double) {
        print("audioPlayerDidFinishPlaying")
        if nextPreloadedPlayable != nil {
            itemFinishedPlaying()
        }
    }
    
    func audioPlayerUnexpectedError(player: AudioStreaming.AudioPlayer, error: AudioPlayerError) {
        print("audioPlayerUnexpectedError")
    }
    
    func audioPlayerDidCancel(player: AudioStreaming.AudioPlayer, queuedItems: [AudioEntryId]) {
        print("audioPlayerDidCancel")
    }
    
    func audioPlayerDidReadMetadata(player: AudioStreaming.AudioPlayer, metadata: [String : String]) {
        print("audioPlayerDidReadMetadata")
    }
    
}
