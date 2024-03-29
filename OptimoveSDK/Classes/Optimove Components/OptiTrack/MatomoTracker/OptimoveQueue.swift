import Foundation
import MatomoTracker

final class OptimoveQueue {

    private let storage: OptimoveStorage

    init(storage: OptimoveStorage) {
        self.storage = storage
    }

    private var cachedEvents = [Event]()

}

extension OptimoveQueue: Queue {

    var eventCount: Int {
        return cachedEvents.count
    }

    func enqueue(events: [Event], completion: (() -> Void)?) {
        OptiLoggerMessages.logAddEventsFromQueue()
        cachedEvents.append(contentsOf: events)
        do {
            try storage.save(
                data: cachedEvents,
                toFileName: TrackerConstants.pendingEventsFile,
                shared: TrackerConstants.isSharedStorage
            )
        } catch {
            OptiLoggerMessages.logEventsfileCouldNotLoad()
        }
        completion?()
    }

    func first(limit: Int, completion: ([Event]) -> Void) {
        let amount = limit <= eventCount ? limit : eventCount
        let dequeuedItems = Array(cachedEvents[0..<amount])
        completion(dequeuedItems)
    }

    func remove(events: [Event], completion: () -> Void) {
        OptiLoggerMessages.logRemoveEventsFromQueue()
        cachedEvents = cachedEvents.filter { cachedEvent in
            !events.contains(cachedEvent)
        }
        do {
            try storage.save(
                data: cachedEvents,
                toFileName: TrackerConstants.pendingEventsFile,
                shared: TrackerConstants.isSharedStorage
            )
        } catch {
            OptiLoggerMessages.logEventFileSaveFailure()
        }
        completion()
    }
}

extension Event: Equatable {

    public static func == (lhs: Event, rhs: Event) -> Bool {
        return lhs.uuid == rhs.uuid
    }

}
