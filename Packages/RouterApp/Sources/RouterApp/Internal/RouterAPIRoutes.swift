import FlyingFox
import Foundation
import TartCommon

extension RouterServer {
    /// Registers the `/api/v1/*` management & debugging routes on the shared HTTP server.
    /// All routes except `health`, `openapi.yaml`, and `docs` require the bearer token when one
    /// is configured.
    func registerManagementRoutes(on server: HTTPServer) async {
        // MARK: Health & status

        await server.appendRoute("GET /api/v1/health") { [weak self] _ in
            guard let self else { return .init(statusCode: .badGateway) }
            let now = Date()
            let health = HealthResponse(
                service: "tart-router",
                version: TartVersion.current,
                startedAt: startedAt,
                uptimeSeconds: now.timeIntervalSince(startedAt)
            )
            return .json(health, encoder: apiEncoder)
        }

        await server.appendRoute("GET /api/v1/status") { [weak self] request in
            guard let self else { return .init(statusCode: .badGateway) }
            if let denied = authorizationFailure(for: request) { return denied }
            let counts = await jobHandler.statusCounts()
            let response = RouterStatusResponse(
                hostname: hostname,
                pendingJobs: counts.pendingJobs,
                pendingJobsUnsent: counts.pendingJobsUnsent,
                pendingJobsQueued: counts.pendingJobsQueued,
                availableVirtualMachines: counts.availableVirtualMachines,
                availableHosts: counts.availableHosts
            )
            return .json(response, encoder: apiEncoder)
        }

        await server.appendRoute("GET /api/v1/settings") { [weak self] request in
            guard let self else { return .init(statusCode: .badGateway) }
            if let denied = authorizationFailure(for: request) { return denied }
            let response = RouterSettingsResponse(
                hostname: hostname,
                labels: labels.sorted(),
                port: listeningPort,
                loggingEndpoint: nil,
                authEnabled: apiToken?.isEmpty == false,
                hosts: hosts.map { host in
                    RouterHostConfigDTO(
                        hostname: host.hostname,
                        url: host.url.absoluteString,
                        priority: host.priority,
                        cpuLimit: host.cpuLimit,
                        memoryLimit: host.memoryLimit
                    )
                }
            )
            return .json(response, encoder: apiEncoder)
        }

        // MARK: Jobs

        await server.appendRoute("GET /api/v1/jobs") { [weak self] request in
            guard let self else { return .init(statusCode: .badGateway) }
            if let denied = authorizationFailure(for: request) { return denied }
            let jobs = await jobHandler.jobsSnapshot()
            return .json(RouterJobsResponse(jobs: jobs), encoder: apiEncoder)
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
            let cancelled = await jobHandler.cancelJob(id: id)
            let response = CancelResponse(cancelled: cancelled, cancelledCount: cancelled ? 1 : 0)
            return .json(response, statusCode: cancelled ? .ok : .notFound, encoder: apiEncoder)
        }

        await server.appendRoute("POST /api/v1/jobs/cancel") { [weak self] request in
            guard let self else { return .init(statusCode: .badGateway) }
            if let denied = authorizationFailure(for: request) { return denied }
            do {
                let bodyData = try await request.bodyData
                let cancelRequest = try apiDecoder.decode(CancelJobsRequest.self, from: bodyData)
                await jobHandler.cancelJobsWithLabels(cancelRequest.labels)
                return .json(CancelResponse(cancelled: true), encoder: apiEncoder)
            } catch {
                return .jsonError("Invalid request body", statusCode: .badRequest)
            }
        }

        // MARK: Executors (hosts)

        await server.appendRoute("GET /api/v1/hosts") { [weak self] request in
            guard let self else { return .init(statusCode: .badGateway) }
            if let denied = authorizationFailure(for: request) { return denied }
            let hosts = await jobHandler.hostsSnapshot()
            return .json(RouterHostsResponse(hosts: hosts), encoder: apiEncoder)
        }

        await server.appendRoute("GET /api/v1/hosts/:hostname") { [weak self] request in
            guard let self else { return .init(statusCode: .badGateway) }
            if let denied = authorizationFailure(for: request) { return denied }
            guard let hostname = request.routeParameters["hostname"] else {
                return .jsonError("Invalid hostname", statusCode: .badRequest)
            }
            guard let host = await jobHandler.host(named: hostname) else {
                return .jsonError("Host not found", statusCode: .notFound)
            }
            return .json(host, encoder: apiEncoder)
        }

        await server.appendRoute("POST /api/v1/hosts/refresh") { [weak self] request in
            guard let self else { return .init(statusCode: .badGateway) }
            if let denied = authorizationFailure(for: request) { return denied }
            await jobHandler.updateStatus()
            return .init(statusCode: .accepted)
        }

        // MARK: OpenAPI spec & docs

        await server.appendRoute("GET /api/v1/openapi.yaml") { _ in
            guard let url = Bundle.module.url(forResource: "openapi", withExtension: "yaml"),
                  let data = try? Data(contentsOf: url) else {
                return APIDocs.specNotFound()
            }
            return APIDocs.yamlResponse(data)
        }

        await server.appendRoute("GET /api/v1/docs") { _ in
            APIDocs.redocResponse(title: "tart-router API")
        }
    }

    /// Returns a `401` response when a token is configured and the request is not authorized,
    /// otherwise `nil`.
    func authorizationFailure(for request: HTTPRequest) -> HTTPResponse? {
        guard APIAuth.isAuthorized(authorizationHeader: request.headers[.authorization], token: apiToken) else {
            return .jsonError("Unauthorized", statusCode: .unauthorized)
        }
        return nil
    }
}
