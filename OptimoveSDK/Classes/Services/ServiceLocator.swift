// Copiright 2019 Optimove

import Foundation

final class ServiceLocator {

    // MARK: - Singletons

    /// Keeps as singleton in reason to share a session state between a service consumers.
    private lazy var _deviceStateMonitor: OptimoveDeviceStateMonitor = {
        return OptimoveDeviceStateMonitorImpl(
            fetcherFactory: DeviceRequirementFetcherFactoryImpl()
        )
    }()

    /// Keeps as singleton in reason to share a session state between a service consumers.
    private lazy var _warehouseProvider: EventsConfigWarehouseProvider = {
        return EventsConfigWarehouseProvider()
    }()

    /// Keeps as singleton in reason to share a session state between a service consumers.
    private lazy var _notificationListener: OptimoveNotificationHandler = {
        return OptimoveNotificationHandler(
            storage: storage(),
            coreEventFactory: CoreEventFactoryImpl(
                storage: storage(),
                dateTimeProvider: dateTimeProvider()
            ),
            optimove: Optimove.shared
        )
    }()

    /// Keeps as singleton in reason to share a session state between a service consumers.
    private lazy var _storage: OptimoveStorageFacade = {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            fatalError("The `CFBundleIdentifier` key is not defined in the bundle’s information property list.")
        }
        guard let groupStorage = UserDefaults(suiteName: "group.\(bundleIdentifier).optimove") else {
            fatalError("If this line is crashing the client forgot to add the app group as described in the documentation.")
        }
        return OptimoveStorageFacade(
            sharedStorage: UserDefaults.standard,
            groupStorage: groupStorage,
            fileStorage: OptimoveFileManager(
                fileManager: .default
            )
        )
    }()

    /// Keeps as singleton in reason to share a session state between a service consumers.
    private lazy var _statisticService: StatisticService = {
        return StatisticServiceImpl()
    }()

    /// Keeps as singleton in reason to share a session state between a service consumers.
    private lazy var _componentsPool: MutableComponentsPool = {
        return ComponentsPoolImpl(
            componentFactory: componentFactory()
        )
    }()

    // MARK: - Functions

    func storage() -> OptimoveStorage {
        return _storage
    }

    func networking() -> NetworkClient {
        return NetworkClientImpl(configuration: .default)
    }

    func warehouseProvider() -> EventsConfigWarehouseProvider {
        return _warehouseProvider
    }

    func deviceStateMonitor() -> OptimoveDeviceStateMonitor {
        return _deviceStateMonitor
    }

    func notificationListener() -> OptimoveNotificationHandling {
        return _notificationListener
    }

    func dateTimeProvider() -> DateTimeProvider {
        return DateTimeProviderImpl()
    }

    func statisticService() -> StatisticService {
        return _statisticService
    }

    func networkClient() -> NetworkClient {
        return NetworkClientImpl()
    }

    func configurationRepository() -> ConfigurationRepository {
        return ConfigurationRepositoryImpl(storage: storage())
    }

    func initializer() -> OptimoveSDKInitializer {
        let networkingFactory = NetworkingFactory(
            networkClient: NetworkClientImpl(),
            requestBuilderFactory: NetworkRequestBuilderFactory(
                serviceLocator: self
            )
        )
        return OptimoveSDKInitializer(
            deviceStateMonitor: deviceStateMonitor(),
            warehouseProvider: warehouseProvider(),
            storage: storage(),
            networking: networkingFactory.createRemoteConfigurationNetworking(),
            configurationRepository: configurationRepository(),
            componentFactory: componentFactory(),
            componentsPool: mutableComponentsPool()
        )
    }

    // FIXME: Move to Main factory
    func componentFactory() -> ComponentFactory {
        return ComponentFactory(
            serviceLocator: self,
            coreEventFactory: CoreEventFactoryImpl(
                storage: storage(),
                dateTimeProvider: dateTimeProvider()
            )
        )
    }

    func componentsPool() -> ComponentsPool {
        return _componentsPool
    }

    func mutableComponentsPool() -> MutableComponentsPool {
        return _componentsPool
    }

}