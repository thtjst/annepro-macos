@preconcurrency import CoreBluetooth
import Foundation
import AnneProKit

public enum AnneProUUID {
    /// The Anne Pro reuses TI's over-the-air-download service for its settings channel.
    public static let service = CBUUID(string: "F000FFC0-0451-4000-B000-000000000000")
    /// Keyboard → host notifications.
    public static let notify = CBUUID(string: "F000FFC1-0451-4000-B000-000000000000")
    /// Host → keyboard writes.
    public static let write = CBUUID(string: "F000FFC2-0451-4000-B000-000000000000")
    public static let batteryService = CBUUID(string: "180F")
    public static let batteryLevel = CBUUID(string: "2A19")
    static let hidService = CBUUID(string: "1812")
}

public enum ConnectionState: Equatable, Sendable {
    case starting
    case poweredOff
    case unauthorized
    case unsupported
    case searching
    case connecting(name: String)
    case connected(name: String)

    public var isConnected: Bool {
        if case .connected = self { true } else { false }
    }

    public var summary: String {
        switch self {
        case .starting: "Starting…"
        case .poweredOff: "Bluetooth is off"
        case .unauthorized: "Bluetooth access not allowed"
        case .unsupported: "Bluetooth LE not available"
        case .searching: "Looking for your Anne Pro…"
        case let .connecting(name): "Connecting to \(name)…"
        case let .connected(name): "Connected to \(name)"
        }
    }
}

public enum AnneProError: LocalizedError, Equatable {
    case notConnected
    case timedOut(String)
    case writeFailed(String)
    case verificationFailed(String)
    case unexpectedReply(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "The keyboard isn't connected."
        case let .timedOut(what): "The keyboard didn't answer (\(what))."
        case let .writeFailed(reason): "Couldn't send to the keyboard: \(reason)"
        case let .verificationFailed(what): "The keyboard didn't keep the new \(what) after several tries."
        case let .unexpectedReply(what): "The keyboard sent an unexpected reply: \(what)"
        }
    }
}

/// How an upload ended.
public enum UploadResult: Sendable {
    /// Read back from the keyboard and matched.
    case verified
    /// Sent, but the keyboard didn't answer the read-back, so it couldn't be checked.
    case unverified
}

/// A connection to an original Anne Pro over Bluetooth LE.
///
/// Create one, call `start()`, and it finds and connects to the keyboard, reconnecting
/// when it sleeps and wakes. All operations are serialized, so a brightness change can't
/// interleave with a lighting upload.
@MainActor
public final class AnneProDevice: NSObject, ObservableObject {
    @Published public private(set) var state: ConnectionState = .starting
    @Published public private(set) var info: DeviceInfo?
    @Published public private(set) var batteryLevel: Int?
    /// Why the last keyboard found couldn't be used, e.g. an Anne Pro 2.
    @Published public private(set) var problem: String?

    /// Receives diagnostic messages. With `verbose`, every packet is logged too.
    public var logHandler: (@MainActor (String) -> Void)?
    public var verbose = false

    /// Messages the keyboard sends that no request was waiting for.
    public var unsolicitedHandler: (@MainActor (Message) -> Void)?

    /// Pause between packets of a multi-packet upload. The keyboard's Bluetooth chip
    /// relays everything over a serial link to the key controller, so it gets a moment.
    public var interPacketDelay: Duration = .milliseconds(20)

    /// Send without waiting for the Bluetooth chip to confirm each packet, like the official
    /// app. Confirmed writes are slow once the keyboard drops to a power-saving connection
    /// interval (~350 ms per packet), and slow uploads get truncated by the keyboard.
    public var preferWriteWithoutResponse = true

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withResponse

    private var assembler = MessageAssembler()
    private let mutex = AsyncMutex()
    private var inbox: [Message] = []

    private var pendingWrite: CheckedContinuation<Void, Error>?
    private var pendingWriteToken = 0
    private var pendingReady: CheckedContinuation<Void, Never>?
    private var replyWaiter: (key: ReplyKey, continuation: CheckedContinuation<Message, Error>, token: Int)?
    private var replyToken = 0
    /// The reply the request in flight expects; it may arrive before the write is confirmed.
    private var expectedReply: ReplyKey?

    /// When the last upload finished. The keyboard drops most of an upload that arrives
    /// while it is still saving the previous one, so uploads are spaced out.
    private var lastUploadFinished: ContinuousClock.Instant?
    private let uploadSpacing: Duration = .seconds(2.5)

    private var searchTask: Task<Void, Never>?
    /// Keyboards that turned out not to have the settings service (e.g. an Anne Pro 2).
    private var ignoredPeripherals: Set<UUID> = []
    private var searchStarted = Date.distantPast
    /// Active scanning stops after this long; after that we only watch system connections.
    private let scanDuration: TimeInterval = 30

    /// Confirmations the keyboard sends for setters and uploads; never worth reporting.
    private static let acknowledgements: Set<ReplyKey> = [
        ReplyKey(type: MessageType.led, op: Operation.reply(to: Operation.LED.themeMode)),
        ReplyKey(type: MessageType.led, op: Operation.reply(to: Operation.LED.themeSwitch)),
        ReplyKey(type: MessageType.led, op: Operation.reply(to: Operation.LED.userStaticTheme)),
        ReplyKey(type: MessageType.keyboard, op: Operation.reply(to: Operation.Keyboard.downloadUserLayout)),
        ReplyKey(type: MessageType.keyboard, op: Operation.reply(to: Operation.Keyboard.setLayoutID)),
    ]

    public override init() {
        super.init()
    }

    public var deviceName: String? {
        switch state {
        case let .connecting(name), let .connected(name): name
        default: nil
        }
    }

    #if DEBUG
    /// Pretends a keyboard is connected, for screenshots.
    public func simulateConnection(name: String, battery: Int) {
        state = .connected(name: name)
        batteryLevel = battery
    }
    #endif

    /// Starts Bluetooth and begins looking for the keyboard. Safe to call more than once.
    public func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Drops the connection (macOS keeps its own link for typing).
    public func stop() {
        searchTask?.cancel()
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        resetConnection(error: .notConnected)
        peripheral = nil
    }

    /// Asks for a fresh battery reading (the keyboard doesn't always push updates).
    public func refreshBattery() {
        guard let peripheral, peripheral.state == .connected, let batteryCharacteristic else { return }
        peripheral.readValue(for: batteryCharacteristic)
    }

    public func waitUntilConnected(timeout: Duration) async throws {
        start()
        let deadline = ContinuousClock.now + timeout
        while !state.isConnected {
            switch state {
            case .poweredOff, .unauthorized, .unsupported:
                throw AnneProError.writeFailed(state.summary)
            default:
                break
            }
            if ContinuousClock.now > deadline { throw AnneProError.timedOut(state.summary) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Requests

    /// Sends a request and, if it has a reply, waits for it.
    @discardableResult
    public func perform(_ request: Request, timeout: Duration = .seconds(3)) async throws -> Message? {
        await mutex.lock()
        defer { mutex.unlock() }
        return try await performLocked(request, timeout: timeout)
    }

    public func refreshInfo() async throws -> DeviceInfo {
        guard let message = try await perform(.deviceInfo), let info = DeviceInfo(message) else {
            throw AnneProError.unexpectedReply("device info")
        }
        self.info = info
        return info
    }

    public func setLightingMode(_ mode: LightingMode) async throws {
        try await performSetter(.setLightingMode(mode))
    }

    public func setBrightness(_ level: Int) async throws {
        try await performSetter(.setBrightness(level))
    }

    public func setLayoutMode(_ mode: LayoutMode) async throws {
        try await performSetter(.setLayoutMode(mode))
    }

    public func readLighting() async throws -> LightingProfile {
        guard let message = try await perform(.customLighting) else { throw AnneProError.unexpectedReply("lighting") }
        return try LightingProfile(payload: message.data)
    }

    public func readLayout() async throws -> KeyLayout {
        guard let message = try await perform(.customLayout) else { throw AnneProError.unexpectedReply("layout") }
        return try KeyLayout(payload: message.data)
    }

    /// Uploads custom lighting, reads it back and retries until the keyboard has it.
    public func writeLighting(_ profile: LightingProfile, attempts: Int = 3) async throws -> UploadResult {
        // The firmware dims over-bright keys, so compare against what it stores.
        let expected = profile.asStoredByKeyboard
        return try await upload(what: "lighting", request: .uploadLighting(profile), readBack: .customLighting, attempts: attempts) { data in
            let stored = try LightingProfile(payload: data)
            let wrong = AnnePro.keys.filter { stored[$0] != expected[$0] }
            guard let first = wrong.first else { return nil }
            return "\(wrong.count) keys differ, first \(first.label) (slot \(first.slot)): got \(stored[first].hex), expected \(expected[first].hex)"
        }
    }

    /// Uploads a custom layout, reads it back and retries until the keyboard has it.
    public func writeLayout(_ layout: KeyLayout, attempts: Int = 3) async throws -> UploadResult {
        if let issue = layout.issues.first { throw AnneProError.writeFailed(issue.description) }
        return try await upload(what: "layout", request: .uploadLayout(layout), readBack: .customLayout, attempts: attempts) { data in
            let stored = try KeyLayout(payload: data)
            if stored.hasSameKeys(as: layout) { return nil }
            let wrong = AnnePro.keys.filter { stored[.base, $0] != layout[.base, $0] || stored[.fn, $0] != layout[.fn, $0] }
            let sample = wrong.prefix(3).map { "\($0.label.isEmpty ? "Space" : $0.label): \(stored[.base, $0])/\(stored[.fn, $0])" }
            return "\(wrong.count) keys differ (\(sample.joined(separator: ", ")))"
        }
    }

    /// Switches to the custom layout only if the keyboard holds a usable one. An empty or
    /// broken custom layout (no Fn/Anne key, or no keys at all) would leave the keyboard dead.
    public func switchToCustomLayoutSafely() async throws {
        let stored = try await readLayout()
        if let issue = stored.issues.first {
            throw AnneProError.writeFailed("the keyboard's custom layout isn't usable (\(issue.description)) Upload a layout first.")
        }
        try await setLayoutMode(.custom)
    }

    /// Setters send one packet. Some are acknowledged; if an expected acknowledgement doesn't
    /// come, the keyboard was probably asleep and missed it, so it is woken and sent again.
    private func performSetter(_ request: Request) async throws {
        await mutex.lock()
        defer { mutex.unlock() }
        _ = try await performLocked(request, timeout: .seconds(1))
        guard let acknowledgement = request.acknowledgement else { return }
        if (try? await awaitReply(acknowledgement, timeout: .milliseconds(800), what: request.name)) != nil { return }
        log("No confirmation for \(request.name); waking the keyboard and resending")
        try await wakeUp()
        _ = try await performLocked(request, timeout: .seconds(1))
        if (try? await awaitReply(acknowledgement, timeout: .milliseconds(800), what: request.name)) == nil {
            log("Still no confirmation for \(request.name)")
        }
    }

    /// The keyboard's key controller sleeps when idle and the first message after that can be
    /// lost. A device-info round trip proves it is awake.
    private func wakeUp() async throws {
        for attempt in 1...4 {
            do {
                _ = try await performLocked(.deviceInfo, timeout: .milliseconds(1200))
                return
            } catch AnneProError.timedOut {
                log("Keyboard not answering yet (try \(attempt))")
            }
        }
        throw AnneProError.timedOut("the keyboard isn't responding")
    }

    private func upload(
        what: String, request: Request, readBack: Request, attempts: Int,
        mismatch: ([UInt8]) throws -> String?
    ) async throws -> UploadResult {
        await mutex.lock()
        defer {
            lastUploadFinished = .now
            mutex.unlock()
        }

        var acknowledged = false
        var readBackAnswered = false
        for attempt in 1...max(1, attempts) {
            if let last = lastUploadFinished, ContinuousClock.now - last < uploadSpacing {
                try await Task.sleep(until: last + uploadSpacing)
            }
            try await wakeUp()
            log("Uploading \(what), attempt \(attempt)")
            do {
                if let ack = try await performLocked(request, timeout: .seconds(3)) {
                    acknowledged = true
                    log("Keyboard acknowledged: \(ack.data.hexString)")
                }
            } catch AnneProError.timedOut {
                log("No acknowledgement; checking anyway")
            }

            try await Task.sleep(for: .milliseconds(300))
            do {
                if let reply = try await performLocked(readBack, timeout: .seconds(3)) {
                    readBackAnswered = true
                    if let difference = try mismatch(reply.data) {
                        log("Read-back didn't match: \(difference)")
                    } else {
                        return .verified
                    }
                }
            } catch AnneProError.timedOut {
                log("Keyboard didn't answer the read-back")
            } catch let error as AnneProDataError {
                log("Read-back unreadable: \(error.localizedDescription)")
            }
            lastUploadFinished = .now
        }
        // Some firmware might never answer read-backs; an acknowledged upload is the best we get.
        if acknowledged && !readBackAnswered { return .unverified }
        throw AnneProError.verificationFailed(what)
    }

    private func performLocked(_ request: Request, timeout: Duration) async throws -> Message? {
        inbox.removeAll()
        expectedReply = request.reply
        defer { expectedReply = nil }
        if verbose { log("\(request.name)") }
        let started = ContinuousClock.now
        for (index, packet) in request.packets.enumerated() {
            if index > 0 { try await Task.sleep(for: interPacketDelay) }
            try await write(packet)
        }
        if request.packets.count > 1 {
            let elapsed = ContinuousClock.now - started
            log("Sent \(request.packets.count) packets in \(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000) ms")
        }
        guard let reply = request.reply else { return nil }
        return try await awaitReply(reply, timeout: timeout, what: request.name)
    }

    // MARK: - Writing and receiving

    private func write(_ packet: [UInt8]) async throws {
        guard let peripheral, let characteristic = writeCharacteristic, peripheral.state == .connected else {
            throw AnneProError.notConnected
        }
        if verbose { log("→ \(packet.hexString)") }
        let data = Data(packet)

        if writeType == .withResponse {
            pendingWriteToken &+= 1
            let token = pendingWriteToken
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pendingWrite = continuation
                peripheral.writeValue(data, for: characteristic, type: .withResponse)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.failPendingWrite(token: token, error: .timedOut("write"))
                }
            }
        } else {
            if !peripheral.canSendWriteWithoutResponse {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    pendingReady = continuation
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(1))
                        self?.resumeReady()
                    }
                }
            }
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        }
    }

    private func failPendingWrite(token: Int, error: AnneProError) {
        guard token == pendingWriteToken, let continuation = pendingWrite else { return }
        pendingWrite = nil
        continuation.resume(throwing: error)
    }

    private func resumeReady() {
        pendingReady?.resume()
        pendingReady = nil
    }

    private func awaitReply(_ key: ReplyKey, timeout: Duration, what: String) async throws -> Message {
        if let index = inbox.firstIndex(where: key.matches) {
            return inbox.remove(at: index)
        }
        replyToken &+= 1
        let token = replyToken
        return try await withCheckedThrowingContinuation { continuation in
            replyWaiter = (key, continuation, token)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.timeOutReply(token: token, what: what)
            }
        }
    }

    private func timeOutReply(token: Int, what: String) {
        guard let waiter = replyWaiter, waiter.token == token else { return }
        replyWaiter = nil
        waiter.continuation.resume(throwing: AnneProError.timedOut(what))
    }

    private func received(_ packet: [UInt8]) {
        if verbose { log("← \(packet.hexString)") }
        guard let message = assembler.feed(packet) else { return }
        if let waiter = replyWaiter, waiter.key.matches(message) {
            replyWaiter = nil
            waiter.continuation.resume(returning: message)
            return
        }
        inbox.append(message)
        if inbox.count > 32 { inbox.removeFirst() }
        if expectedReply?.matches(message) != true, !Self.acknowledgements.contains(ReplyKey(type: message.type, op: message.op)) {
            unsolicitedHandler?(message)
        }
    }

    private func log(_ text: String) {
        logHandler?(text)
    }

    // MARK: - Connection management

    private func centralStateChanged() {
        guard let central else { return }
        log("Bluetooth state: \(central.state.rawValue) (5 = on)")
        switch central.state {
        case .poweredOn:
            beginSearching()
        case .poweredOff:
            resetConnection(error: .notConnected)
            // No disconnect callback arrives when Bluetooth turns off; forget the old link
            // so it can't block reconnecting once Bluetooth is back.
            peripheral = nil
            searchTask?.cancel()
            state = .poweredOff
        case .unauthorized:
            state = .unauthorized
        case .unsupported:
            state = .unsupported
        default:
            break
        }
    }

    private func beginSearching() {
        guard let central, central.state == .poweredOn else { return }
        state = .searching
        searchStarted = Date()
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.connectToSystemKeyboard() { return }
                let scanning = Date().timeIntervalSince(self.searchStarted) < self.scanDuration
                if scanning, !central.isScanning {
                    central.scanForPeripherals(withServices: nil, options: nil)
                } else if !scanning, central.isScanning {
                    self.log("Stopped scanning; waiting for the keyboard to connect to the Mac")
                    central.stopScan()
                }
                try? await Task.sleep(for: .seconds(scanning ? 2 : 5))
            }
        }
    }

    /// The keyboard is normally already connected to macOS as a keyboard; we share that link.
    private func connectToSystemKeyboard() -> Bool {
        guard let central else { return false }
        let byService = central.retrieveConnectedPeripherals(withServices: [AnneProUUID.service])
            .filter { !ignoredPeripherals.contains($0.identifier) }
        let byHID = central.retrieveConnectedPeripherals(withServices: [AnneProUUID.hidService, AnneProUUID.batteryService])
            .filter { Self.looksLikeAnnePro(name: $0.name) && !ignoredPeripherals.contains($0.identifier) }
        guard let match = byService.first ?? byHID.first else { return false }
        connect(match)
        return true
    }

    nonisolated private static func looksLikeAnnePro(name: String?) -> Bool {
        name?.uppercased().contains("ANNE") == true
    }

    private func connect(_ peripheral: CBPeripheral) {
        guard let central else { return }
        searchTask?.cancel()
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        let name = peripheral.name ?? "Anne Pro"
        state = .connecting(name: name)
        log("Connecting to \(name)")
        central.connect(peripheral, options: nil)
    }

    private func resetConnection(error: AnneProError) {
        writeCharacteristic = nil
        notifyCharacteristic = nil
        batteryCharacteristic = nil
        assembler = MessageAssembler()
        inbox.removeAll()
        info = nil
        batteryLevel = nil
        if let continuation = pendingWrite {
            pendingWrite = nil
            continuation.resume(throwing: error)
        }
        resumeReady()
        if let waiter = replyWaiter {
            replyWaiter = nil
            waiter.continuation.resume(throwing: error)
        }
    }

    private func didConnect(_ peripheral: CBPeripheral) {
        log("Connected; discovering services")
        peripheral.discoverServices([AnneProUUID.service, AnneProUUID.batteryService])
    }

    private func didDiscoverServices(_ peripheral: CBPeripheral, error: Error?) {
        let services = peripheral.services ?? []
        guard let control = services.first(where: { $0.uuid == AnneProUUID.service }) else {
            let name = peripheral.name ?? "This keyboard"
            problem = "\(name) doesn't offer the original Anne Pro's settings service. The Anne Pro 2 isn't supported."
            log(problem! + " \(error?.localizedDescription ?? "")")
            ignoredPeripherals.insert(peripheral.identifier)
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([AnneProUUID.notify, AnneProUUID.write], for: control)
        if let battery = services.first(where: { $0.uuid == AnneProUUID.batteryService }) {
            peripheral.discoverCharacteristics([AnneProUUID.batteryLevel], for: battery)
        }
    }

    private func didDiscoverCharacteristics(_ peripheral: CBPeripheral, service: CBService) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case AnneProUUID.write:
                writeCharacteristic = characteristic
                let properties = characteristic.properties
                let canConfirm = properties.contains(.write)
                let canSkip = properties.contains(.writeWithoutResponse)
                writeType = (canConfirm && !(preferWriteWithoutResponse && canSkip)) ? .withResponse : .withoutResponse
                log("Write characteristic: confirmed=\(canConfirm) unconfirmed=\(canSkip)")
            case AnneProUUID.notify:
                notifyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case AnneProUUID.batteryLevel:
                batteryCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            default:
                break
            }
        }
    }

    private func notificationStateChanged(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == AnneProUUID.notify else { return }
        if let error {
            log("Couldn't subscribe to the keyboard: \(error.localizedDescription)")
            return
        }
        guard characteristic.isNotifying, writeCharacteristic != nil else { return }
        let name = peripheral.name ?? "Anne Pro"
        log("Ready (writes \(writeType == .withResponse ? "with" : "without") response)")
        problem = nil
        state = .connected(name: name)
        Task { [weak self] in
            do {
                _ = try await self?.refreshInfo()
            } catch {
                self?.log("Couldn't read device info: \(error.localizedDescription)")
            }
        }
    }

    private func valueUpdated(_ characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        switch characteristic.uuid {
        case AnneProUUID.notify:
            received([UInt8](value))
        case AnneProUUID.batteryLevel:
            batteryLevel = value.first.map(Int.init)
        default:
            break
        }
    }

    private func writeCompleted(_ characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == AnneProUUID.write, let continuation = pendingWrite else { return }
        pendingWrite = nil
        if let error {
            continuation.resume(throwing: AnneProError.writeFailed(error.localizedDescription))
        } else {
            continuation.resume()
        }
    }

    private func disconnected(_ peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        log("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        resetConnection(error: .notConnected)
        self.peripheral = nil
        beginSearching()
    }
}

// MARK: - CoreBluetooth delegates
// The central manager delivers on the main queue, so hopping onto the main actor is safe.

extension AnneProDevice: CBCentralManagerDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { centralStateChanged() }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let isAnne = Self.looksLikeAnnePro(name: advertisedName ?? peripheral.name) || services.contains(AnneProUUID.service)
        guard isAnne else { return }
        MainActor.assumeIsolated {
            guard self.peripheral == nil, !ignoredPeripherals.contains(peripheral.identifier) else { return }
            connect(peripheral)
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { didConnect(peripheral) }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            log("Connection failed: \(error?.localizedDescription ?? "unknown error")")
            disconnected(peripheral, error: error)
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { disconnected(peripheral, error: error) }
    }
}

extension AnneProDevice: CBPeripheralDelegate {
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { didDiscoverServices(peripheral, error: error) }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { didDiscoverCharacteristics(peripheral, service: service) }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { notificationStateChanged(peripheral, characteristic: characteristic, error: error) }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { valueUpdated(characteristic, error: error) }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { writeCompleted(characteristic, error: error) }
    }

    nonisolated public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated { resumeReady() }
    }
}

/// A first-come, first-served lock for async code on the main actor.
@MainActor
final class AsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
