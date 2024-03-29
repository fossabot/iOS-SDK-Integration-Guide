//  Copyright © 2017 Optimove. All rights reserved.

import UIKit
import UserNotifications

protocol OptimoveEventReporting: class {
    func reportEvent(_ event: OptimoveEvent)
    func dispatchQueuedEventsNow()
}

/// The entry point of Optimove SDK.
/// Initialize and configure Optimove using Optimove.sharedOptimove.configure.
@objc public final class Optimove: NSObject {

    // MARK: - Attributes

    let optiPush: OptiPush
    let optiTrack: OptiTrack
    let realTime: RealTime

    private let serviceLocator: ServiceLocator
    private let stateDelegateQueue = DispatchQueue(label: "com.optimove.sdk_state_delegates")
    private var storage: OptimoveStorage
    private let networkingFactory: NetworkingFactory

    private lazy var sdkInitializer: OptimoveSDKInitializer = { [unowned self, serviceLocator] in
        return OptimoveSDKInitializer(
            deviceStateMonitor: serviceLocator.deviceStateMonitor(),
            configuratorFactory: ComponentConfiguratorFactory(
                serviceLocator: serviceLocator,
                optimoveInstance: self
            ),
            warehouseProvider: serviceLocator.warehouseProvider(),
            storage: serviceLocator.storage(),
            networking: networkingFactory.createRemoteConfigurationNetworking()
        )
    }()

    private static var swiftStateDelegates: [ObjectIdentifier: OptimoveSuccessStateListenerWrapper] = [:]
    private static var objcStateDelegate: [ObjectIdentifier: OptimoveSuccessStateDelegateWrapper] = [:]

    private var optimoveTestTopic: String {
        return "test_ios_\(Bundle.main.bundleIdentifier ?? "")"
    }

    // MARK: - Deep Link

    private var deepLinkResponders = [OptimoveDeepLinkResponder]()

    var deepLinkComponents: OptimoveDeepLinkComponents? {
        didSet {
            guard let dlc = deepLinkComponents else {
                return
            }
            for responder in deepLinkResponders {
                responder.didReceive(deepLinkComponent: dlc)
            }
        }
    }

    // MARK: - API

    // MARK: - Initializers
    /// The shared instance of optimove singleton
    @objc public static let shared: Optimove = {
        let serviceLocator = ServiceLocator()
        let instance = Optimove(
            serviceLocator: serviceLocator,
            componentFactory: ComponentFactory(
                serviceLocator: serviceLocator,
                coreEventFactory: CoreEventFactoryImpl(
                    storage: serviceLocator.storage(),
                    dateTimeProvider: serviceLocator.dateTimeProvider()
                )
            )
        )
        return instance
    }()

    private init(
        serviceLocator: ServiceLocator,
        componentFactory: ComponentFactory) {
        self.serviceLocator = serviceLocator
        optiPush = componentFactory.createOptipushComponent()
        optiTrack = componentFactory.createOptitrackComponent()
        realTime = componentFactory.createRealtimeComponent()
        storage = serviceLocator.storage()
        networkingFactory = NetworkingFactory(
            networkClient: NetworkClientImpl(),
            requestBuilderFactory: NetworkRequestBuilderFactory(
                serviceLocator: serviceLocator
            )
        )
        super.init()

        setup()
    }

    /// The starting point of the Optimove SDK
    ///
    /// - Parameter info: Basic client information received on the onboarding process with Optimove
    @objc public static func configure(for tenantInfo: OptimoveTenantInfo) {
        shared.configureLogger()
        OptiLoggerMessages.logStartConfigureOptimoveSDK()
        shared.storeTenantInfo(tenantInfo)
        shared.startNormalInitProcess { (sucess) in
            guard sucess else {
                OptiLoggerMessages.logNormalInitFailed()
                return
            }
            OptiLoggerMessages.logNormalInitSuccess()
        }
    }

    // MARK: - Private Methods

    /// stores the user information that was provided during configuration
    ///
    /// - Parameter info: user unique info
    private func storeTenantInfo(_ info: OptimoveTenantInfo) {
        storage.tenantToken = info.tenantToken
        storage.version = info.configName
        storage.configurationEndPoint = info.url.last == "/" ? info.url : "\(info.url)/"

        OptiLoggerMessages.logStoreUserInfo(
            tenantToken: info.tenantToken,
            tenantVersion: info.configName,
            tenantUrl: info.url
        )

    }

    private func configureLogger() {
        let consoleStream = OptiLoggerConsoleStream()
        OptiLoggerStreamsContainer.add(stream: consoleStream)
        if SDK.isStaging {
            let tenantID: Int = storage.siteID ?? -1
            OptiLoggerStreamsContainer.add(
                stream: MobileLogServiceLoggerStream(tenantId: tenantID)
            )
        }
    }

    private func setup() {
        setUserAgent()
        setVisitorIdIfNeeded()
    }

    private func setUserAgent() {
        let userAgent = Device.evaluateUserAgent()
        storage.set(value: userAgent, key: .userAgent)
    }

    private func setVisitorIdIfNeeded() {
        if storage.visitorID == nil {
            let uuid = UUID().uuidString
            let sanitizedUUID = uuid.replacingOccurrences(of: "-", with: "")
            let start = sanitizedUUID.startIndex
            let end = sanitizedUUID.index(start, offsetBy: 16)
            storage.initialVisitorId = String(sanitizedUUID[start..<end]).lowercased()
            storage.visitorID = storage.initialVisitorId
        }
    }
}

// MARK: - Initialization API

extension Optimove {

    func startNormalInitProcess(didSucceed: @escaping ResultBlockWithBool) {
        OptiLoggerMessages.logStartInitFromRemote()
        if RunningFlagsIndication.isSdkRunning {
            OptiLoggerMessages.logSkipNormalInitSinceRunning()
            didSucceed(true)
            return
        }
        sdkInitializer.initializeFromRemoteServer { [sdkInitializer] success in
            guard success else {
                sdkInitializer.initializeFromLocalConfigs {
                    success in
                    didSucceed(success)
                }
                return
            }
            didSucceed(success)
        }
    }

    func startUrgentInitProcess(didSucceed: @escaping ResultBlockWithBool) {
        OptiLoggerMessages.logStartUrgentInitProcess()
        if RunningFlagsIndication.isSdkRunning {
            OptiLoggerMessages.logSkipUrgentInitSinceRunning()
            didSucceed(true)
            return
        }
        sdkInitializer.initializeFromLocalConfigs { success in
            didSucceed(success)
        }
    }

    func didFinishInitializationSuccessfully() {
        RunningFlagsIndication.isInitializerRunning = false
        RunningFlagsIndication.isSdkRunning = true

        if let clientApnsToken = storage.apnsToken,
            RunningFlagsIndication.isComponentRunning(.optiPush) {
            optiPush.application(didRegisterForRemoteNotificationsWithDeviceToken: clientApnsToken)
            storage.apnsToken = nil
        }
        let missingPermissions = serviceLocator.deviceStateMonitor().getMissingPermissions()
        let missingPermissionsObjc = missingPermissions.map { $0.rawValue }
        Optimove.swiftStateDelegates.values.forEach { (wrapper) in
            wrapper.observer?.optimove(self, didBecomeActiveWithMissingPermissions: missingPermissions)
        }
        Optimove.objcStateDelegate.values.forEach { (wrapper) in
            wrapper.observer.optimove(self, didBecomeActiveWithMissingPermissions: missingPermissionsObjc)
        }
    }
}

// MARK: - SDK state observing
//TODO: expose to  @objc
extension Optimove {

    public func registerSuccessStateListener(_ listener: OptimoveSuccessStateListener) {
        if RunningFlagsIndication.isSdkRunning {
            listener.optimove(
                self,
                didBecomeActiveWithMissingPermissions: serviceLocator.deviceStateMonitor().getMissingPermissions()
            )
            return
        }
        stateDelegateQueue.async {
            Optimove.swiftStateDelegates[ObjectIdentifier(listener)] = OptimoveSuccessStateListenerWrapper(
                observer: listener
            )
        }
    }

    public func unregisterSuccessStateListener(_ delegate: OptimoveSuccessStateListener) {
        stateDelegateQueue.async {
            Optimove.swiftStateDelegates[ObjectIdentifier(delegate)] = nil
        }
    }

    @available(swift, obsoleted: 1.0)
    @objc public func registerSuccessStateDelegate(_ delegate: OptimoveSuccessStateDelegate) {
        if RunningFlagsIndication.isSdkRunning {
            delegate.optimove(
                self,
                didBecomeActiveWithMissingPermissions: serviceLocator.deviceStateMonitor().getMissingPermissions().map { $0.rawValue }
            )
            return
        }
        stateDelegateQueue.async {
            Optimove.objcStateDelegate[ObjectIdentifier(delegate)] = OptimoveSuccessStateDelegateWrapper(
                observer: delegate
            )
        }
    }

    @available(swift, obsoleted: 1.0)
    @objc public func unregisterSuccessStateDelegate(_ delegate: OptimoveSuccessStateDelegate) {
        stateDelegateQueue.async {
            Optimove.objcStateDelegate[ObjectIdentifier(delegate)] = nil
        }
    }
}

// MARK: - Notification related API
extension Optimove {
    /// Validate user notification permissions and sends the payload to the message handler
    ///
    /// - Parameters:
    ///   - userInfo: the data payload as sends by the the server
    ///   - completionHandler: an indication to the OS that the data is ready to be presented by the system as a notification
    @objc public func didReceiveRemoteNotification(
        userInfo: [AnyHashable: Any],
        didComplete: @escaping (UIBackgroundFetchResult) -> Void
        ) -> Bool {
        OptiLoggerMessages.logReceiveRemoteNotification()
        guard userInfo[OptimoveKeys.Notification.isOptimoveSdkCommand.rawValue] as? String == "true" else {
            return false
        }
        serviceLocator.notificationListener().didReceiveRemoteNotification(
            userInfo: userInfo,
            didComplete: didComplete
        )
        return true
    }

    @objc public func willPresent(
        notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) -> Bool {
        OptiLoggerMessages.logReceiveNotificationInForeground()
        guard notification.request.content.userInfo[OptimoveKeys.Notification.isOptipush.rawValue] as? String == "true"
            else {
                OptiLoggerMessages.logNotificationShouldNotHandleByOptimove()
                return false
        }
        completionHandler([.alert, .sound, .badge])
        return true
    }

    /// Report user response to optimove notifications and send the client the related deep link to open
    ///
    /// - Parameters:
    ///   - response: The user response
    ///   - completionHandler: Indication about the process ending
    @objc public func didReceive(
        response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
        ) -> Bool {
        guard
            response.notification.request.content.userInfo[OptimoveKeys.Notification.isOptipush.rawValue] as? String
                == "true"
            else {
                OptiLoggerMessages.logNotificationResponse()
                return false
        }
        serviceLocator.notificationListener().didReceive(
            response: response,
            withCompletionHandler: completionHandler
        )
        return true
    }
}

// MARK: - OptiPush related API
extension Optimove {
    /// Request to handle APNS <-> FCM regisration process
    ///
    /// - Parameter deviceToken: A token that was received in the appDelegate callback
    @objc public func application(didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        if RunningFlagsIndication.isComponentRunning(.optiPush) {
            optiPush.application(didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
        } else {
            storage.apnsToken = deviceToken
        }
    }

    /// Request to subscribe to test campaign topics
    @objc public func startTestMode() {
        registerToOptipushTopic(optimoveTestTopic)
    }

    /// Request to unsubscribe from test campaign topics
    @objc public func stopTestMode() {
        unregisterFromOptipushTopic(optimoveTestTopic)
    }

    /// Request to register to topic
    ///
    /// - Parameter topic: The topic name
    func registerToOptipushTopic(_ topic: String, didSucceed: ((Bool) -> Void)? = nil) {
        if RunningFlagsIndication.isComponentRunning(.optiPush) {
            optiPush.subscribeToTopic(topic: topic, didSucceed: didSucceed)
        }
    }

    /// Request to unregister from topic
    ///
    /// - Parameter topic: The topic name
    func unregisterFromOptipushTopic(_ topic: String, didSucceed: ((Bool) -> Void)? = nil) {
        if RunningFlagsIndication.isComponentRunning(.optiPush) {
            optiPush.unsubscribeFromTopic(topic: topic, didSucceed: didSucceed)
        }
    }

    func performRegistration() {
        if RunningFlagsIndication.isComponentRunning(.optiPush) {
            optiPush.performRegistration()
        }
    }
}

extension Optimove: OptimoveDeepLinkResponding {
    @objc public func register(deepLinkResponder responder: OptimoveDeepLinkResponder) {
        if let dlc = self.deepLinkComponents {
            responder.didReceive(deepLinkComponent: dlc)
        } else {
            deepLinkResponders.append(responder)
        }
    }

    @objc public func unregister(deepLinkResponder responder: OptimoveDeepLinkResponder) {
        if let index = self.deepLinkResponders.firstIndex(of: responder) {
            deepLinkResponders.remove(at: index)
        }
    }
}

extension Optimove: OptimoveEventReporting {
    func dispatchQueuedEventsNow() {
        if RunningFlagsIndication.isSdkRunning {
            optiTrack.dispatchNow()
        }
    }
}

// MARK: - optiTrack related API
extension Optimove {
    /// validate the permissions of the client to use optitrack component and if permit sends the report to the apropriate handler
    ///
    /// - Parameters:
    ///   - event: optimove event object
    @objc public func reportEvent(_ event: OptimoveEvent) {
        let eventDecor = OptimoveEventDecoratorFactory.getEventDecorator(forEvent: event)

        guard let warehouse = try? serviceLocator.warehouseProvider().getWarehouse(),
            let config = warehouse.getConfig(for: event) else {
            OptiLoggerMessages.logConfigurationForEventMissing(eventName: eventDecor.name)
            return
        }
        eventDecor.processEventConfig(config)

        // Must pass the decorator in case some additional attributes become mandatory
        if let eventValidationError = OptimoveEventValidator().validate(event: eventDecor, withConfig: config) {
            OptiLoggerMessages.logReportEventFailed(
                eventName: eventDecor.name,
                eventValidationError: eventValidationError.localizedDescription
            )
            return
        }

        if RunningFlagsIndication.isComponentRunning(.optiTrack), config.supportedOnOptitrack {
            OptiLoggerMessages.logOptitrackReport(event: eventDecor.name)
            optiTrack.report(event: eventDecor, withConfigs: config)
        } else {
            OptiLoggerMessages.logOptiTrackNotRunning(eventName: eventDecor.name)
        }

        if RunningFlagsIndication.isComponentRunning(.realtime) {
            if config.supportedOnRealTime {
                OptiLoggerMessages.logRealtimeReportEvent(eventName: eventDecor.name)
                realTime.report(event: eventDecor, config: config)
            } else {
                OptiLoggerMessages.logEventNotsupportedOnRealtime(eventName: eventDecor.name)
            }
        } else {
            OptiLoggerMessages.logRealtimeNotrunning(eventName: eventDecor.name)
            if eventDecor.name == OptimoveKeys.Configuration.setUserId.rawValue {
                storage.realtimeSetUserIdFailed = true
            } else if eventDecor.name == OptimoveKeys.Configuration.setEmail.rawValue {
                storage.realtimeSetEmailFailed = true
            }
        }
    }

    @objc public func reportEvent(name: String, parameters: [String: Any]) {
        let customEvent = SimpleCustomEvent(name: name, parameters: parameters)
        self.reportEvent(customEvent)
    }

}

// MARK: - set user id API
extension Optimove {

    /// validate the permissions of the client to use optitrack component and if permit validate the sdkId content and sends:
    /// - conversion request to the DB
    /// - new customer registraion to the registration end point
    ///
    /// - Parameter sdkId: the client unique identifier
    @objc public func setUserId(_ sdkId: String) {
        let userId = sdkId.trimmingCharacters(in: .whitespaces)
        guard isValid(userId: userId) else {
            OptiLoggerMessages.logUserIdNotValid(userID: userId)
            return
        }

        //TODO: Move to Optipush
        if storage.customerID == nil {
            storage.isFirstConversion = true
        } else if userId != storage.customerID {
            OptiLoggerStreamsContainer.log(
                level: .debug,
                fileName: #file,
                methodName: #function,
                logModule: "Optimove",
                "user id changed from '\(storage.customerID ?? "nil")' to '\(userId)'"
            )
            if storage.isRegistrationSuccess == true {
                // send the first_conversion flag only if no previous registration has succeeded
                storage.isFirstConversion = false
            }
        } else {
            OptiLoggerMessages.logUserIdNotNew(userId: userId)
            return
        }
        storage.isRegistrationSuccess = false
        //

        let initialVisitorId = storage.initialVisitorId!
        let updatedVisitorId = getVisitorId(from: userId)
        storage.visitorID = updatedVisitorId
        storage.customerID = userId

        if RunningFlagsIndication.isComponentRunning(.optiTrack) {
            self.optiTrack.setUserId(userId)
        } else {
            OptiLoggerMessages.logOptitrackNotRunningForSetUserId()
            //Retry done inside optitrack module
        }

        let setUserIdEvent = SetUserIdEvent(
            originalVistorId: initialVisitorId,
            userId: userId,
            updateVisitorId: storage.visitorID!
        )
        reportEvent(setUserIdEvent)

        if RunningFlagsIndication.isComponentRunning(.optiPush) {
            self.optiPush.performRegistration()
        } else {
            OptiLoggerMessages.logOptipushNOtRunningForRegistration()
            // Retry handled inside optipush
        }
    }

    /// Produce a 16 characters string represents the visitor ID of the client
    ///
    /// - Parameter userId: The user ID which is the source
    /// - Returns: THe generated visitor ID
    private func getVisitorId(from userId: String) -> String {
        return userId.sha1().prefix(16).description.lowercased()
    }

    /// Send the sdk id and the user email
    ///
    /// - Parameters:
    ///   - email: The user email
    ///   - sdkId: The user ID

    @available(*, deprecated, renamed: "registerUser(sdkId:email:)")
    @objc public func registerUser(email: String, sdkId: String) {
        registerUser(sdkId: sdkId, email: email)
    }

    /// Send the sdk id and the user email
    ///
    /// - Parameters:
    ///   - sdkId: The user ID
    ///   - email: The user email
    @objc public func registerUser(sdkId: String, email: String) {
        self.setUserId(sdkId)
        self.setUserEmail(email: email)
    }

    /// Call for the SDK to send the user email to its components
    ///
    /// - Parameter email: The user email
    @objc public func setUserEmail(email: String) {
        guard isValid(email: email) else {
            OptiLoggerMessages.logEmailNotValid()
            return
        }
        storage.userEmail = email
        reportEvent(SetUserEmailEvent(email: email))
    }

    /// Validate that the user id that provided by the client, feets with optimove conditions for valid user id
    ///
    /// - Parameter userId: the client user id
    /// - Returns: An indication of the validation of the provided user id
    private func isValid(userId: String) -> Bool {
        return !userId.isEmpty && (userId != "none") && (userId != "undefined") && !userId.contains("undefine") && !(
            userId == "null"
        )
    }

    private func isValid(email: String) -> Bool {
        let emailRegEx = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailTest = NSPredicate(format: "SELF MATCHES %@", emailRegEx)
        return emailTest.evaluate(with: email)
    }
}

extension Optimove {

    // MARK: - Report screen visit

    @objc public func setScreenVisit(screenPathArray: [String], screenTitle: String, screenCategory: String? = nil) {
        OptiLoggerMessages.logReportScreen()
        guard !screenTitle.trimmingCharacters(in: .whitespaces).isEmpty else {
            OptiLoggerMessages.logReportScreenWithEmptyTitleError()
            return
        }
        let path = screenPathArray.joined(separator: "/")
        setScreenVisit(screenPath: path, screenTitle: screenTitle, screenCategory: screenCategory)
    }

    @objc public func setScreenVisit(screenPath: String, screenTitle: String, screenCategory: String? = nil) {
        let screenTitle = screenTitle.trimmingCharacters(in: .whitespaces)
        var screenPath = screenPath.trimmingCharacters(in: .whitespaces)
        guard !screenTitle.isEmpty else {
            OptiLoggerMessages.logReportScreenWithEmptyTitleError()
            return
        }
        guard !screenPath.isEmpty else {
            OptiLoggerMessages.logReportScreenWithEmptyScreenPath()
            return
        }

        if screenPath.starts(with: "/") {
            screenPath = String(screenPath[screenPath.index(after: screenPath.startIndex)...])
        }
        if let customUrl = removeUrlProtocol(path: screenPath)
            .lowercased()
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {

            var path = customUrl.last != "/" ? "\(customUrl)/" : "\(customUrl)"

            path = "\(Bundle.main.bundleIdentifier!)/\(path)".lowercased()

            // TODO: Handle it
            if RunningFlagsIndication.isComponentRunning(.optiTrack) {
                try? optiTrack.reportScreenEvent(
                    screenTitle: screenTitle,
                    screenPath: path, category:
                    screenCategory
                )
            }
            if RunningFlagsIndication.isComponentRunning(.realtime) {
                try? realTime.reportScreenEvent(
                    customURL: path,
                    pageTitle: screenTitle,
                    category: screenCategory
                )
            }
        }
    }

    private func removeUrlProtocol(path: String) -> String {
        var result = path
        for prefix in ["https://www.", "http://www.", "https://", "http://"] {
            if result.hasPrefix(prefix) {
                result.removeFirst(prefix.count)
                break
            }
        }
        return result
    }
}
