import Foundation

final class RealTime: OptimoveComponent {

    private let realTimeQueue: DispatchQueue
    private let networking: RealTimeNetworking
    private let hanlder: RealTimeHanlder
    private let warehouse: EventsConfigWarehouseProvider
    private var storage: OptimoveStorage
    private let eventBuilder: RealTimeEventBuilder
    private let coreEventFactory: CoreEventFactory

    // MARK: - Public

    required init(
        storage: OptimoveStorage,
        networking: RealTimeNetworking,
        warehouse: EventsConfigWarehouseProvider,
        deviceStateMonitor: OptimoveDeviceStateMonitor,
        eventBuilder: RealTimeEventBuilder,
        handler: RealTimeHanlder,
        coreEventFactory: CoreEventFactory) {
        self.storage = storage
        self.networking = networking
        self.warehouse = warehouse
        self.realTimeQueue = DispatchQueue(
            label: "com.optimove.queue.realtime",
            qos: .userInitiated
        )
        self.hanlder = handler
        self.eventBuilder = eventBuilder
        self.coreEventFactory = coreEventFactory
        super.init(deviceStateMonitor: deviceStateMonitor)
    }
    
    override func performInitializationOperations() {
        super.performInitializationOperations()
        setFirstTimeVisitIfNeeded()
    }

    func report(event: OptimoveEvent, config: EventsConfig, retryFailedEvents: Bool = true) {
        do {
            let context = createEventContext(event: event, config: config)
            try report(context: context, retryFailedEvents: retryFailedEvents)
        } catch {
            OptiLoggerMessages.logError(error: error)
        }
    }

}

// MARK: - Additional public API

extension RealTime {

    func reportEvent(event: OptimoveEvent, retryFailedEvents: Bool = true) {
        let event = OptimoveEventDecorator(event: event)
        guard let config = obtainConfiguration(for: event) else { return }
        event.processEventConfig(config)
        report(event: event, config: config, retryFailedEvents: retryFailedEvents)
    }

    func reportScreenEvent(customURL: String,
                           pageTitle: String,
                           category: String?) throws {
        let event = try coreEventFactory.createEvent(
            .pageVisit(screenPath: customURL,
                       screenTitle: pageTitle,
                       category: category
            )
        )
        reportEvent(event: event)
    }

    func reportUserId() throws {
        let event = try coreEventFactory.createEvent(.setUserId)
        reportEvent(event: event, retryFailedEvents: false)
    }

    func reportUserEmail(_ email: String) {
        let event = SetUserEmailEvent(
            email: email
        )
        reportEvent(event: event, retryFailedEvents: false)
    }

    func isAllowToSendReport(completion: @escaping (Bool) -> Void) {
        deviceStateMonitor.getStatus(for: .internet) { (online) in
            completion(online)
        }
    }

}

// MARK: - Private

private extension RealTime {

    func setFirstTimeVisitIfNeeded() {
        if storage[.firstVisitTimestamp] == nil {
            // Realtime server asked to get it in seconds
            storage[.firstVisitTimestamp] = Int64(Date().timeIntervalSince1970)
        }
    }

    // MARK: Transforming an event

    func obtainConfiguration(for event: OptimoveEvent) -> EventsConfig? {
        guard let warehouse = try? warehouse.getWarehouse(),
            let config = warehouse.getConfig(for: event) else {
                OptiLoggerMessages.logConfigForEventMissing(eventName: event.name)
                return nil
        }
        return config
    }

    func createEventContext(event: OptimoveEvent, config: EventsConfig) -> RealTimeEventContext {
        switch event.name {
        case OptimoveKeys.Configuration.setUserId.rawValue:
            return SetUserIdEventContext(event: event, config: config)
        case OptimoveKeys.Configuration.setEmail.rawValue:
            return SetUserEmailEventContext(event: event, config: config)
        default:
            return RegularEventContext(event: event, config: config)
        }
    }

    // MARK: Prepare before send a report

    func report(context: RealTimeEventContext, retryFailedEvents: Bool) throws {
        if retryFailedEvents {
            try retryUserDataIfNeeded(context: context)
        }
        sentReportEvent(context: context)
    }

    // MARK: Retry

    /// Verify that failed set_user_id is dispatched before failed set_email
    /// and before any custom event.
    /// This is requirment from the Server-side.
    func retryUserDataIfNeeded(context: RealTimeEventContext) throws {
        // Do not invoke retry on a new UserID
        if context.type != .setUserID {
            try retrySetUserIdEventIfNeeded()
        }
        // Do not invoke retry on a new UserEmail
        if context.type != .setUserEmail {
            try retrySetUserEmailIfNeeded()
        }
    }

    func retrySetUserIdEventIfNeeded() throws {
        if storage[.realtimeSetUserIdFailed] ?? false {
            try reportUserId()
        }
    }


    func retrySetUserEmailIfNeeded() throws {
        if storage[.realtimeSetEmailFailed] ?? false {
            reportUserEmail(try cast(storage[.userEmail]))
        }
    }

    // MARK: Send report
    
    func sentReportEvent(context: RealTimeEventContext) {
        isAllowToSendReport { [realTimeQueue, hanlder, networking, eventBuilder] (allow) in
            guard allow else {
                hanlder.handleOffline(context)
                return
            }
            // The delay added as the temporary hotfix for the realtime race condition issue.
            // Should be removed right after release a solution on a server side.
            let delay: TimeInterval = 1
            realTimeQueue.asyncAfter(deadline: .now() + delay, execute: {
                do {
                    let realtimeEvent = try eventBuilder.createEvent(context: context)
                    try networking.report(event: realtimeEvent) { (result) in
                        switch result {
                        case let .success(json):
                            hanlder.handleOnSuccess(context, json: json)
                        case let .failure(error):
                            hanlder.handleOnError(context, error: error)
                        }
                    }
                } catch {
                    hanlder.handleOnCatch(context, error: error)
                }
            })
        }
    }

}

enum RealTimeError: LocalizedError {
    case eitherCustomerOrVisitorIdIsNil

    var errorDescription: String? {
        switch self {
        case .eitherCustomerOrVisitorIdIsNil:
            return "Either a CustomerID or a VisitorID should not be nil."
        }
    }
}
