import Foundation
import Darwin

@MainActor
final class PerformanceMonitor: ObservableObject {
    struct Sample {
        let timestamp: Date
        let cpuUsagePercent: Double
        let memoryUsedBytes: UInt64

        var memoryUsedMegabytes: Double {
            Double(memoryUsedBytes) / 1_048_576
        }
    }

    @Published private(set) var latestSample: Sample?
    @Published private(set) var isRunning = false

    private var samplingTask: Task<Void, Never>?
    private let maximumSampleCount = 300
    private(set) var samples: [Sample] = []

    func start(sampleIntervalSeconds: TimeInterval = 2) {
        guard !isRunning else { return }
        isRunning = true

        samplingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                recordSample()
                let sleepNanoseconds = UInt64(sampleIntervalSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: sleepNanoseconds)
            }
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        isRunning = false
    }

    private func recordSample() {
        let sample = Sample(
            timestamp: Date(),
            cpuUsagePercent: Self.currentCPUUsagePercent(),
            memoryUsedBytes: Self.currentMemoryUsageBytes()
        )

        latestSample = sample
        samples.append(sample)
        if samples.count > maximumSampleCount {
            samples.removeFirst(samples.count - maximumSampleCount)
        }

        print(
            String(
                format: "[Performance] CPU: %.1f%% | Memory: %.1f MB",
                sample.cpuUsagePercent,
                sample.memoryUsedMegabytes
            )
        )
    }

    private static func currentMemoryUsageBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integerPointer in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), integerPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    private static func currentCPUUsagePercent() -> Double {
        var threadsList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)

        let result = task_threads(mach_task_self_, &threadsList, &threadCount)
        guard result == KERN_SUCCESS, let threads = threadsList else { return 0 }

        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: threads),
                vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.stride)
            )
        }

        var totalCPUUsage: Double = 0

        for index in 0..<Int(threadCount) {
            var threadInfo = thread_basic_info()
            var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)

            let threadResult = withUnsafeMutablePointer(to: &threadInfo) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(threadInfoCount)) { integerPointer in
                    thread_info(
                        threads[index],
                        thread_flavor_t(THREAD_BASIC_INFO),
                        integerPointer,
                        &threadInfoCount
                    )
                }
            }

            guard threadResult == KERN_SUCCESS else { continue }
            if (threadInfo.flags & TH_FLAGS_IDLE) == 0 {
                totalCPUUsage += (Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE)) * 100.0
            }
        }

        return totalCPUUsage
    }
}
