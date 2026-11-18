import Darwin
import Foundation

enum Footprint {
    static func physicalBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    static func megabytes() -> Double? {
        physicalBytes().map { Double($0) / 1_048_576 }
    }
}

struct ProcessMetrics {
    var footprintMB: Double
    var peakMB: Double
    var rssMB: Double
    var cpuSeconds: Double
    var wakeups: UInt64
    var threads: Int

    static func sample() -> ProcessMetrics {
        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        var power = task_power_info_data_t()
        var powerCount = mach_msg_type_number_t(
            MemoryLayout<task_power_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &power) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(powerCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &powerCount)
            }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        var list: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        if task_threads(mach_task_self_, &list, &threadCount) == KERN_SUCCESS, let list {
            vm_deallocate(
                mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                vm_size_t(Int(threadCount) * MemoryLayout<thread_act_t>.size))
        }
        let megabyte = 1_048_576.0
        return ProcessMetrics(
            footprintMB: Double(vm.phys_footprint) / megabyte,
            peakMB: Double(max(UInt64(bitPattern: vm.ledger_phys_footprint_peak), UInt64(vm.phys_footprint)))
                / megabyte,
            rssMB: Double(vm.resident_size) / megabyte,
            cpuSeconds: seconds(usage.ru_utime) + seconds(usage.ru_stime),
            wakeups: power.task_interrupt_wakeups + power.task_platform_idle_wakeups,
            threads: Int(threadCount))
    }
}
