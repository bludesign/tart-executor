import FlyingFox
import Foundation
import TartCommon

extension ExecutorServer {
    /// Registers the `/api/v1/*` management & debugging routes on the shared HTTP server.
    /// All routes except `health`, `openapi.yaml`, and `docs` require the bearer token when one
    /// is configured.
    func registerManagementRoutes(on server: HTTPServer) async {
        // MARK: Health & status

        await server.appendRoute("GET /api/v1/health") { [weak self] _ in
            guard let self else { return .init(statusCode: .badGateway) }
            let now = Date()
            let health = HealthResponse(
                service: "tart-executor",
                version: TartVersion.current,
                startedAt: startedAt,
                uptimeSeconds: now.timeIntervalSince(startedAt)
            )
            return .json(health, encoder: apiEncoder)
        }

        await server.appendRoute("GET /api/v1/status") { [weak self] request in
            guard let self else { return .init(statusCode: .badGateway) }
            if let denied = authorizationFailure(for: request) { return denied }
            let jobStatus = await jobHandler.jobStatus
            let response = ExecutorStatusResponse(
                hostname: settings.hostname,
                inProgressJobs: jobStatus.inProgressJobs,
                pendingJobs: jobStatus.pendingJobs,
                startedPendingJobs: jobStatus.startedPendingJobs,
                activeVirtualMachines: jobStatus.virtualMachines,
                virtualMachineLimit: settings.numberOfMachines,
                cpuLimit: settings.cpuLimit,
                cpuUsed: jobStatus.cpuUsed,
                totalMemory: settings.totalMemory,
                memoryUsed: jobStatus.memoryUsed
            )
            return .json(response, encoder: apiEncoder)
        }

        await server.appendRoute("GET /api/v1/settings") { [weak self] request in
            guard let self else { return .init(statusCode: .badGateway) }
            if let denied = authorizationFailure(for: request) { return denied }
            let response = ExecutorSettingsResponse(
                hostname: settings.hostname,
                numberOfMachines: settings.numberOfMachines,
                runnerLabels: settings.runnerLabels,
                webhookPort: settings.webhookPort,
                routerUrl: settings.routerUrl,
                localUrl: settings.localUrl,
                isHeadless: settings.isHeadless,
                isInsecure: settings.isInsecure,
                insecureDomains: settings.insecureDomains,
                netBridgedAdapter: settings.netBridgedAdapter,
                defaultCpu: settings.defaultCpu,
                defaultMemory: settings.defaultMemory,
                cpuLimit: settings.cpuLimit,
                totalMemory: settings.totalMemory,
                loggingEndpoint: settings.loggingEndpoint,
                authEnabled: settings.apiToken?.isEmpty == false
            )
            return .json(response, encoder: apiEncoder)
        }

        // MARK: Jobs

        await server.appendRoute("GET /api/v1/jobs") { [weak self] request in
            guard let self else { return .init(statusCode: .badGateway) }
            if let denied = authorizationFailure(for: request) { return denied }
            var jobs = await jobHandler.jobsSnapshot()
            if let stateValue = request.query["state"] {
                guard let state = ExecutorJobState(rawValue: stateValue) else {
                    return .jsonError("Invalid state filter", statusCode: .badRequest)
                }
                jobs = jobs.filter { $0.state == state }
            }
            return .json(ExecutorJobsResponse(jobs: jobs), encoder: apiEncoder)
        }

        await server.appendRoute("GET /api/v1/jobs/:id") { [weak self] request in
            guard let self else { return .init(statusCode: .badGateway) }
            if let denied = authorizationFailure(for: request) { return denied }
            guard let id = request.routeParameters["id", of: Int.self] else {
                return .jsonError("Invalid job id", statusCode: .badRequest)
            }
            guard let job = await jobHandler.job(id: id) else {
                return .jsonError("Job not found", statusCode: .notFound)
            }
            return .json(job, encoder: apiEncoder)
        }

        await server.appendRoute("POST /api/v1/jobs/:id/cancel") { [weak self] request in
            guard let self else { return .init(statusCode: .badGateway) }
            if let denied = authorizationFailure(for: request) { return denied }
            guard let id = request.routeParameters["id", of: Int.self] else {
                return .jsonError("Invalid job id", statusCode: .badRequest)
            }
            let cancelled = await jobHandler.cancel(jobId: id)
            let response = CancelResponse(cancelled: cancelled, cancelledCount: cancelled ? 1 : 0)
            return .json(response, statusCode: cancelled ? .ok : .notFound, encoder: apiEncoder)
        }

        await server.appendRoute("POST /api/v1/jobs/cancel") { [weak self] request in
            guard let self else { return .init(statusCode: .badGateway) }
            if let denied = authorizationFailure(for: request) { return denied }
            do {
                let bodyData = try await request.bodyData
                let cancelRequest = try apiDecoder.decode(CancelJobsRequest.self, from: bodyData)
                let count = await jobHandler.cancelJobsByLabels(cancelRequest.labels)
                return .json(CancelResponse(cancelled: count > 0, cancelledCount: count), encoder: apiEncoder)
            } catch {
                return .jsonError("Invalid request body", statusCode: .badRequest)
            }
        }

        await server.appendRoute("POST /api/v1/jobs/cancel-all") { [weak self] request in
            guard let self else { return .init(statusCode: .badGateway) }
            if let denied = authorizationFailure(for: request) { return denied }
            await jobHandler.cancelAll()
            return .json(CancelResponse(cancelled: true), encoder: apiEncoder)
        }

        // MARK: Virtual machines & images

        await server.appendRoute("GET /api/v1/vms") { [weak self] request in
            guard let self else { return .init(statusCode: .badGateway) }
            if let denied = authorizationFailure(for: request) { return denied }
            do {
                let names = try await virtualMachineProvider.listVirtualMachines()
                let vms = names.map { self.virtualMachineDTO(name: $0, ipAddress: nil) }
                return .json(VirtualMachineListResponse(virtualMachines: vms), encoder: apiEncoder)
            } catch {
                return .jsonError("Failed to list virtual machines", statusCode: .init(500, phrase: "Internal Server Error"))
            }
        }

        await server.appendRoute("GET /api/v1/vms/:name") { [weak self] request in
            guard let self else { return .init(statusCode: .badGateway) }
            if let denied = authorizationFailure(for: request) { return denied }
            guard let name = request.routeParameters["name"] else {
                return .jsonError("Invalid virtual machine name", statusCode: .badRequest)
            }
            let names = (try? await virtualMachineProvider.listVirtualMachines()) ?? []
            guard names.contains(name) else {
                return .jsonError("Virtual machine not found", statusCode: .notFound)
            }
            let ipAddress = try? await virtualMachineProvider.ipAddress(ofVirtualMachineNamed: name)
            return .json(virtualMachineDTO(name: name, ipAddress: ipAddress), encoder: apiEncoder)
        }

        await server.appendRoute("DELETE /api/v1/vms/:name") { [weak self] request in
            guard let self else { return .init(statusCode: .badGateway) }
            if let denied = authorizationFailure(for: request) { return denied }
            guard let name = request.routeParameters["name"] else {
                return .jsonError("Invalid virtual machine name", statusCode: .badRequest)
            }
            do {
                try await virtualMachineProvider.deleteVirtualMachine(name: name)
                return .init(statusCode: .noContent)
            } catch {
                return .jsonError("Failed to delete virtual machine", statusCode: .init(500, phrase: "Internal Server Error"))
            }
        }

        await server.appendRoute("POST /api/v1/images/pull") { [weak self] request in
            guard let self else { return .init(statusCode: .badGateway) }
            if let denied = authorizationFailure(for: request) { return denied }
            let pullRequest: ImagePullRequest
            do {
                let bodyData = try await request.bodyData
                pullRequest = try apiDecoder.decode(ImagePullRequest.self, from: bodyData)
            } catch {
                return .jsonError("Invalid request body", statusCode: .badRequest)
            }
            do {
                try await virtualMachineProvider.pullImage(
                    name: pullRequest.name,
                    isInsecure: pullRequest.isInsecure ?? settings.isInsecure
                )
                return .json(["status": "pulled", "name": pullRequest.name], encoder: apiEncoder)
            } catch {
                return .jsonError("Failed to pull image", statusCode: .init(500, phrase: "Internal Server Error"))
            }
        }

        // MARK: OpenAPI spec & docs

        await server.appendRoute("GET /api/v1/openapi.yaml") { _ in
            APIDocs.yamlResponse(Data(OpenAPISpec.yaml.utf8))
        }

        await server.appendRoute("GET /api/v1/docs") { _ in
            APIDocs.redocResponse(title: "tart-executor API")
        }
    }

    /// Returns a `401` response when a token is configured and the request is not authorized,
    /// otherwise `nil`.
    func authorizationFailure(for request: HTTPRequest) -> HTTPResponse? {
        guard APIAuth.isAuthorized(authorizationHeader: request.headers[.authorization], token: settings.apiToken) else {
            return .jsonError("Unauthorized", statusCode: .unauthorized)
        }
        return nil
    }

    /// Builds a `VirtualMachineDTO`, deriving the owning job id for executor-managed VMs whose
    /// name follows the `tart-executor-<jobId>-<uuid>` convention.
    func virtualMachineDTO(name: String, ipAddress: String?) -> VirtualMachineDTO {
        let prefix = ExecutorConstants.virtualMachineNamePrefix
        guard name.hasPrefix(prefix) else {
            return VirtualMachineDTO(name: name, ipAddress: ipAddress, jobId: nil, managedByExecutor: false)
        }
        let remainder = name.dropFirst(prefix.count)
        let jobIdText = remainder.prefix { $0 != "-" }
        return VirtualMachineDTO(name: name, ipAddress: ipAddress, jobId: Int(jobIdText), managedByExecutor: true)
    }
}
