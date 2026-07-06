import Foundation

enum ExecutorConstants {
    /// Prefix for the names of the temporary virtual machines this executor creates. Used on
    /// startup to find and remove machines left behind by a previous run that crashed.
    static let virtualMachineNamePrefix = "tart-executor-"
    /// How long to wait after the last job with a set of labels completes before cancelling
    /// idle virtual machines with those labels. Gives the machine that ran the job time to
    /// shut itself down and gives new jobs a chance to arrive and keep their machines.
    static let idleMachineCancellationDelay: TimeInterval = 30
}
