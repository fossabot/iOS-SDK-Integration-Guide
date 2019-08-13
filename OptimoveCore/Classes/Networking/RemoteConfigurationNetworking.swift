//  Copyright © 2019 Optimove. All rights reserved.

import Foundation

public final class RemoteConfigurationNetworking {

    private let networkClient: NetworkClient
    private let requestBuilder: RemoteConfigurationRequestBuilder

    public init(networkClient: NetworkClient,
         requestBuilder: RemoteConfigurationRequestBuilder) {
        self.networkClient = networkClient
        self.requestBuilder = requestBuilder
    }

    public func getTenantConfiguration(_ completion: @escaping (Result<TenantConfig, Error>) -> Void) {
        do {
            let request = try requestBuilder.createTenantConfigurationsRequest()
            networkClient.perform(request) { (result) in
                completion(
                    Result {
                        return try result.get().decode(to: TenantConfig.self)
                    }
                )
            }
        } catch {
            completion(.failure(error))
        }
    }

    public func getGlobalConfiguration(_ completion: @escaping (Result<GlobalConfig, Error>) -> Void) {
        let request = requestBuilder.createGlobalConfigurationsRequest()
        networkClient.perform(request) { (result) in
            completion(
                Result {
                    return try result.get().decode(to: GlobalConfig.self)
                }
            )
        }
    }

}