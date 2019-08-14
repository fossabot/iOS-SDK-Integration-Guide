//  Copyright © 2017 Optimove.

public struct EventsConfig: Codable {
    public let id: Int
    public let supportedOnOptitrack: Bool
    public let supportedOnRealTime: Bool
    public let parameters: [String: Parameter]

    public init(
        id: Int,
        supportedOnOptitrack: Bool,
        supportedOnRealTime: Bool,
        parameters: [String: Parameter]) {
        self.id = id
        self.supportedOnOptitrack = supportedOnOptitrack
        self.supportedOnRealTime = supportedOnRealTime
        self.parameters = parameters
    }
}
