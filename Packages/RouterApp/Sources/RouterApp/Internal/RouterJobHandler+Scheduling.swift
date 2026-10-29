import Foundation
import TartCommon

extension RouterJobHandler {
    // A job stays attributed to a host even if the host lost it because the virtual machine
    // could not be created, or the executor crashed or restarted. Executors report how many
    // machines they are actually running; when a host keeps reporting fewer machines than the
    // number of jobs attributed to it, the difference will never run, so clear the attribution
    // of that many queued jobs to have them sent out again. The deficit must persist for a
    // while before jobs are requeued because a completed job's webhook typically arrives a few
    // seconds after its machine already shut down, which looks like a deficit as well.
    func requeueLostJobs() {
        let now = Date()
        for host in hosts {
            let hostKey = ObjectIdentifier(host)
            guard let lastStatus = host.lastStatus else {
                hostDeficitSince[hostKey] = nil
                continue
            }
            let attributedJobs = jobs.values.filter { $0.sentToHost === host }
            let lostJobs = attributedJobs.count - lastStatus.activeVirtualMachines
            guard lostJobs > 0 else {
                hostDeficitSince[hostKey] = nil
                continue
            }
            guard let deficitSince = hostDeficitSince[hostKey] else {
                hostDeficitSince[hostKey] = now
                continue
            }
            guard now.timeIntervalSince(deficitSince) >= Constants.lostJobRequeueInterval else { continue }
            hostDeficitSince[hostKey] = nil
            // Only queued jobs can be requeued. An in-progress job whose machine died is
            // GitHub's to fail; its completed webhook will remove it.
            let queuedJobs = attributedJobs.filter { $0.workflowJob.action == .queued }
            for job in queuedJobs.prefix(lostJobs) {
                logger.error("Job Router Lost By Host", job: job, host: host)
                job.sentToHost = nil
            }
        }
    }

    func sendQueuedJobs() async {
        // Iterate over a snapshot: every send suspends this actor and webhooks can mutate
        // `jobs` in the meantime, so each job is re-checked right before it is sent.
        for job in jobs.values.sorted(by: { $0.receivedAt < $1.receivedAt }) {
            guard jobs[job.id] === job, completedJobs[job.id] == nil, job.sentToHost == nil, job.workflowJob.action == .queued else { continue }
            await sendQueuedJob(job)
        }
    }

    func sendQueuedJob(_ job: RouterPendingJob) async {
        var foundPerJobEligibleHost = false
        var foundResourceCapacity = false
        var foundVirtualMachineSlot = false
        for host in hosts {
            // The job may have completed or been attributed to a host while a previous send
            // attempt was awaited.
            guard jobs[job.id] === job, completedJobs[job.id] == nil, job.sentToHost == nil, job.workflowJob.action == .queued else { return }
            guard let lastStatus = host.lastStatus else { continue }
            let requirements = job.resourceRequirements(for: lastStatus)
            guard job.hostCanRun(host, requirements: requirements) else { continue }
            foundPerJobEligibleHost = true
            guard lastStatus.resourceCapacity.canFit(requirements) else { continue }
            foundResourceCapacity = true
            guard lastStatus.activeVirtualMachines < lastStatus.virtualMachineLimit else { continue }
            foundVirtualMachineSlot = true
            do {
                try await Self.sendJob(host: host, job: job, logger: logger, session: session)
            } catch {
                logger.error("Executor API Send Job Error", job: job, host: host, error: error)
                continue
            }
            // The virtual machine now exists on the host no matter what happened to the job
            // while the send was in flight.
            var reservedStatus = lastStatus
            reservedStatus.activeVirtualMachines += 1
            reservedStatus.reserve(requirements)
            host.lastStatus = reservedStatus
            if jobs[job.id] === job, job.sentToHost == nil, job.workflowJob.action == .queued {
                job.sentToHost = host
            } else if jobs[job.id] !== job {
                // The job finished while the send was in flight, so the label cancel that runs
                // on completion has already passed and the machine that was just created would
                // idle forever. Cancel it on the host it was sent to.
                logger.error("Job Router Job Finished During Send", job: job, host: host)
                if !reconciledCompletedJobs.contains(job.id) {
                    try? await Self.cancelJobsByLabels(host: host, labels: job.workflowJob.labels, logger: logger, session: session)
                }
            } else {
                // The job was attributed to another host or started while the send was in
                // flight. The machine will pick up other queued work with these labels or be
                // cancelled once the last job with them completes.
                logger.error("Job Router Job Changed During Send", job: job, host: host)
            }
            return
        }
        if !foundPerJobEligibleHost {
            logger.error("Job Router No Host Matches Per-Job Limits", job: job)
        } else if !foundResourceCapacity {
            logger.info("Job Router No Host Has Aggregate Resource Capacity", job: job)
        } else if !foundVirtualMachineSlot {
            logger.info("Job Router No Host Has Virtual Machine Capacity", job: job)
        }
    }
}
