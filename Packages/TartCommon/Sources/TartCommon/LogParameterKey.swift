public enum LogParameterKey {
    // Job identifiers
    public static let jobId = "jobId"
    public static let workflowJobId = "workflowJobId"
    public static let uuid = "uuid"
    public static let jobAction = "jobAction"

    // Virtual Machine
    public static let vmName = "vmName"
    public static let imageName = "imageName"

    // Host information
    public static let hostname = "hostname"
    public static let url = "url"
    public static let routerUrl = "routerUrl"

    // Labels
    public static let labels = "labels"
    public static let jobLabels = "jobLabels"
    public static let tartLabels = "tartLabels"
    public static let extraLabels = "extraLabels"

    // Errors
    public static let error = "error"
    public static let runError = "runError"
    public static let deleteError = "deleteError"

    // Job execution
    public static let action = "action"
    public static let willStart = "willStart"
    public static let activeJobs = "activeJobs"
    public static let maxMachines = "maxMachines"
    public static let cancelledCount = "cancelledCount"

    // Resource allocation
    public static let cpu = "cpu"
    public static let memory = "memory"
    public static let isInsecure = "isInsecure"

    // Server configuration
    public static let port = "port"
    public static let numberOfMachines = "numberOfMachines"

    // Validation
    public static let expectedCount = "expectedCount"
    public static let actualCount = "actualCount"
}
