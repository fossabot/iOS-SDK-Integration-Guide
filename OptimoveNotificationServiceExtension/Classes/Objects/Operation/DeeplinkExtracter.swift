// Copiright 2019 Optimove

import Foundation
import UserNotifications
import os

final class DeeplinkExtracter: AsyncOperation {
    
    private struct Constants {
        static let dynamicLinksKey = "dynamic_link"
    }
    
    private let bundleIdentifier: String
    private let notificationPayload: NotificationPayload
    private let bestAttemptContent: UNMutableNotificationContent
    
    init(bundleIdentifier: String,
         notificationPayload: NotificationPayload,
         bestAttemptContent: UNMutableNotificationContent) {
        self.bundleIdentifier = bundleIdentifier
        self.notificationPayload = notificationPayload
        self.bestAttemptContent = bestAttemptContent
    }
    
    override func main() {
        state = .executing
        
        let appKey = bundleIdentifier.replacingOccurrences(of: ".", with: "_")
        guard let url = notificationPayload.dynamicLinks?.ios?[appKey] else {
            os_log("Found no url for this app", log: OSLog.extracter, type: .error)
            state = .finished
            return
        }
        DynamicLinkParser(parsingCallback: parserHandler).parse(url)
    }
    
}

private extension DeeplinkExtracter {
    
    func parserHandler(result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            var urlString = replaceSpecialSymbols(in: url)
            let campaignDetails = notificationPayload.campaignDetails
            let urlQueryAllowedSet = CharacterSet.urlQueryAllowed
            let alphanumericsSet = CharacterSet.alphanumerics
            if let value = notificationPayload.deepLinkPersonalization?.values {
                for (key, value) in value {
                    guard let percentKey = key.addingPercentEncoding(withAllowedCharacters: urlQueryAllowedSet) else {
                        continue
                    }
                    guard let percentValue = value.addingPercentEncoding(withAllowedCharacters: alphanumericsSet) else {
                        if let campaignDetails = campaignDetails {
                            // ELI: TODO: REplace campaign details
                            if campaignDetails.campaignId > 0 {  // This is not Test campaign, any non-string values must be replaced with empty string
                                urlString = urlString.replacingOccurrences(of: percentKey, with: "")
                                continue
                            }  // This is a test campaign PN, tags must stay as keys
                        }
                        continue
                    }
                    urlString = urlString.replacingOccurrences(of: percentKey, with: percentValue)
                }
            }
            os_log("Dynamic links were updated.", log: OSLog.extracter, type: .debug)
            bestAttemptContent.userInfo[Constants.dynamicLinksKey] = urlString
            
        case let .failure(error):
            os_log("Error: %{PRIVATE}@", log: OSLog.extracter, type: .error, error.localizedDescription)
        }
        state = .finished
    }
    
    func replaceSpecialSymbols(in url: URL) -> String {
        let urlString = url.absoluteString
        if let query = url.query {
            let replacingQuery = query.replacingOccurrences(of: "+", with: "%20")
            return urlString.replacingOccurrences(of: query, with: replacingQuery)
        }
        return urlString
    }

}

extension OSLog {
    static let extracter = OSLog(subsystem: subsystem, category: "extracter")
}
