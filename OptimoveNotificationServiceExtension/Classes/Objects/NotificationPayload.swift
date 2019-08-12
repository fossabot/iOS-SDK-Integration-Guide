// Copiright 2019 Optimove

import Foundation

// MARK: - NotificationPayload

struct NotificationPayload: Decodable {
    let title: String
    let content: String
    let dynamicLinks: DynamicLinks
    let deepLinkPersonalization: DeeplinkPersonalization?
    let campaign: NotificationCampaign
    let collapseKey: String?
    let isOptipush: Bool
    let media: MediaAttachment?
    let userAction: UserAction?
    
    enum CodingKeys: String, CodingKey {
        case title
        case content
        case dynamicLinks = "dynamic_links"
        case deepLinkPersonalization = "deep_link_personalization_values"
        case campaign
        case campaignID = "campaign_id"
        case actionSerial = "action_serial"
        case templateID = "template_id"
        case engagementID = "engagement_id"
        case campaignType = "campaign_type"
        case collapseKey = "collapse_Key"
        case isOptipush = "is_optipush"
        case media
        case userAction = "user_action"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decode(String.self, forKey: .title)
        self.content = try container.decode(String.self, forKey: .content)
        self.dynamicLinks = try DynamicLinks(firebaseFrom: decoder)
        self.deepLinkPersonalization = try? DeeplinkPersonalization(firebaseFrom: decoder)
        let campaignContainer = try container.nestedContainer(keyedBy: NotificationCampaignType.self, forKey: .campaign)
        switch campaignContainer.allKeys {
        case [NotificationCampaignType.scheduled]:
            campaign = try campaignContainer.decode(ScheduledNotificationCampaign.self, forKey: .scheduled)
        case [NotificationCampaignType.triggered]:
            campaign = try campaignContainer.decode(TriggeredNotificationCampaign.self, forKey: .triggered)
        default:
            throw DecodingError.valueNotFound(
                NotificationCampaign.self,
                DecodingError.Context(
                    codingPath: campaignContainer.codingPath,
                    debugDescription:
                    """
                    Unable to find a supported Notification campaign type.
                    Supported types: \(NotificationCampaignType.allCases.map { $0.rawValue })
                    """
                )
            )
        }
        self.collapseKey = try container.decodeIfPresent(String.self, forKey: .collapseKey)
        self.isOptipush = try container.decode(StringCodableMap<Bool>.self, forKey: .isOptipush).decoded
        self.media = try? MediaAttachment(firebaseFrom: decoder)
        self.userAction = try? UserAction(firebaseFrom: decoder)
    }
}

// MARK: - Notification campaign

enum NotificationCampaignType: String, CodingKey, CaseIterable {
    case scheduled
    case triggered
}

protocol NotificationCampaign: Codable {
    var type: NotificationCampaignType { get }
}

struct TriggeredNotificationCampaign: NotificationCampaign {
    let type: NotificationCampaignType = .triggered
    let actionSerial: Int
    let actionID: Int
    let templateID: Int

    enum CodingKeys: String, CodingKey {
        case actionSerial = "action_serial"
        case actionID = "action_id"
        case templateID = "template_id"
    }
}

struct ScheduledNotificationCampaign: NotificationCampaign {
    let type: NotificationCampaignType = .scheduled
    let campaignID: Int
    let actionSerial: Int
    let templateID: Int
    let engagementID: Int
    let campaignType: Int

    enum CodingKeys: String, CodingKey {
        case campaignID = "campaign_id"
        case actionSerial = "action_serial"
        case templateID = "template_id"
        case engagementID = "engagement_id"
        case campaignType = "campaign_type"
    }
    
}

struct DeeplinkPersonalization: Decodable {
    let values: [String: String]

    /// The custom decoder does preprocess before the primary decoder.
    init(firebaseFrom decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NotificationPayload.CodingKeys.self)
        let string = try container.decode(String.self, forKey: .deepLinkPersonalization)
        let data: Data = try cast(string.data(using: .utf8))
        values = try JSONDecoder().decode([String: String].self, from: data)
    }
}


// MARK: - Dynamic links

struct DynamicLinks: Decodable {
    let ios: [String: URL]
    let android: [String: URL]

    /// The custom decoder does preprocess before the primary decoder.
    init(firebaseFrom decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NotificationPayload.CodingKeys.self)
        let string = try container.decode(String.self, forKey: .dynamicLinks)
        let data: Data = try cast(string.data(using: .utf8))
        self = try JSONDecoder().decode(DynamicLinks.self, from: data)
    }
}


// MARK: - Media

struct MediaAttachment: Decodable {
    let url: URL
    let mediaType: MediaType
    
    enum MediaType: String, Codable {
        case image
        case video
        case gif
    }
    
    enum CodingKeys: String, CodingKey {
        case url
        case mediaType = "media_type"
    }

    /// The custom decoder does preprocess before the primary decoder.
    init(firebaseFrom decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NotificationPayload.CodingKeys.self)
        let string = try container.decode(String.self, forKey: .media)
        let data: Data = try cast(string.data(using: .utf8))
        self = try JSONDecoder().decode(MediaAttachment.self, from: data)
    }

}

// MARK: - UserAction

struct UserAction: Decodable {
    let categoryIdentifier: String
    let actions: [Action]
    
    enum CodingKeys: String, CodingKey {
        case categoryIdentifier = "category_identifier"
        case actions = "actions"
    }

    /// The custom decoder does preprocess before the primary decoder.
    init(firebaseFrom decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NotificationPayload.CodingKeys.self)
        let string = try container.decode(String.self, forKey: .userAction)
        let data: Data = try cast(string.data(using: .utf8))
        self = try JSONDecoder().decode(UserAction.self, from: data)
    }
}

// MARK: - Action

struct Action: Decodable {
    let identifier: String
    let title: String
    let deeplink: String?
}

/// https://stackoverflow.com/a/44596291
struct StringCodableMap<Decoded: LosslessStringConvertible> : Codable {

    var decoded: Decoded

    init(_ decoded: Decoded) {
        self.decoded = decoded
    }

    init(from decoder: Decoder) throws {

        let container = try decoder.singleValueContainer()
        let decodedString = try container.decode(String.self)

        guard let decoded = Decoded(decodedString) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: """
                The string \(decodedString) is not representable as a \(Decoded.self)
                """
            )
        }

        self.decoded = decoded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(decoded.description)
    }
}