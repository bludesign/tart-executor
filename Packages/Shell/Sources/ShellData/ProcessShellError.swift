import Foundation

public enum ProcessShellError: LocalizedError {
   case unexpectedTerminationStatus(
       Int32,
       executablePath: String,
       arguments: [String],
       environment: [String: String],
       result: String
   )

   public var errorDescription: String? {
       switch self {
       case let .unexpectedTerminationStatus(
           terminationStatus,
           executablePath,
           arguments,
           environment,
           result
       ):
            "Unexpected termination status: \(terminationStatus), Executable: \(executablePath), Arguments: \(arguments.joined(separator: " ")), Environment: \(environment.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")), Result: \(result)"
       }
   }
}
