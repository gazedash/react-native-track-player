//
//  AVPlayerWrapper.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 06/03/2018.
//  Copyright © 2018 Jørgen Henrichsen. All rights reserved.
//

import AVFoundation
import Foundation
import MediaPlayer

public enum PlaybackEndedReason: String {
    case playedUntilEnd
    case playerStopped
    case skippedToNext
    case skippedToPrevious
    case jumpedToIndex
}

class AVPlayerWrapper: AVPlayerWrapperProtocol {
    struct Constants {
        static let assetPlayableKey = "playable"
    }

    // MARK: - Properties

    let avPlayer: AVPlayer
    let playerObserver: AVPlayerObserver
    let playerTimeObserver: AVPlayerTimeObserver
    let playerItemNotificationObserver: AVPlayerItemNotificationObserver
    let playerItemObserver: AVPlayerItemObserver
    private var currentItem: AVPlayerItem!
    private var _videoCache: RCTVideoCache!

    /**
     True if the last call to load(from:playWhenReady) had playWhenReady=true.
     */
    fileprivate var _playWhenReady: Bool = true

    fileprivate var _state: AVPlayerWrapperState = AVPlayerWrapperState.idle {
        didSet {
            if oldValue != _state {
                delegate?.AVWrapper(didChangeState: _state)
            }
        }
    }

    public init(avPlayer: AVPlayer = AVPlayer(), eventDispatcher: RCTEventDispatcher) {
        avPlayer = avPlayer
        playerObserver = AVPlayerObserver(player: avPlayer)
        playerTimeObserver = AVPlayerTimeObserver(player: avPlayer, periodicObserverTimeInterval: timeEventFrequency.getTime())
        playerItemNotificationObserver = AVPlayerItemNotificationObserver()
        playerItemObserver = AVPlayerItemObserver()

        playerObserver.delegate = self
        playerTimeObserver.delegate = self
        playerItemNotificationObserver.delegate = self
        playerItemObserver.delegate = self

        playerTimeObserver.registerForPeriodicTimeEvents()

        if self = super.init() {
            _eventDispatcher = eventDispatcher

            _videoCache = RCTVideoCache.sharedInstance()
        }

        return self
    }

    // MARK: - AVPlayerWrapperProtocol

    var state: AVPlayerWrapperState {
        return _state
    }

    var reasonForWaitingToPlay: AVPlayer.WaitingReason? {
        return avPlayer.reasonForWaitingToPlay
    }

    var currentItem: AVPlayerItem? {
        return avPlayer.currentItem
    }

    var automaticallyWaitsToMinimizeStalling: Bool {
        get { return avPlayer.automaticallyWaitsToMinimizeStalling }
        set { avPlayer.automaticallyWaitsToMinimizeStalling = newValue }
    }

    var currentTime: TimeInterval {
        let seconds = avPlayer.currentTime().seconds
        return seconds.isNaN ? 0 : seconds
    }

    var duration: TimeInterval {
        if let seconds = currentItem?.asset.duration.seconds, !seconds.isNaN {
            return seconds
        }
        else if let seconds = currentItem?.duration.seconds, !seconds.isNaN {
            return seconds
        } else if let seconds = currentItem?.loadedTimeRanges.first?.timeRangeValue.duration.seconds,
            !seconds.isNaN {
            return seconds
        }
        return 0.0
    }

    weak var delegate: AVPlayerWrapperDelegate?

    var bufferDuration: TimeInterval = 0

    var timeEventFrequency: TimeEventFrequency = .everySecond {
        didSet {
            playerTimeObserver.periodicObserverTimeInterval = timeEventFrequency.getTime()
        }
    }

    var rate: Float {
        get { return avPlayer.rate }
        set { avPlayer.rate = newValue }
    }

    var volume: Float {
        get { return avPlayer.volume }
        set { avPlayer.volume = newValue }
    }

    var isMuted: Bool {
        get { return avPlayer.isMuted }
        set { avPlayer.isMuted = newValue }
    }

    func play() {
        avPlayer.play()
    }

    func pause() {
        avPlayer.pause()
    }

    func togglePlaying() {
        switch avPlayer.timeControlStatus {
        case .playing, .waitingToPlayAtSpecifiedRate:
            pause()
        case .paused:
            play()
        }
    }

    func stop() {
        pause()
        reset(soft: false)
    }

    func seek(to seconds: TimeInterval) {
        avPlayer.seek(to: CMTimeMakeWithSeconds(seconds, preferredTimescale: 1)) { finished in
            delegate?.AVWrapper(seekTo: Int(seconds), didFinish: finished)
        }
    }

    func playerItemForSource(source: NSDictionary!, withCallback handler: (AVPlayerItem!) -> Void) {
        let isNetwork: bool = RCTConvert.BOOL(source.objectForKey("isNetwork"))
        let isAsset: bool = RCTConvert.BOOL(source.objectForKey("isAsset"))
        let shouldCache: bool = RCTConvert.BOOL(source.objectForKey("shouldCache"))
        let uri: String! = source.objectForKey("uri")
        let type: String! = source.objectForKey("type")

        let url: NSURL! = isNetwork || isAsset
            ? NSURL.URLWithString(uri)
            : NSURL.initFileURLWithPath(NSBundle.mainBundle().pathForResource(uri, ofType: type))
        let assetOptions: NSMutableDictionary! = NSMutableDictionary()

        if isNetwork {
            let cookies: [AnyObject]! = NSHTTPCookieStorage.sharedHTTPCookieStorage().cookies()
            assetOptions.setObject(cookies, forKey: AVURLAssetHTTPCookiesKey)

            if shouldCache {
                [self playerItemForSourceUsingCache: uri assetOptions: assetOptions withCallback: handler]
                return
            }

            let asset: AVURLAsset! = AVURLAsset.URLAssetWithURL(url, options: assetOptions)
            return
        } else if isAsset {
            let asset: AVURLAsset! = AVURLAsset.URLAssetWithURL(url, options: nil)
            return
        }

        let asset: AVURLAsset! = AVURLAsset.URLAssetWithURL(NSURL.initFileURLWithPath(NSBundle.mainBundle().pathForResource(uri, ofType: type)), options: nil)
    }

    func playerItemForSourceUsingCache(uri: String!, assetOptions options: NSDictionary!, withCallback handler: (AVPlayerItem!) -> Void) {
        let url: NSURL! = NSURL.URLWithString(uri)
        _videoCache.getItemForUri(uri, withCallback: { (videoCacheStatus: RCTVideoCacheStatus, cachedAsset: AVAsset?) in
            switch videoCacheStatus {
            case RCTVideoCacheStatusMissingFileExtension:
                DebugLog("Could not generate cache key for uri '%@'. It is currently not supported to cache urls that do not include a file extension. The video file will not be cached. Checkout https://github.com/react-native-community/react-native-video/blob/master/docs/caching.md", uri)
                let asset: AVURLAsset! = AVURLAsset.URLAssetWithURL(url, options: options)
                return

            case RCTVideoCacheStatusUnsupportedFileExtension:
                DebugLog("Could not generate cache key for uri '%@'. The file extension of that uri is currently not supported. The video file will not be cached. Checkout https://github.com/react-native-community/react-native-video/blob/master/docs/caching.md", uri)
                let asset: AVURLAsset! = AVURLAsset.URLAssetWithURL(url, options: options)
                return

            default:
                if cachedAsset {
                    DebugLog("Playing back uri '%@' from cache", uri)
                    handler(AVPlayerItem.playerItemWithAsset(cachedAsset))
                    return
                }
            }

            let asset: DVURLAsset! = DVURLAsset(URL: url, options: options, networkTimeout: 10000)
            asset.loaderDelegate = self

            handler(AVPlayerItem.playerItemWithAsset(asset))
        })
    }

    func load(from url: URL, playWhenReady: Bool) {
        reset(soft: true)
        _playWhenReady = playWhenReady
        _state = .loading

        // Set item
        let currentAsset = AVURLAsset(url: url)

        let currentItem = AVPlayerItem(asset: currentAsset, automaticallyLoadedAssetKeys: [Constants.assetPlayableKey])

        playerItemForSource(source, withCallback: { (playerItem: AVPlayerItem!) in
            currentItem = playerItem

            avPlayer = AVPlayer.playerWithPlayerItem(currentItem)
        })

        currentItem.preferredForwardBufferDuration = bufferDuration
        avPlayer.replaceCurrentItem(with: currentItem)

        // Register for events
        playerTimeObserver.registerForBoundaryTimeEvents()
        playerObserver.startObserving()
        playerItemNotificationObserver.startObserving(item: currentItem)
        playerItemObserver.startObserving(item: currentItem)

        // if no file found, check if the file exists in the Document directory
        let paths: [AnyObject]! = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, true)
        var relativeFilePath: String! = filepath.lastPathComponent()
        // the file may be multiple levels below the documents directory
        let fileComponents: [AnyObject]! = filepath.componentsSeparatedByString("Documents/")
        if fileComponents.count > 1 {
            relativeFilePath = fileComponents.objectAtIndex(1)
        }

        let path: String! = paths.firstObject.stringByAppendingPathComponent(relativeFilePath)
        if NSFileManager.defaultManager().fileExistsAtPath(path) {
            return NSURL.fileURLWithPath(path)
        }
        return nil
    }

    // MARK: - Util

    private func reset(soft: Bool) {
        playerItemObserver.stopObservingCurrentItem()
        playerTimeObserver.unregisterForBoundaryTimeEvents()
        playerItemNotificationObserver.stopObservingCurrentItem()

        if !soft {
            avPlayer.replaceCurrentItem(with: nil)
        }
    }
}

extension AVPlayerWrapper: AVPlayerObserverDelegate {
    // MARK: - AVPlayerObserverDelegate

    func player(didChangeTimeControlStatus status: AVPlayer.TimeControlStatus) {
        switch status {
        case .paused:
            if currentItem == nil {
                _state = .idle
            } else {
                _state = .paused
            }
        case .waitingToPlayAtSpecifiedRate:
            _state = .loading
        case .playing:
            _state = .playing
        }
    }

    func player(statusDidChange status: AVPlayer.Status) {
        switch status {
        case .readyToPlay:
            _state = .ready
            if _playWhenReady {
                play()
            }

        case .failed:
            delegate?.AVWrapper(failedWithError: avPlayer.error)

        case .unknown:
            break
        }
    }
}

extension AVPlayerWrapper: AVPlayerTimeObserverDelegate {
    // MARK: - AVPlayerTimeObserverDelegate

    func audioDidStart() {
        _state = .playing
    }

    func timeEvent(time: CMTime) {
        delegate?.AVWrapper(secondsElapsed: time.seconds)
    }
}

extension AVPlayerWrapper: AVPlayerItemNotificationObserverDelegate {
    // MARK: - AVPlayerItemNotificationObserverDelegate

    func itemDidPlayToEndTime() {
        delegate?.AVWrapper(itemPlaybackDoneWithReason: .playedUntilEnd)
    }
}

extension AVPlayerWrapper: AVPlayerItemObserverDelegate {
    // MARK: - AVPlayerItemObserverDelegate

    func item(didUpdateDuration duration: Double) {
        delegate?.AVWrapper(didUpdateDuration: duration)
    }
}
