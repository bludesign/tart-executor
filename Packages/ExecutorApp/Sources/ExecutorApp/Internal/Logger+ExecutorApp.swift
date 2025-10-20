import Foundation
import LoggingDomain
import TartCommon
import VirtualMachineDomain

extension Logger {
    func info(
        _ message: String,
        pendingJob: ExecutorPendingJob? = nil,
        virtualMachine: VirtualMachine? = nil,
        uuid: UUID? = nil,
        error: Error? = nil,
        runError: Error? = nil,
        deleteError: Error? = nil,
        _ additionalParameters: [String: String]? = nil
    ) {
        info(message, parameters: buildParameters(
            pendingJob: pendingJob,
            virtualMachine: virtualMachine,
            uuid: uuid,
            error: error,
            runError: runError,
            deleteError: deleteError,
            additionalParameters
        ))
    }

    func error(
        _ message: String,
        pendingJob: ExecutorPendingJob? = nil,
        virtualMachine: VirtualMachine? = nil,
        uuid: UUID? = nil,
        error: Error? = nil,
        runError: Error? = nil,
        deleteError: Error? = nil,
        _ additionalParameters: [String: String]? = nil
    ) {
        self.error(message, parameters: buildParameters(
            pendingJob: pendingJob,
            virtualMachine: virtualMachine,
            uuid: uuid,
            error: error,
            runError: runError,
            deleteError: deleteError,
            additionalParameters
        ))
    }

    private func buildParameters(
        pendingJob: ExecutorPendingJob? = nil,
        virtualMachine: VirtualMachine? = nil,
        uuid: UUID? = nil,
        error: Error? = nil,
        runError: Error? = nil,
        deleteError: Error? = nil,
        _ additionalParameters: [String: String]? = nil
    ) -> [String: String]? {
        var params = [String: String]()

        if let pendingJob {
            params[LogParameterKey.jobId] = "\(pendingJob.id)"
            params[LogParameterKey.workflowJobId] = "\(pendingJob.workflowJob.id)"
            params[LogParameterKey.imageName] = pendingJob.imageName
        }

        if let virtualMachine {
            params[LogParameterKey.vmName] = virtualMachine.name
        }

        if let uuid {
            params[LogParameterKey.uuid] = uuid.uuidString
        }

        if let error {
            params[LogParameterKey.error] = error.localizedDescription
        }

        if let runError {
            params[LogParameterKey.runError] = runError.localizedDescription
        }

        if let deleteError {
            params[LogParameterKey.deleteError] = deleteError.localizedDescription
        }

        if let additionalParameters {
            params.merge(additionalParameters) { _, new in new }
        }

        return params.isEmpty ? nil : params
    }
}
