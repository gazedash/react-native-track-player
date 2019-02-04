//  Converted to Swift 4 by Swiftify v4.2.28153 - https://objectivec2swift.com/

class RCTVideoCache {
    var videoCache
    var cachePath
    var cacheIdentifier
    var temporaryCachePath

    static let sharedInstanceVar: RCTVideoCache? = {
        var sharedInstance = self.init()
        return sharedInstance
    }()

    class func sharedInstance() -> RCTVideoCache? {
        // `dispatch_once()` call was converted to a static variable initializer
        return sharedInstanceVar
    }

    init() {
        // if super.init()
        cacheIdentifier = "rct.video.cache"
        temporaryCachePath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(cacheIdentifier).absoluteString
        cachePath = URL(fileURLWithPath: NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first ?? "").appendingPathComponent(cacheIdentifier).absoluteString
        let options = SPTPersistentCacheOptions()
        options.cachePath = cachePath
        options.cacheIdentifier = cacheIdentifier
        options.defaultExpirationPeriod = 60 * 60 * 24 * 30
        options.garbageCollectionInterval = Int(1.5 * SPTPersistentCacheDefaultGCIntervalSec)
        options.sizeConstraintBytes = 1024 * 1024 * 100
        options.useDirectorySeparation = false
        #if DEBUG
            options.debugOutput = { string in
                print("Video Cache: \(string ?? "")")
            }
        #endif
        createTemporaryPath()
        videoCache = SPTPersistentCache(options: options)
        videoCache.scheduleGarbageCollector()
    }

    func createTemporaryPath() {
        var error: Error?
        let success = try? FileManager.default.createDirectory(atPath: temporaryCachePath, withIntermediateDirectories: true, attributes: nil)
        #if DEBUG
            if !(success ?? false) || error != nil {
                if let error = error {
                    print("Error while! \(error)")
                }
            }
        #endif

        func storeItem(_ data: Data?, forUri uri: String?, withCallback handler: @escaping (Bool) -> Void) {
            let key = generateKey(forUri: uri)
            if key == nil {
                handler(false)
                return
            }
            saveData(toTemporaryStorage: data, key: key)
            videoCache.store(data, forKey: key, locked: false, withCallback: { response in
                if response.error {
                    #if DEBUG
                        print("An error occured while saving the video into the cache: \(response.error.localizedDescription)")
                    #endif
                    handler(false)
                    return
                }
                handler(true)
            }, onQueue: DispatchQueue.main)
            return
        }

        func getItemFromTemporaryStorage(_ key: String?) -> AVURLAsset? {
            let temporaryFilePath = URL(fileURLWithPath: temporaryCachePath).appendingPathComponent(key).absoluteString

            let fileExists: Bool = FileManager.default.fileExists(atPath: temporaryFilePath)
            if !fileExists {
                return nil
            }
            let assetUrl = URL(fileURLWithPath: temporaryFilePath)
            let asset = AVURLAsset(url: assetUrl, options: nil)
            return asset
        }

        func saveData(toTemporaryStorage data: Data?, key: String?) -> Bool {
            let temporaryFilePath = URL(fileURLWithPath: temporaryCachePath).appendingPathComponent(key).absoluteString
            data?.write(toFile: temporaryFilePath, atomically: true)
            return true
        }

        func generateKey(forUri uri: String?) -> String? {
            var uriWithoutQueryParams = uri

            // parse file extension
            if Int((uri as NSString?)?.range(of: "?").location ?? 0) != NSNotFound {
                let components = uri?.components(separatedBy: "?")
                uriWithoutQueryParams = components?[0]
            }

            let pathExtension = URL(fileURLWithPath: uriWithoutQueryParams ?? "").pathExtension
            let supportedExtensions = ["m4v", "mp4", "mov"]
            if pathExtension == "" {
                let userInfo = [
                    NSLocalizedDescriptionKey: NSLocalizedString("Missing file extension.", comment: ""),
                    NSLocalizedFailureReasonErrorKey: NSLocalizedString("Missing file extension.", comment: ""),
                    NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString("Missing file extension.", comment: ""),
                ]
                let error = NSError(domain: "RCTVideoCache", code: Int(RCTVideoCacheStatusMissingFileExtension), userInfo: userInfo)
                throw error
            } else if !(supportedExtensions.contains(pathExtension ?? "")) {
                // Notably, we don't currently support m3u8 (HLS playlists)
                let userInfo = [
                    NSLocalizedDescriptionKey: NSLocalizedString("Unsupported file extension.", comment: ""),
                    NSLocalizedFailureReasonErrorKey: NSLocalizedString("Unsupported file extension.", comment: ""),
                    NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString("Unsupported file extension.", comment: ""),
                ]
                let error = NSError(domain: "RCTVideoCache", code: Int(RCTVideoCacheStatusUnsupportedFileExtension), userInfo: userInfo)
                throw error
            }
            return URL(fileURLWithPath: generateHash(forUrl: uri) ?? "").appendingPathExtension(pathExtension).absoluteString
        }

        func generateHash(forUrl string: String?) -> String? {
            let cStr = Int8(string?.utf8CString ?? 0)
            let result = [UInt8](repeating: 0, count: CC_MD5_DIGEST_LENGTH)
            CC_MD5(cStr, strlen(cStr) as? CC_LONG, result)

            return String(format: "%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X", result[0], result[1], result[2], result[3], result[4], result[5], result[6], result[7], result[8], result[9], result[10], result[11], result[12], result[13], result[14], result[15])
        }

        func getItemForUri(_ uri: String?, withCallback handler: @escaping (RCTVideoCacheStatus, AVAsset?) -> Void) {
            defer {}
            do {
                let key = generateKey(forUri: uri)
                let temporaryAsset: AVURLAsset? = getItemFromTemporaryStorage(key)
                if temporaryAsset != nil {
                    handler(RCTVideoCacheStatusAvailable, temporaryAsset)
                    return
                }

                videoCache.loadData(forKey: key, withCallback: { response in
                    if response.record == nil || response.record.data == nil {
                        handler(RCTVideoCacheStatusNotAvailable, nil)
                        return
                    }
                    self.saveData(toTemporaryStorage: response.record.data, key: key)
                    handler(RCTVideoCacheStatusAvailable, self.getItemFromTemporaryStorage(key))
                }, onQueue: DispatchQueue.main)
            } catch let err {
                switch err.code {
                case RCTVideoCacheStatusMissingFileExtension:
                    handler(RCTVideoCacheStatusMissingFileExtension, nil)
                    return
                case RCTVideoCacheStatusUnsupportedFileExtension:
                    handler(RCTVideoCacheStatusUnsupportedFileExtension, nil)
                    return
                default:
                    throw err
                }
            }
        }
    }
}
