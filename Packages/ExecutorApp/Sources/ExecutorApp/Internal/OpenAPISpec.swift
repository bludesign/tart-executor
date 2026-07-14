// Generated from Packages/ExecutorApp/Sources/ExecutorApp/Resources/openapi.yaml by scripts/generate-openapi-spec.sh. Do not edit by hand.
// swiftlint:disable all
enum OpenAPISpec {
    static let yaml = #"""
openapi: 3.1.0
info:
  title: tart-executor management API
  description: >-
    Management & debugging API for a tart-executor instance. Exposes job introspection and
    control, Tart virtual-machine and image management, effective settings, and health.


    When an `apiToken` is configured in `~/tart-executor.yaml`, every `/api/v1/*` endpoint
    except `/health`, `/openapi.yaml`, and `/docs` requires an
    `Authorization: Bearer <token>` header.
  version: 0.24.0
servers:
  - url: /api/v1
    description: Served on the executor's webhook port (see `webhook.port`, e.g. 3250).
security:
  - bearerAuth: []
tags:
  - name: Health
  - name: Jobs
  - name: Virtual Machines
  - name: Settings
paths:
  /health:
    get:
      tags: [Health]
      summary: Liveness and version
      security: []
      responses:
        "200":
          description: Service is up.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/HealthResponse"
  /status:
    get:
      tags: [Health]
      summary: Current job and capacity status
      responses:
        "200":
          description: Status snapshot.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/ExecutorStatusResponse"
        "401": { $ref: "#/components/responses/Unauthorized" }
  /settings:
    get:
      tags: [Settings]
      summary: Effective settings (secrets redacted)
      responses:
        "200":
          description: The executor's effective configuration. Secrets are never included.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/ExecutorSettingsResponse"
        "401": { $ref: "#/components/responses/Unauthorized" }
  /jobs:
    get:
      tags: [Jobs]
      summary: List tracked jobs
      parameters:
        - name: state
          in: query
          required: false
          description: Optional lifecycle filter.
          schema:
            $ref: "#/components/schemas/ExecutorJobState"
      responses:
        "200":
          description: The jobs currently tracked by the executor.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/ExecutorJobsResponse"
        "400": { $ref: "#/components/responses/BadRequest" }
        "401": { $ref: "#/components/responses/Unauthorized" }
  /jobs/{id}:
    get:
      tags: [Jobs]
      summary: Get a single job
      parameters:
        - $ref: "#/components/parameters/JobId"
      responses:
        "200":
          description: The job.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/ExecutorJobDTO"
        "400": { $ref: "#/components/responses/BadRequest" }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "404": { $ref: "#/components/responses/NotFound" }
  /jobs/{id}/cancel:
    post:
      tags: [Jobs]
      summary: Cancel a single job by id
      description: Cancels any running VM task for the job and drops it from the queues.
      parameters:
        - $ref: "#/components/parameters/JobId"
      responses:
        "200":
          description: The job was cancelled.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/CancelResponse"
        "401": { $ref: "#/components/responses/Unauthorized" }
        "404":
          description: No job with that id was tracked.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/CancelResponse"
  /jobs/cancel:
    post:
      tags: [Jobs]
      summary: Cancel jobs by label set
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/CancelJobsRequest"
      responses:
        "200":
          description: Number of jobs cancelled.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/CancelResponse"
        "400": { $ref: "#/components/responses/BadRequest" }
        "401": { $ref: "#/components/responses/Unauthorized" }
  /jobs/cancel-all:
    post:
      tags: [Jobs]
      summary: Cancel every active job
      responses:
        "200":
          description: All active jobs were cancelled.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/CancelResponse"
        "401": { $ref: "#/components/responses/Unauthorized" }
  /vms:
    get:
      tags: [Virtual Machines]
      summary: List local Tart virtual machines and images
      responses:
        "200":
          description: Local VMs / images from `tart list`.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/VirtualMachineListResponse"
        "401": { $ref: "#/components/responses/Unauthorized" }
        "500": { $ref: "#/components/responses/ServerError" }
  /vms/{name}:
    get:
      tags: [Virtual Machines]
      summary: Get a virtual machine (with IP)
      parameters:
        - $ref: "#/components/parameters/VmName"
      responses:
        "200":
          description: The virtual machine, including its IP address if resolvable.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/VirtualMachineDTO"
        "401": { $ref: "#/components/responses/Unauthorized" }
        "404": { $ref: "#/components/responses/NotFound" }
    delete:
      tags: [Virtual Machines]
      summary: Delete a virtual machine
      parameters:
        - $ref: "#/components/parameters/VmName"
      responses:
        "204":
          description: The virtual machine was deleted.
        "401": { $ref: "#/components/responses/Unauthorized" }
        "500": { $ref: "#/components/responses/ServerError" }
  /images/pull:
    post:
      tags: [Virtual Machines]
      summary: Pull an image into the local Tart store
      description: Runs `tart pull`. May take a while for large images; the call blocks until done.
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/ImagePullRequest"
      responses:
        "200":
          description: The image was pulled.
          content:
            application/json:
              schema:
                type: object
                properties:
                  status: { type: string }
                  name: { type: string }
        "400": { $ref: "#/components/responses/BadRequest" }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "500": { $ref: "#/components/responses/ServerError" }
components:
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
  parameters:
    JobId:
      name: id
      in: path
      required: true
      description: GitHub workflow job id.
      schema: { type: integer }
    VmName:
      name: name
      in: path
      required: true
      description: Virtual machine name.
      schema: { type: string }
  responses:
    Unauthorized:
      description: A bearer token is configured and was missing or invalid.
      content:
        application/json:
          schema: { $ref: "#/components/schemas/ErrorResponse" }
    BadRequest:
      description: The request was malformed.
      content:
        application/json:
          schema: { $ref: "#/components/schemas/ErrorResponse" }
    NotFound:
      description: The resource was not found.
      content:
        application/json:
          schema: { $ref: "#/components/schemas/ErrorResponse" }
    ServerError:
      description: The operation failed.
      content:
        application/json:
          schema: { $ref: "#/components/schemas/ErrorResponse" }
  schemas:
    ErrorResponse:
      type: object
      required: [error]
      properties:
        error: { type: string }
    HealthResponse:
      type: object
      required: [status, service, version, startedAt, uptimeSeconds]
      properties:
        status: { type: string }
        service: { type: string }
        version: { type: string }
        startedAt: { type: string, format: date-time }
        uptimeSeconds: { type: number }
    WorkflowAction:
      type: string
      enum: [router_start, waiting, queued, in_progress, completed, unknown]
    ExecutorJobState:
      type: string
      enum: [pending, in_progress, active]
      description: >-
        `pending` = queued; `in_progress` = reported running by GitHub; `active` = a VM still
        exists for the job though it is no longer tracked as pending/in-progress.
    ExecutorStatusResponse:
      type: object
      required:
        [hostname, inProgressJobs, pendingJobs, startedPendingJobs, activeVirtualMachines,
         virtualMachineLimit, cpuLimit, cpuUsed, totalMemory, memoryUsed]
      properties:
        hostname: { type: string }
        inProgressJobs: { type: integer }
        pendingJobs: { type: integer }
        startedPendingJobs: { type: integer }
        activeVirtualMachines: { type: integer }
        virtualMachineLimit: { type: integer }
        cpuLimit: { type: integer }
        cpuUsed: { type: integer }
        totalMemory: { type: integer }
        memoryUsed: { type: integer }
    ExecutorSettingsResponse:
      type: object
      required: [hostname, numberOfMachines, runnerLabels, webhookPort, isHeadless, isInsecure,
                 insecureDomains, cpuLimit, totalMemory, authEnabled]
      properties:
        hostname: { type: string }
        numberOfMachines: { type: integer }
        runnerLabels: { type: string }
        webhookPort: { type: integer }
        routerUrl: { type: [string, "null"] }
        localUrl: { type: [string, "null"] }
        isHeadless: { type: boolean }
        isInsecure: { type: boolean }
        insecureDomains:
          type: array
          items: { type: string }
        netBridgedAdapter: { type: [string, "null"] }
        defaultCpu: { type: [integer, "null"] }
        defaultMemory: { type: [integer, "null"] }
        cpuLimit: { type: integer }
        totalMemory: { type: integer }
        loggingEndpoint: { type: [string, "null"] }
        authEnabled:
          type: boolean
          description: Whether a bearer token is configured for this API.
    ExecutorJobDTO:
      type: object
      required: [id, action, state, labels, didStart]
      properties:
        id: { type: integer }
        action: { $ref: "#/components/schemas/WorkflowAction" }
        state: { $ref: "#/components/schemas/ExecutorJobState" }
        labels:
          type: array
          items: { type: string }
        didStart: { type: boolean }
        cpu: { type: [integer, "null"] }
        memory: { type: [integer, "null"] }
        imageName: { type: [string, "null"] }
        vmName: { type: [string, "null"] }
        vmUUID: { type: [string, "null"] }
        queuedAt: { type: [string, "null"], format: date-time }
        startedAt: { type: [string, "null"], format: date-time }
    ExecutorJobsResponse:
      type: object
      required: [jobs]
      properties:
        jobs:
          type: array
          items: { $ref: "#/components/schemas/ExecutorJobDTO" }
    VirtualMachineDTO:
      type: object
      required: [name, managedByExecutor]
      properties:
        name: { type: string }
        ipAddress: { type: [string, "null"] }
        jobId: { type: [integer, "null"] }
        managedByExecutor: { type: boolean }
    VirtualMachineListResponse:
      type: object
      required: [virtualMachines]
      properties:
        virtualMachines:
          type: array
          items: { $ref: "#/components/schemas/VirtualMachineDTO" }
    ImagePullRequest:
      type: object
      required: [name]
      properties:
        name: { type: string }
        isInsecure: { type: [boolean, "null"] }
    CancelJobsRequest:
      type: object
      required: [labels]
      properties:
        labels:
          type: array
          items: { type: string }
          uniqueItems: true
    CancelResponse:
      type: object
      required: [cancelled]
      properties:
        cancelled: { type: boolean }
        cancelledCount: { type: [integer, "null"] }
"""#
}
