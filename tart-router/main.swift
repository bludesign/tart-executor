import EnvironmentSettings
import Foundation
import RouterApp

let environment = try RouterEnvironment()
let composer = RouterComposer(environment: environment)

try await composer.run()
