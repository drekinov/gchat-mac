import Darwin
import Foundation
import Testing

/// Suites that assert on process memory nest here so they never run alongside each other.
@Suite(.serialized) enum MemorySensitive {}

func physFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "chatnet-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeSparseFile(in directory: URL, megabytes: Int) throws -> URL {
    let url = directory.appending(path: "sparse.bin")
    FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(megabytes) << 20)
    try handle.close()
    return url
}
