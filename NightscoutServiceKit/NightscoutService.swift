//
//  NightscoutService.swift
//  NightscoutServiceKit
//
//  Created by Darin Krauss on 6/20/19.
//  Copyright © 2019 LoopKit Authors. All rights reserved.
//

import os.log
import HealthKit
import LoopKit
import NightscoutUploadKit

public final class NightscoutService: Service {

    public static let serviceIdentifier = "NightscoutService"

    public static let localizedTitle = LocalizedString("Nightscout", comment: "The title of the Nightscout service")
    
    public let objectIdCacheKeepTime = TimeInterval(24 * 60 * 60)

    public weak var serviceDelegate: ServiceDelegate?

    public var siteURL: URL? {
        didSet {
            updateUploader()
        }
    }

    public var apiSecret: String? {
        didSet {
            updateUploader()
        }
    }
    
    public var isOnboarded: Bool

    public let otpManager: OTPManager
    
    /// Maps loop syncIdentifiers to Nightscout objectIds
    var objectIdCache: ObjectIdCache {
        get {
            return lockedObjectIdCache.value
        }
        set {
            lockedObjectIdCache.value = newValue
        }
    }
    private let lockedObjectIdCache: Locked<ObjectIdCache>

    private var uploader: NightscoutUploader? = nil

    private let log = OSLog(category: "NightscoutService")

    public init() {
        self.isOnboarded = false
        self.lockedObjectIdCache = Locked(ObjectIdCache())
        self.otpManager = OTPManager(secretStore: KeychainManager())
    }

    public required init?(rawState: RawStateValue) {
        self.isOnboarded = rawState["isOnboarded"] as? Bool ?? true   // Backwards compatibility

        if let objectIdCacheRaw = rawState["objectIdCache"] as? ObjectIdCache.RawValue,
            let objectIdCache = ObjectIdCache(rawValue: objectIdCacheRaw)
        {
            self.lockedObjectIdCache = Locked(objectIdCache)
        } else {
            self.lockedObjectIdCache = Locked(ObjectIdCache())
        }
        
        self.otpManager = OTPManager(secretStore: KeychainManager())
        
        restoreCredentials()
    }

    public var rawState: RawStateValue {
        return [
            "isOnboarded": isOnboarded,
            "objectIdCache": objectIdCache.rawValue
        ]
    }

    public var hasConfiguration: Bool { return siteURL != nil && apiSecret?.isEmpty == false }

    public func verifyConfiguration(completion: @escaping (Error?) -> Void) {
        guard hasConfiguration, let siteURL = siteURL, let apiSecret = apiSecret else {
            return
        }

        let uploader = NightscoutUploader(siteURL: siteURL, APISecret: apiSecret)
        uploader.checkAuth(completion)
    }

    public func completeCreate() {
        saveCredentials()
    }

    public func completeOnboard() {
        isOnboarded = true

        saveCredentials()
        serviceDelegate?.serviceDidUpdateState(self)
    }

    public func completeUpdate() {
        saveCredentials()
        serviceDelegate?.serviceDidUpdateState(self)
    }

    public func completeDelete() {
        clearCredentials()
        serviceDelegate?.serviceWantsDeletion(self)
    }

    private func saveCredentials() {
        try? KeychainManager().setNightscoutCredentials(siteURL: siteURL, apiSecret: apiSecret)
    }

    public func restoreCredentials() {
        if let credentials = try? KeychainManager().getNightscoutCredentials() {
            self.siteURL = credentials.siteURL
            self.apiSecret = credentials.apiSecret
        }
    }

    public func clearCredentials() {
        siteURL = nil
        apiSecret = nil
        try? KeychainManager().setNightscoutCredentials()
    }
    
    private func updateUploader() {
        if let siteURL = siteURL, let apiSecret = apiSecret, uploader == nil {
            uploader = NightscoutUploader(siteURL: siteURL, APISecret: apiSecret)
        } else if (siteURL == nil || apiSecret == nil) && uploader != nil {
            uploader = nil
        }
    }
    
}

extension NightscoutService: RemoteDataService {

    public var carbDataLimit: Int? { return 1000 }

    public func uploadCarbData(created: [SyncCarbObject], updated: [SyncCarbObject], deleted: [SyncCarbObject], completion: @escaping (Result<Bool, Error>) -> Void) {
        guard let uploader = uploader else {
            completion(.success(true))
            return
        }
        
        uploader.createCarbData(created) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let createdObjectIds):
                let createdUploaded = !created.isEmpty
                let syncIdentifiers = created.map { $0.syncIdentifier }
                for (syncIdentifier, objectId) in zip(syncIdentifiers, createdObjectIds) {
                    if let syncIdentifier = syncIdentifier {
                        self.objectIdCache.add(syncIdentifier: syncIdentifier, objectId: objectId)
                    }
                }
                self.serviceDelegate?.serviceDidUpdateState(self)
                
                uploader.updateCarbData(updated, usingObjectIdCache: self.objectIdCache) { result in
                    switch result {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let updatedUploaded):
                        uploader.deleteCarbData(deleted, usingObjectIdCache: self.objectIdCache) { result in
                            switch result {
                            case .failure(let error):
                                completion(.failure(error))
                            case .success(let deletedUploaded):
                                self.objectIdCache.purge(before: Date().addingTimeInterval(-self.objectIdCacheKeepTime))
                                self.serviceDelegate?.serviceDidUpdateState(self)
                                completion(.success(createdUploaded || updatedUploaded || deletedUploaded))
                            }
                        }
                    }
                }
            }
        }
    }

    public var doseDataLimit: Int? { return 1000 }

    public func uploadDoseData(_ stored: [DoseEntry], completion: @escaping (Result<Bool, Error>) -> Void) {
        guard let uploader = uploader else {
            completion(.success(true))
            return
        }

        uploader.uploadDoses(stored, usingObjectIdCache: self.objectIdCache) { (result) in
            switch (result) {
            case .success(let objectIds):
                let syncIdentifiers = stored.map { $0.syncIdentifier }
                for (syncIdentifier, objectId) in zip(syncIdentifiers, objectIds) {
                    if let syncIdentifier = syncIdentifier {
                        self.objectIdCache.add(syncIdentifier: syncIdentifier, objectId: objectId)
                    }
                }
                completion(.success(!stored.isEmpty))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    public var dosingDecisionDataLimit: Int? { return 50 }  // Each can be up to 20K bytes of serialized JSON, target ~1M or less

    public func uploadDosingDecisionData(_ stored: [StoredDosingDecision], completion: @escaping (Result<Bool, Error>) -> Void) {
        guard let uploader = uploader else {
            completion(.success(true))
            return
        }

        uploader.uploadDeviceStatuses(stored.map { $0.deviceStatus }, completion: completion)
    }

    public var glucoseDataLimit: Int? { return 1000 }

    public func uploadGlucoseData(_ stored: [StoredGlucoseSample], completion: @escaping (Result<Bool, Error>) -> Void) {
        guard let uploader = uploader else {
            completion(.success(true))
            return
        }

        uploader.uploadGlucoseSamples(stored, completion: completion)
    }

    public var pumpEventDataLimit: Int? { return 1000 }

    public func uploadPumpEventData(_ stored: [PersistedPumpEvent], completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(false))
    }

    public var settingsDataLimit: Int? { return 400 }  // Each can be up to 2.5K bytes of serialized JSON, target ~1M or less

    public func uploadSettingsData(_ stored: [StoredSettings], completion: @escaping (Result<Bool, Error>) -> Void) {
        guard let uploader = uploader else {
            completion(.success(true))
            return
        }

        uploader.uploadProfiles(stored.compactMap { $0.profileSet }, completion: completion)
    }
    
    public func validatePushNotificationSource(_ notification: [String: AnyObject]) -> Bool {
        guard let otpToValidate = notification["otp"] as? String else {
            return false
        }

        return otpManager.validateOTP(otpToValidate: otpToValidate)
    }
    
}

extension KeychainManager {

    func setNightscoutCredentials(siteURL: URL? = nil, apiSecret: String? = nil) throws {
        let credentials: InternetCredentials?

        if let siteURL = siteURL, let apiSecret = apiSecret {
            credentials = InternetCredentials(username: NightscoutAPIAccount, password: apiSecret, url: siteURL)
        } else {
            credentials = nil
        }

        try replaceInternetCredentials(credentials, forAccount: NightscoutAPIAccount)
    }

    func getNightscoutCredentials() throws -> (siteURL: URL, apiSecret: String) {
        let credentials = try getInternetCredentials(account: NightscoutAPIAccount)

        return (siteURL: credentials.url, apiSecret: credentials.password)
    }

}

fileprivate let NightscoutAPIAccount = "NightscoutAPI"
