import Foundation
import LoggingDomain
import TartCommon

extension Logger {
    func info(
        _ message: String,
        job: RouterPendingJob? = nil,
        host: TartHost? = nil,
        labels: Set<String>? = nil,
        error: Error? = nil,
        _ additionalParameters: [String: String]? = nil
    ) {
        info(message, parameters: buildParameters(
            job: job,
            host: host,
            labels: labels,
            error: error,
            additionalParameters
        ))
    }

    func error(
        _ message: String,
        job: RouterPendingJob? = nil,
        host: TartHost? = nil,
        labels: Set<String>? = nil,
        error: Error? = nil,
        _ additionalParameters: [String: String]? = nil
    ) {
        self.error(message, parameters: buildParameters(
            job: job,
            host: host,
            labels: labels,
            error: error,
            additionalParameters
        ))
    }

    private func buildParameters(
        job: RouterPendingJob? = nil,
        host: TartHost? = nil,
        labels: Set<String>? = nil,
        error: Error? = nil,
        _ additionalParameters: [String: String]? = nil
    ) -> [String: String]? {
        var params = [String: String]()

        if let job {
            params[LogParameterKey.jobId] = "\(job.id)"
            params[LogParameterKey.workflowJobId] = "\(job.workflowJob.id)"
            params[LogParameterKey.jobAction] = job.workflowJob.action.rawValue
            params[LogParameterKey.labels] = job.workflowJob.labels.joined(separator: ",")
        }

        if let host {
            params[LogParameterKey.hostname] = host.hostname
            params[LogParameterKey.url] = host.url.absoluteString
        }

        if let labels {
            params[LogParameterKey.labels] = labels.joined(separator: ",")
        }

        if let error {
            params[LogParameterKey.error] = error.localizedDescription
        }

        if let additionalParameters {
            params.merge(additionalParameters) { _, new in new }
        }

        return params.isEmpty ? nil : params
    }
}
