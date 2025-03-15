import EnvironmentSettings
import ExecutorApp
import Foundation

extension Environment: @retroactive ExecutorEnvironment {}

let environment = try Environment()
let composer = ExecutorComposer(environment: environment)

try await composer.run()
