// Copiright 2017 Optimove

enum MbaasOperation: String, Codable, CaseIterable {
    case registration = "registration_data"
    case unregistration = "unregistration_data"
    case optOut = "opt_out"
    case optIn = "opt_in"
}
