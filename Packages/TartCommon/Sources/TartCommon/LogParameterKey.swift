public enum LogParameterKey {
    // Job identifiers
    public static let jobId = "job_id"
    public static let workflowJobId = "workflow_job_id"
    public static let uuid = "uuid"
    public static let jobAction = "job_action"

    // Virtual Machine
    public static let vmName = "vm_name"
    public static let imageName = "image_name"

    // Host information
    public static let hostname = "hostname"
    public static let url = "url"
    public static let routerUrl = "router_url"

    // Labels
    public static let labels = "labels"
    public static let jobLabels = "job_labels"
    public static let tartLabels = "tart_labels"
    public static let extraLabels = "extra_labels"

    // Errors
    public static let error = "error"
    public static let runError = "run_error"
    public static let deleteError = "delete_error"

    // Job execution
    public static let action = "action"
    public static let willStart = "will_start"
    public static let activeJobs = "active_jobs"
    public static let maxMachines = "max_machines"
    public static let cancelledCount = "cancelled_count"
    public static let state = "state"
    public static let forced = "forced"

    // GitHub scanning
    public static let repository = "repository"
    public static let repositoryCount = "repository_count"
    public static let jobCount = "job_count"
    public static let durationMs = "duration_ms"
    public static let truncated = "truncated"
    public static let rateLimitRemaining = "rate_limit_remaining"
    public static let statusCode = "status_code"

    // Resource allocation
    public static let cpu = "cpu"
    public static let memory = "memory"
    public static let cpuLimit = "cpu_limit"
    public static let cpuUsed = "cpu_used"
    public static let memoryLimit = "memory_limit"
    public static let memoryUsed = "memory_used"
    public static let activeVirtualMachines = "active_virtual_machines"
    public static let virtualMachineLimit = "virtual_machine_limit"
    public static let isInsecure = "is_insecure"

    // Server configuration
    public static let port = "port"
    public static let numberOfMachines = "number_of_machines"

    // Validation
    public static let expectedCount = "expected_count"
    public static let actualCount = "actual_count"
}
