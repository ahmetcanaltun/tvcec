// tvcec: send HDMI-CEC wake/standby to a TV when the Mac wakes or sleeps.
//
// CEC transport: VESA DP "CEC tunneling over AUX" registers (DPCD 0x3000-0x302F),
// see Linux drivers/gpu/drm/display/drm_dp_cec.c. They are reached with the
// undocumented IODPDevice* functions in IOKit, resolved at runtime as MacTV does
// (github.com/pengchujin/MacTV, MIT). Writes are limited to the CEC block, so
// display timing, resolution and rotation (Crisp's job) are never touched.
//
// On Macs that macOS does not enable CEC for (tested on MacBookPro18,3), the
// converter's transmitter is cut off the bus until SMC GPIO gP12, named
// function-hdmi_cec_en in the device tree, is driven high. That write is
// undocumented and needs root, so wake/standby run as root via a sudoers rule
// and the pin is high only while a command runs.

import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt

// MARK: - Logging

enum Log {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/tvcec")
    static let file = directory.appendingPathComponent("tvcec.log")
    private static let maxBytes = 1_000_000
    private static let lock = NSLock()
    static var writesFile = true
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) \(message)\n"
        fputs(line, stderr)
        // A root child reports through stderr; the agent owns the log file.
        guard geteuid() != 0, writesFile else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        if let size = attributes?[.size] as? Int, size > maxBytes {
            let old = directory.appendingPathComponent("tvcec.log.1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: file, to: old)
        }
        guard let handle = fopen(file.path, "a") else { return }
        fputs(line, handle)
        fclose(handle)
    }
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
}

// MARK: - DPCD access

struct CECFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

protocol Registers {
    func read(_ address: UInt32, count: Int) throws -> [UInt8]
    func write(_ address: UInt32, _ bytes: [UInt8]) throws
    var physicalAddress: UInt16? { get }
}

enum DPCD {
    static let capability: UInt32 = 0x3000
    static let control: UInt32 = 0x3001
    static let rxInfo: UInt32 = 0x3002
    static let txInfo: UInt32 = 0x3003
    static let irqFlags: UInt32 = 0x3004
    static let addressMask: UInt32 = 0x300e
    static let rxBuffer: UInt32 = 0x3010
    static let txBuffer: UInt32 = 0x3020
}

final class HardwarePort: Registers {
    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> UnsafeMutableRawPointer?
    private typealias ReadDPCD = @convention(c) (UnsafeMutableRawPointer, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
    private typealias WriteDPCD = @convention(c) (UnsafeMutableRawPointer, UInt32, UnsafeRawPointer, UInt32) -> Int32
    private typealias CopyEDID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Unmanaged<CFData>?>) -> Int32

    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private let device: UnsafeMutableRawPointer
    private let readFunction: ReadDPCD
    private let writeFunction: WriteDPCD
    let serviceName: String
    let physicalAddress: UInt16?

    init() throws {
        guard let library = Self.iokit,
              let create = dlsym(library, "IODPDeviceCreateWithService"),
              let read = dlsym(library, "IODPDeviceReadDPCD"),
              let write = dlsym(library, "IODPDeviceWriteDPCD") else {
            throw CECFailure("this macOS no longer exports the IODPDevice functions")
        }
        let createDevice = unsafeBitCast(create, to: Create.self)
        readFunction = unsafeBitCast(read, to: ReadDPCD.self)
        writeFunction = unsafeBitCast(write, to: WriteDPCD.self)

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPDPDeviceProxy"), &iterator) == KERN_SUCCESS else {
            throw CECFailure("cannot enumerate display ports")
        }
        defer { IOObjectRelease(iterator) }
        var found: [(UnsafeMutableRawPointer, String)] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let candidate = createDevice(kCFAllocatorDefault, service) else { continue }
            var capability: UInt8 = 0
            if readFunction(candidate, DPCD.capability, &capability, 1) == 0, capability & 1 != 0 {
                found.append((candidate, Self.parentName(of: service)))
            } else {
                Unmanaged<AnyObject>.fromOpaque(candidate).release()
            }
        }
        guard found.count == 1 else {
            found.forEach { Unmanaged<AnyObject>.fromOpaque($0.0).release() }
            throw CECFailure(found.isEmpty ? "no CEC-capable port (is the HDMI cable connected?)"
                                           : "\(found.count) CEC-capable ports: \(found.map(\.1)); refusing to guess")
        }
        device = found[0].0
        serviceName = found[0].1
        physicalAddress = Self.readPhysicalAddress(displayPrefix: serviceName.prefix { $0 != ":" })
    }

    deinit { Unmanaged<AnyObject>.fromOpaque(device).release() }

    func read(_ address: UInt32, count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let result = bytes.withUnsafeMutableBytes { readFunction(device, address, $0.baseAddress!, UInt32(count)) }
        guard result == 0 else { throw CECFailure(String(format: "DPCD read 0x%04x failed: 0x%08x", address, result)) }
        return bytes
    }

    func write(_ address: UInt32, _ bytes: [UInt8]) throws {
        guard (DPCD.control...DPCD.txBuffer + 0x0f).contains(address) else {
            throw CECFailure(String(format: "refusing DPCD write outside the CEC block: 0x%04x", address))
        }
        let result = bytes.withUnsafeBytes { writeFunction(device, address, $0.baseAddress!, UInt32(bytes.count)) }
        guard result == 0 else { throw CECFailure(String(format: "DPCD write 0x%04x failed: 0x%08x", address, result)) }
    }

    private static func parentName(of service: io_service_t) -> String {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return "?" }
        defer { IOObjectRelease(parent) }
        var name = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(parent, &name)
        return String(cString: name)
    }

    private static func readPhysicalAddress(displayPrefix: Substring) -> UInt16? {
        guard let library = iokit,
              let create = dlsym(library, "IOAVServiceCreateWithService"),
              let copy = dlsym(library, "IOAVServiceCopyEDID") else { return nil }
        let createService = unsafeBitCast(create, to: Create.self)
        let copyEDID = unsafeBitCast(copy, to: CopyEDID.self)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard parentName(of: service).prefix(while: { $0 != ":" }) == displayPrefix,
                  let av = createService(kCFAllocatorDefault, service) else { continue }
            defer { Unmanaged<AnyObject>.fromOpaque(av).release() }
            var data: Unmanaged<CFData>?
            guard copyEDID(av, &data) == 0, let data else { continue }
            return parsePhysicalAddress(fromEDID: Array(data.takeRetainedValue() as Data))
        }
        return nil
    }
}

/// CEC physical address from the HDMI vendor block in the first CTA extension.
func parsePhysicalAddress(fromEDID edid: [UInt8]) -> UInt16? {
    guard edid.count >= 256, edid[128] == 2 else { return nil }
    let block = Array(edid[128..<256])
    let end = Int(block[2])
    guard end >= 4, end <= 127 else { return nil }
    var offset = 4
    while offset < end {
        let length = Int(block[offset] & 0x1f), tag = block[offset] >> 5
        guard offset + 1 + length <= end else { return nil }
        if tag == 3, length >= 5, block[offset + 1] == 0x03, block[offset + 2] == 0x0c, block[offset + 3] == 0x00 {
            let address = UInt16(block[offset + 4]) << 8 | UInt16(block[offset + 5])
            return address == 0 || address == 0xffff ? nil : address
        }
        offset += length + 1
    }
    return nil
}

// MARK: - CEC protocol

enum SendResult: Equatable {
    case acknowledged
    case unconfirmed // macOS took the interrupt flag first, so the ACK is unknowable.
    case notAcknowledged
    case lineError

    var delivered: Bool { self == .acknowledged || self == .unconfirmed }
}

let tvAddress: UInt8 = 0
let broadcastAddress: UInt8 = 15
let powerStatusNames: [UInt8: String] = [0: "on", 1: "standby", 2: "turning on", 3: "turning off"]

final class CECSession {
    private let io: Registers
    private let pause: (TimeInterval) -> Void
    private var restore: (control: UInt8, mask: [UInt8])?
    private(set) var source: UInt8 = 4

    /// macOS owns the tunnel on Macs Apple lists as CEC capable: reuse its address.
    /// Otherwise enable the tunnel for this session, as Linux does, and undo it in `close`.
    init(io: Registers, pause: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)) throws {
        self.io = io
        self.pause = pause
        let control = try io.read(DPCD.control, count: 1)[0]
        let mask = try io.read(DPCD.addressMask, count: 2)
        let owned = UInt16(mask[0]) | UInt16(mask[1]) << 8
        if control & 1 != 0, let existing = [UInt8(4), 8, 11].first(where: { owned & (1 << UInt16($0)) != 0 }) {
            source = existing
        } else {
            restore = (control, mask)
            try io.write(DPCD.control, [0x01])
            try io.write(DPCD.addressMask, [0x10, 0x80]) // playback 1 + unregistered
        }
    }

    func close() {
        guard let restore else { return }
        try? io.write(DPCD.addressMask, restore.mask)
        try? io.write(DPCD.control, [restore.control])
        self.restore = nil
    }

    func send(_ payload: [UInt8], to destination: UInt8 = tvAddress, retries: UInt8 = 2) throws -> SendResult {
        var ready = false
        for _ in 0..<100 {
            if try io.read(DPCD.txInfo, count: 1)[0] & 0x80 == 0 { ready = true; break }
            pause(0.01)
        }
        guard ready else { throw CECFailure("CEC transmitter stayed busy") }
        let frame = [source << 4 | destination] + payload
        try io.write(DPCD.irqFlags, [0xf0])
        try io.write(DPCD.txBuffer, frame)
        try io.write(DPCD.txInfo, [UInt8(frame.count - 1) | retries << 4 | 0x80])
        var idleReads = 0
        for _ in 0..<1500 {
            let flags = try io.read(DPCD.irqFlags, count: 1)[0]
            if flags & 0xf0 != 0 {
                try io.write(DPCD.irqFlags, [flags & 0xf0])
                let result: SendResult = flags & 0x10 != 0 ? .acknowledged : flags & 0x20 != 0 ? .lineError : .notAcknowledged
                Log.write("cec tx \(hex(frame)) -> \(result)")
                return result
            }
            if try io.read(DPCD.txInfo, count: 1)[0] & 0x80 == 0 {
                idleReads += 1
                if idleReads > 20 {
                    Log.write("cec tx \(hex(frame)) -> unconfirmed")
                    return .unconfirmed
                }
            }
            pause(0.001)
        }
        throw CECFailure("CEC transmit timed out")
    }

    /// Returns the first frame from `peer` carrying `reply`, or nil if none arrives in time.
    func query(_ payload: [UInt8], reply: UInt8, from peer: UInt8 = tvAddress, timeout: TimeInterval = 1.0) throws -> [UInt8]? {
        try io.write(DPCD.irqFlags, [0x03])
        guard try send(payload, to: peer).delivered else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let flags = try io.read(DPCD.irqFlags, count: 1)[0]
            if flags & 0x01 != 0 {
                let frame = try io.read(DPCD.rxBuffer, count: 16)
                try io.write(DPCD.irqFlags, [0x01])
                if frame[0] >> 4 == peer, frame[1] == reply { return frame }
            }
            pause(0.002)
        }
        return nil
    }

    /// False only if the TV keeps reporting standby. No reply is not a failure:
    /// a booting TV can stay silent, and macOS can take the receive flag first.
    func confirmOn(attempts: Int = 3) throws -> Bool {
        var status: UInt8?
        for _ in 0..<attempts {
            pause(1.5)
            status = try query([0x8f], reply: 0x90).map { $0[2] }
            if status == 0 || status == 2 { break }
        }
        Log.write("tv power status: \(status.flatMap { powerStatusNames[$0] } ?? "no reply")")
        return status != 1 && status != 3
    }
}

enum Power: String { case on, off }

/// Drives the CEC enable pin for the lifetime of a command. Only this key is ever written.
final class CECEnablePin {
    private var connection: io_connect_t = 0

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw CECFailure("AppleSMC not found") }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
            throw CECFailure("cannot open AppleSMC")
        }
        try write(0x0100_0001) // CMD_OUTPUT | high, see Linux gpio-macsmc.c
        Thread.sleep(forTimeInterval: 0.5)
    }

    func close() {
        try? write(0x0100_0000)
        IOServiceClose(connection)
    }

    private func write(_ value: UInt32) throws {
        // SMCParamStruct: key@0, keyInfo.dataSize@28, data8@42, bytes@48.
        var input = [UInt8](repeating: 0, count: 80)
        var output = [UInt8](repeating: 0, count: 80)
        input.withUnsafeMutableBytes {
            $0.storeBytes(of: UInt32(0x6750_3132), toByteOffset: 0, as: UInt32.self) // 'gP12'
            $0.storeBytes(of: UInt32(4), toByteOffset: 28, as: UInt32.self)
            $0.storeBytes(of: value, toByteOffset: 48, as: UInt32.self)
        }
        input[42] = 6 // SMC write
        var size = 80
        let result = IOConnectCallStructMethod(connection, 2, &input, 80, &output, &size)
        guard result == KERN_SUCCESS, output[40] == 0 else {
            throw CECFailure(String(format: "gP12 write failed: 0x%08x/0x%02x (run as root)", result, output[40]))
        }
    }
}

/// Opens the port, runs one power command and always restores the pin and tunnel state.
func deliver(_ power: Power) throws -> Bool {
    let lock = try PortLock()
    defer { lock.release() }
    let port = try HardwarePort()
    let pin = try CECEnablePin()
    defer { pin.close() }
    let session = try CECSession(io: port)
    defer { session.close() }
    switch power {
    case .off:
        return try session.send([0x36]).delivered // Standby
    case .on:
        let viewOn = try session.send([0x04]) // Image View On
        guard viewOn.delivered else { return false }
        _ = try session.send([0x44, 0x6d]) // User Control Pressed: Power On Function
        _ = try session.send([0x45]) // User Control Released
        if let address = port.physicalAddress {
            // Active Source, so the TV selects this input after turning on.
            _ = try session.send([0x82, UInt8(address >> 8), UInt8(address & 0xff)], to: broadcastAddress)
        }
        return try session.confirmOn()
    }
}

/// Serializes the daemon and manual commands; the CEC registers are a single shared mailbox.
final class PortLock {
    private let descriptor: Int32

    init() throws {
        let path = "/var/run/tvcec.lock"
        descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CECFailure("cannot open \(path)") }
        for _ in 0..<30 {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        close(descriptor)
        throw CECFailure("another tvcec command is using the port")
    }

    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

// MARK: - Power state machine

/// Sends each transition once. `delivered` becomes nil after a failure, so the
/// next event or HDMI reconnect retries instead of being deduplicated away.
final class PowerController {
    private let queue = DispatchQueue(label: "tvcec.power")
    private let wakeDelays: [TimeInterval]
    private let displaySleepDelay: TimeInterval
    private let send: (Power) throws -> Bool
    private var desired = Power.on
    private var delivered: Power?
    private var generation = 0

    init(wakeDelays: [TimeInterval] = [1.5, 3, 5, 10], displaySleepDelay: TimeInterval = 30, send: @escaping (Power) throws -> Bool) {
        self.wakeDelays = wakeDelays
        self.displaySleepDelay = displaySleepDelay
        self.send = send
    }

    func systemWillSleep(completion: @escaping () -> Void) {
        queue.async { [self] in
            generation += 1
            desired = .off
            if delivered == .off {
                Log.write("sleep: standby already delivered, skipping")
            } else {
                _ = attempt(.off)
            }
            completion()
        }
    }

    /// Delayed, so a screen that wakes again right away does not cycle the TV.
    func displayDidSleep() {
        queue.async { [self] in
            Log.write("event: screens slept")
            generation += 1
            desired = .off
            let token = generation
            queue.asyncAfter(deadline: .now() + displaySleepDelay) { [self] in
                guard token == generation, delivered != .off else { return }
                _ = attempt(.off)
            }
        }
    }

    func systemDidWake(reason: String) {
        queue.async { [self] in
            Log.write("event: \(reason)")
            generation += 1
            desired = .on
            guard delivered != .on else { return }
            scheduleWake(attempt: 0, token: generation)
        }
    }

    func displayReconnected() {
        queue.async { [self] in
            Log.write("event: display added")
            guard desired == .on, delivered != .on else { return }
            generation += 1
            scheduleWake(attempt: 0, token: generation)
        }
    }

    /// For tests: blocks until queued work has run.
    func drain() { queue.sync {} }

    private func scheduleWake(attempt index: Int, token: Int) {
        guard index < wakeDelays.count else {
            Log.write("wake: giving up after \(wakeDelays.count) attempts; will retry on the next display event")
            return
        }
        queue.asyncAfter(deadline: .now() + wakeDelays[index]) { [self] in
            guard token == generation, desired == .on, delivered != .on else { return }
            if !attempt(.on) { scheduleWake(attempt: index + 1, token: token) }
        }
    }

    private func attempt(_ power: Power) -> Bool {
        do {
            if try send(power) {
                delivered = power
                Log.write("power \(power.rawValue): delivered")
                return true
            }
            Log.write("power \(power.rawValue): TV did not acknowledge")
        } catch {
            Log.write("power \(power.rawValue): \(error)")
        }
        delivered = nil
        return false
    }
}

// MARK: - Daemon

final class SleepWatcher {
    // iokit_common_msg() macros from IOMessage.h, which Swift cannot import.
    private static let canSystemSleep: UInt32 = 0xe000_0270
    private static let systemWillSleep: UInt32 = 0xe000_0280

    private let controller: PowerController
    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var notificationPort: IONotificationPortRef?
    private var observers: [NSObjectProtocol] = []
    private var reconnectPending = false

    /// How long sleep may wait for the CEC command before being allowed regardless.
    private static let sleepBudget: TimeInterval = 5

    init(controller: PowerController) { self.controller = controller }

    func start() throws {
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &notificationPort, { context, _, message, argument in
            Unmanaged<SleepWatcher>.fromOpaque(context!).takeUnretainedValue().handle(message, argument)
        }, &notifier)
        guard rootPort != 0, let notificationPort else { throw CECFailure("IORegisterForSystemPower failed") }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue(), .defaultMode)

        // Unlike kIOMessageSystemHasPoweredOn, these skip Power Nap dark wakes.
        // The screen notifications arrive only in a process with an NSApplication.
        let center = NSWorkspace.shared.notificationCenter
        for (name, reason) in [(NSWorkspace.didWakeNotification, "system woke"), (NSWorkspace.screensDidWakeNotification, "screens woke")] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [controller] _ in
                controller.systemDidWake(reason: reason)
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [controller] _ in
            controller.displayDidSleep()
        })
        observers.append(center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [controller] _ in
            Log.write("event: logout or shutdown")
            let done = DispatchSemaphore(value: 0)
            controller.systemWillSleep { done.signal() }
            _ = done.wait(timeout: .now() + Self.sleepBudget)
        })

        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            guard flags.contains(.addFlag), !flags.contains(.beginConfigurationFlag) else { return }
            Unmanaged<SleepWatcher>.fromOpaque(context!).takeUnretainedValue().displayAdded()
        }, context)
    }

    private func handle(_ message: UInt32, _ argument: UnsafeMutableRawPointer?) {
        let token = Int(bitPattern: argument)
        switch message {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, token) // Never veto idle sleep.
        case Self.systemWillSleep:
            Log.write("event: system will sleep")
            var allowed = false
            let allow = { [rootPort] in
                guard !allowed else { return }
                allowed = true
                IOAllowPowerChange(rootPort, token)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.sleepBudget) {
                if !allowed { Log.write("sleep: CEC budget exceeded, allowing sleep") }
                allow()
            }
            controller.systemWillSleep { DispatchQueue.main.async(execute: allow) }
        default:
            break
        }
    }

    private func displayAdded() {
        guard !reconnectPending else { return }
        reconnectPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            reconnectPending = false
            controller.displayReconnected()
        }
    }
}

// MARK: - Commands

func runStatus() -> Int32 {
    do {
        let lock = try PortLock()
        defer { lock.release() }
        let port = try HardwarePort()
        let pin = try CECEnablePin()
        defer { pin.close() }
        let capability = try port.read(DPCD.capability, count: 1)[0]
        let control = try port.read(DPCD.control, count: 1)[0]
        let mask = try port.read(DPCD.addressMask, count: 2)
        print("port:        \(port.serviceName)")
        print("capability:  \(hex([capability]))  tunnel control: \(hex([control]))  address mask: \(hex(mask))")
        print("macOS owns tunnel: \(control & 1 != 0 && mask != [0, 0] ? "yes" : "no (Mac not on Apple's CEC list, or no adapter)")")
        if let address = port.physicalAddress {
            print(String(format: "physical address: %x.%x.%x.%x", address >> 12, (address >> 8) & 15, (address >> 4) & 15, address & 15))
        } else {
            print("physical address: unknown")
        }
        let session = try CECSession(io: port)
        defer { session.close() }
        let result = try session.send([0x8f])
        guard result.delivered else {
            print("TV: no ACK at logical address 0. tvcec cannot control the TV over this path.")
            return 2
        }
        let reply = try session.query([0x8f], reply: 0x90)
        print("TV: acknowledged, power \(reply.flatMap { powerStatusNames[$0[2]] } ?? "not reported")")
        return 0
    } catch {
        print("error: \(error)")
        return 1
    }
}

func runMonitor(seconds: TimeInterval) -> Int32 {
    do {
        let port = try HardwarePort()
        let control = try port.read(DPCD.control, count: 1)
        let mask = try port.read(DPCD.addressMask, count: 2)
        try port.write(DPCD.control, [control[0] | 0x03])
        if mask == [0, 0] { try port.write(DPCD.addressMask, [0x10, 0x80]) }
        defer {
            try? port.write(DPCD.addressMask, mask)
            try? port.write(DPCD.control, control)
        }
        print("listening on \(port.serviceName) for \(Int(seconds)) s")
        let deadline = Date().addingTimeInterval(seconds)
        var last = try port.read(DPCD.rxBuffer, count: 16)
        while Date() < deadline {
            let flags = try port.read(DPCD.irqFlags, count: 1)[0]
            if flags & 0x03 != 0 { try port.write(DPCD.irqFlags, [flags & 0x03]) }
            let frame = try port.read(DPCD.rxBuffer, count: 16)
            if frame != last {
                let length = Int(try port.read(DPCD.rxInfo, count: 1)[0] & 0x0f) + 1
                print(hex(Array(frame.prefix(min(length, 16)))))
                last = frame
            }
            usleep(2000)
        }
        return 0
    } catch {
        print("error: \(error)")
        return 1
    }
}

func runPower(_ power: Power) -> Int32 {
    do {
        if try deliver(power) {
            print("\(power == .on ? "wake" : "standby"): delivered")
            return 0
        }
        print("\(power == .on ? "wake" : "standby"): TV did not acknowledge")
        return 2
    } catch {
        print("error: \(error)")
        return 1
    }
}

/// Runs a power command as root through the sudoers rule, logging its output.
func deliverViaSudo(_ power: Power) throws -> Bool {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    process.arguments = ["-n", CommandLine.arguments[0], power == .on ? "wake" : "standby"]
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let watchdog = DispatchWorkItem { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: watchdog)
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    watchdog.cancel()
    output.split(separator: "\n").forEach { Log.write("  \($0)") }
    switch process.terminationStatus {
    case 0: return true
    case 2: return false
    default: throw CECFailure("root helper exited with \(process.terminationStatus)")
    }
}

func runDaemon() -> Never {
    Log.write("daemon started (pid \(getpid()))")
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let controller = PowerController { try deliverViaSudo($0) }
    let watcher = SleepWatcher(controller: controller)
    do {
        try watcher.start()
    } catch {
        Log.write("fatal: \(error)")
        exit(1)
    }
    // Logout and shutdown leave the TV in standby, so turn it back on at login.
    if CGDisplayIsAsleep(CGMainDisplayID()) == 0 { controller.systemDidWake(reason: "daemon started") }
    withExtendedLifetime(watcher) { app.run() }
    exit(0)
}

// MARK: - Self test

final class FakePort: Registers {
    var memory = [UInt32: UInt8]()
    var sent: [[UInt8]] = []
    var txOutcome: UInt8? = 0x10
    var physicalAddress: UInt16? = 0x1000
    var powerReply: UInt8?

    func read(_ address: UInt32, count: Int) throws -> [UInt8] {
        (0..<count).map { memory[address + UInt32($0), default: 0] }
    }

    func write(_ address: UInt32, _ bytes: [UInt8]) throws {
        if address == DPCD.irqFlags {
            memory[address, default: 0] &= ~bytes[0]
            return
        }
        for (index, byte) in bytes.enumerated() { memory[address + UInt32(index)] = byte }
        if address == DPCD.txInfo, bytes[0] & 0x80 != 0 {
            sent.append(try read(DPCD.txBuffer, count: Int(bytes[0] & 0x0f) + 1))
            memory[DPCD.txInfo] = bytes[0] & 0x7f
            if let txOutcome { memory[DPCD.irqFlags, default: 0] |= txOutcome }
            if let powerReply, sent.last?[1] == 0x8f {
                memory[DPCD.rxBuffer] = 0x04
                memory[DPCD.rxBuffer + 1] = 0x90
                memory[DPCD.rxBuffer + 2] = powerReply
                memory[DPCD.irqFlags, default: 0] |= 0x01
            }
        }
    }
}

func runSelfTest() -> Int32 {
    Log.writesFile = false
    var failures = 0
    func check(_ name: String, _ condition: Bool) {
        print("\(condition ? "ok  " : "FAIL") \(name)")
        if !condition { failures += 1 }
    }
    func session(_ port: FakePort) throws -> CECSession { try CECSession(io: port, pause: { _ in }) }

    do {
        let port = FakePort()
        let cec = try session(port)
        check("enables tunnel when macOS does not", port.memory[DPCD.control] == 1 && port.memory[DPCD.addressMask] == 0x10)
        check("ACK flag means acknowledged", try cec.send([0x36]) == .acknowledged)
        check("standby frame is directed at the TV", port.sent.last == [0x40, 0x36])
        port.txOutcome = 0x40
        check("address NACK is not delivered", try !cec.send([0x36]).delivered)
        port.txOutcome = 0x20
        check("line error is reported", try cec.send([0x36]) == .lineError)
        port.txOutcome = 0x10
        check("no power reply still counts as on", try cec.confirmOn(attempts: 1))
        port.powerReply = 0
        check("TV reporting on confirms wake", try cec.confirmOn())
        port.powerReply = 1
        check("TV staying in standby fails wake", try !cec.confirmOn())
        port.powerReply = nil
        port.txOutcome = nil
        check("consumed flag is unconfirmed", try cec.send([0x36]) == .unconfirmed)
        cec.close()
        check("close restores tunnel state", port.memory[DPCD.control] == 0 && port.memory[DPCD.addressMask] == 0)

        let owned = FakePort()
        owned.memory[DPCD.control] = 1
        owned.memory[DPCD.addressMask] = 0x00
        owned.memory[DPCD.addressMask + 1] = 0x01 // address 8
        let ownedSession = try session(owned)
        _ = try ownedSession.send([0x36])
        ownedSession.close()
        check("reuses the macOS address", owned.sent == [[0x80, 0x36]])
        check("leaves macOS tunnel state alone", owned.memory[DPCD.control] == 1 && owned.memory[DPCD.addressMask + 1] == 0x01)
    } catch {
        check("session threw \(error)", false)
    }

    var edid = [UInt8](repeating: 0, count: 256)
    edid[128] = 2; edid[130] = 12
    edid.replaceSubrange(132..<138, with: [0x65, 0x03, 0x0c, 0x00, 0x10, 0x00])
    check("reads 1.0.0.0 from EDID", parsePhysicalAddress(fromEDID: edid) == 0x1000)

    var log: [Power] = []
    var succeed = true
    let controller = PowerController(wakeDelays: [0, 0, 0]) { log.append($0); return succeed }
    func settle() { for _ in 0..<3 { controller.drain(); usleep(30000) } }
    func sleep() {
        let done = DispatchSemaphore(value: 0)
        controller.systemWillSleep { done.signal() }
        done.wait()
    }
    sleep(); sleep()
    check("repeated sleep sends standby once", log == [.off])
    controller.systemDidWake(reason: "test"); settle()
    controller.systemDidWake(reason: "test"); settle()
    check("repeated wake sends wake once", log == [.off, .on])
    log = []; succeed = false
    controller.displayReconnected(); settle()
    check("reconnect while on sends nothing", log.isEmpty)
    sleep()
    check("sleep with absent TV does not block", log == [.off])
    log = []
    controller.systemDidWake(reason: "test"); settle()
    check("failed wake retries, then stops", log == [.on, .on, .on])
    log = []; succeed = true
    controller.displayReconnected(); settle()
    check("reconnect retries undelivered wake", log == [.on])

    var idle: [Power] = []
    let delayed = PowerController(wakeDelays: [0], displaySleepDelay: 0.05) { idle.append($0); return true }
    func wait() { usleep(120_000); delayed.drain() }
    delayed.systemDidWake(reason: "test"); wait()
    idle = []
    delayed.displayDidSleep()
    delayed.systemDidWake(reason: "test"); wait()
    check("screen waking inside the delay cancels standby", idle.isEmpty)
    delayed.displayDidSleep(); wait()
    check("screen sleep sends standby after the delay", idle == [.off])
    delayed.systemDidWake(reason: "test"); wait()
    check("screen wake turns the TV back on", idle == [.off, .on])
    idle = []
    delayed.displayDidSleep()
    let slept = DispatchSemaphore(value: 0)
    delayed.systemWillSleep { slept.signal() }
    slept.wait(); wait()
    check("system sleep inside the delay sends standby once", idle == [.off])
    return failures == 0 ? 0 : 1
}

// MARK: - Entry point

@main
enum Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "wake": exit(runPower(.on))
        case "standby": exit(runPower(.off))
        case "status": exit(runStatus())
        case "monitor": exit(runMonitor(seconds: arguments.dropFirst().first.flatMap(TimeInterval.init) ?? 30))
        case "daemon": runDaemon()
        case "selftest": exit(runSelfTest())
        default:
            print("usage: tvcec wake | standby | status | monitor [seconds] | daemon | selftest")
            exit(64)
        }
    }
}
