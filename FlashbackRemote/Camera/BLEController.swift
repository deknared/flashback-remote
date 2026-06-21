import CoreBluetooth
import Foundation
import Combine

// MARK: - BLE Constants

private let flashbackServiceUUID = CBUUID(string: "46246F52-C9F2-49A6-821B-D68F02298C97")
private let uuidFB00 = CBUUID(string: "FB00")  // AUTH / USER_TOKEN
private let uuidFB01 = CBUUID(string: "FB01")  // WIFIMODE
private let uuidFB02 = CBUUID(string: "FB02")  // WIFISTATUS
private let uuidFB04 = CBUUID(string: "FB04")  // CONNECT / WiFi trigger
private let uuidFB05 = CBUUID(string: "FB05")  // SSID (AP network name)
private let uuidFB06 = CBUUID(string: "FB06")  // PASSWORD (AP network password)
private let uuidFB10 = CBUUID(string: "FB10")  // IS_WOUND
private let uuidFB20 = CBUUID(string: "FB20")  // ROLL (primary)
private let uuidFB21 = CBUUID(string: "FB21")  // ROLL fallback 1
private let uuidFB22 = CBUUID(string: "FB22")  // ROLL fallback 2
private let uuidFB23 = CBUUID(string: "FB23")  // ROLL fallback 3

private let manufacturerCompanyIDBytes: (UInt8, UInt8) = (0x16, 0x0c)
private let rollIDRange = 1...16_777_215
private let encryptionRetryDelay: TimeInterval = 2.0
private let scanTimeout: TimeInterval = 30.0

// MARK: - Pending Write

private struct PendingWrite {
    let uuid: CBUUID
    let label: String
    let data: Data
    let required: Bool
    let onSuccess: () -> Void
    let onFailure: (Error?) -> Void
}

// MARK: - BLE State

enum BLEState: Equatable {
    case idle
    case scanning
    case connecting
    case discoveringServices
    case discoveringCharacteristics
    case authenticating
    case writingRoll
    case triggeringWiFi
    case connected
    case failed(String)
    case scanTimeout

    var isActive: Bool {
        switch self {
        case .idle, .connected, .failed, .scanTimeout: return false
        default: return true
        }
    }
}

// MARK: - BLEController

@MainActor
final class BLEController: NSObject, ObservableObject {

    @Published var state: BLEState = .idle
    @Published var discoveredCamera: DiscoveredCamera?
    @Published var statusMessage: String = ""
    @Published var wifiStatus: WiFiStatus = .off
    @Published var lastError: String?

    // All cameras seen during the current scan. When more than one appears, the UI
    // lets the user pick which to connect to instead of auto-connecting.
    @Published var discoveredCameras: [DiscoveredCamera] = []
    @Published var awaitingSelection = false

    // Compatibility self-test (used when an unknown firmware is detected).
    enum SelfTestState: Equatable { case idle, running, passed(String), failed(String) }
    @Published var selfTest: SelfTestState = .idle

    // Diagnostics: last raw value seen for every characteristic UUID
    @Published var diagValues: [String: Data] = [:]
    @Published var diagLog: [String] = []

    // AP credentials we generated and pushed to the camera (shown to the user so
    // they can join the hotspot in Settings > WiFi).
    @Published var apSSID: String?
    @Published var apPassword: String?

    // Injected overrides from SettingsStore (set before use)
    var uuidOverrides: BLEUUIDOverrides = BLEUUIDOverrides()

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var peripheralsByID: [UUID: CBPeripheral] = [:]
    private var discoverySettleTimer: DispatchWorkItem?
    private var characteristics: [String: CBCharacteristic] = [:]
    private var pendingWrite: PendingWrite?
    private var retryCounts: [String: Int] = [:]
    private var rollCandidatesRemaining: [CBUUID] = []
    private var rollWriteSucceeded = false
    private var scanTimer: DispatchWorkItem?
    private var operationRollLength: Int = 36
    private var pendingOperation: BLEOperation = .rollAndWifi

    private enum BLEOperation { case rollAndWifi, rollOnly, wifiOnly }

    #if DEBUG
    private(set) var isMockMode = false
    #endif

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Public API

    func startScan() {
        guard central.state == .poweredOn else {
            statusMessage = "Bluetooth is not available"
            return
        }
        discoveredCamera = nil
        discoveredCameras = []
        peripheralsByID = [:]
        awaitingSelection = false
        selfTest = .idle
        characteristics = [:]
        peripheral = nil
        retryCounts = [:]
        state = .scanning
        statusMessage = "Scanning for ONE35 V2…"
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scheduleScanTimeout()
    }

    func stopScan() {
        central.stopScan()
        cancelScanTimer()
        if case .scanning = state { state = .idle }
    }

    func refresh() {
        switch state {
        case .connected:
            // Re-read wound status and signal strength without disconnecting
            guard let p = peripheral else { return }
            if let woundChar = characteristics[uuidFB10.uuidString] {
                p.readValue(for: woundChar)
            }
            p.readRSSI()
        default:
            startScan()
        }
    }

    func configureAndStartWiFi(rollLength: Int) {
        #if DEBUG
        if isMockMode {
            operationRollLength = min(max(rollLength, 1), 100)
            pendingOperation = .rollAndWifi
            Task { await simulateMockWriteFlow() }
            return
        }
        #endif
        guard discoveredCamera != nil, peripheral != nil else {
            lastError = "No camera connected"
            return
        }
        operationRollLength = min(max(rollLength, 1), 100)
        pendingOperation = .rollAndWifi
        lastError = nil
        beginWriteRoll()
    }

    func writeRollOnly(rollLength: Int) {
        guard discoveredCamera != nil, peripheral != nil else {
            lastError = "No camera connected"
            return
        }
        operationRollLength = min(max(rollLength, 1), 100)
        pendingOperation = .rollOnly
        lastError = nil
        beginWriteRoll()
    }

    func startWiFiOnly() {
        guard discoveredCamera != nil, peripheral != nil else {
            lastError = "No camera connected"
            return
        }
        pendingOperation = .wifiOnly
        lastError = nil
        beginAuthForWiFi()
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        resetState()
    }

    // MARK: - Compatibility Self-Test

    /// Non-destructive check that this firmware still speaks the protocol we expect:
    /// all required characteristics are present and the encrypted auth handshake
    /// (FB00) succeeds. Does NOT change roll length or trigger WiFi.
    func runCompatibilityTest() {
        guard state == .connected else {
            selfTest = .failed("Connect to the camera first")
            return
        }
        guard let peripheral, let authChar = characteristics[uuidFB00.uuidString] else {
            selfTest = .failed("FB00 (auth) characteristic missing")
            return
        }
        let required = [uuidFB00, uuidFB01, uuidFB04, uuidFB02, uuidFB10]
        let missing = required.filter { characteristics[$0.uuidString] == nil }
        let hasRoll = [uuidFB20, uuidFB21, uuidFB22, uuidFB23].contains { characteristics[$0.uuidString] != nil }
        guard missing.isEmpty else {
            selfTest = .failed("Missing: \(missing.map { $0.uuidString }.joined(separator: ", "))")
            return
        }
        guard hasRoll else {
            selfTest = .failed("No ROLL characteristic (FB20–FB23)")
            return
        }

        selfTest = .running
        let token = tokenData()
        pendingWrite = PendingWrite(
            uuid: uuidFB00, label: "SELFTEST AUTH FB00", data: token, required: true,
            onSuccess: { [weak self] in
                self?.selfTest = .passed("All characteristics present, auth handshake OK")
            },
            onFailure: { [weak self] error in
                self?.selfTest = .failed("Auth failed: \(error?.localizedDescription ?? "unknown")")
            }
        )
        peripheral.writeValue(token, for: authChar, type: .withResponse)
    }

    // MARK: - Diagnostics

    /// Snapshot of every discovered characteristic with its properties, for the diagnostics screen.
    var discoveredCharacteristicInfo: [(uuid: String, properties: CBCharacteristicProperties)] {
        characteristics
            .map { (uuid: $0.key, properties: $0.value.properties) }
            .sorted { $0.uuid < $1.uuid }
    }

    /// Read every readable characteristic right now (encrypted reads need an
    /// already-encrypted link — run "Auth + Read All" first to establish it).
    func diagReadAll() {
        guard let p = peripheral else { diagAppend("No camera connected"); return }
        diagAppend("Reading all readable characteristics…")
        for (uuid, char) in characteristics where char.properties.contains(.read) {
            diagAppend("→ read \(uuid)")
            p.readValue(for: char)
        }
    }

    /// Authenticate (write FB00) to establish the encrypted link, then read everything.
    /// This is the key diagnostic: encrypted characteristics (SSID/password/status)
    /// only return real data after auth.
    func diagAuthThenReadAll() {
        guard let peripheral, let authChar = characteristics[uuidFB00.uuidString] else {
            diagAppend("No camera connected / FB00 missing")
            return
        }
        let token = tokenData()
        diagAppend("Auth: WRITE FB00 \(token.hexString)")
        state = .authenticating
        pendingWrite = PendingWrite(
            uuid: uuidFB00, label: "DIAG AUTH FB00", data: token, required: true,
            onSuccess: { [weak self] in
                self?.diagAppend("Auth ok — link encrypted")
                self?.state = .connected
                self?.diagReadAll()
            },
            onFailure: { [weak self] error in
                self?.diagAppend("Auth FAILED: \(error?.localizedDescription ?? "unknown")")
                self?.state = .connected
            }
        )
        peripheral.writeValue(token, for: authChar, type: .withResponse)
    }

    /// Full WiFi trigger (auth → FB01 AP mode → FB04 start), then read everything
    /// after a delay so the AP has time to come up. Use this to discover whether an
    /// SSID/password appears in any characteristic once the hotspot is active.
    func diagTriggerWiFiThenReadAll() {
        diagAppend("Triggering WiFi AP, will read all in 4s…")
        startWiFiOnly()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.diagReadAll()
        }
    }

    func diagClear() {
        diagValues = [:]
        diagLog = []
    }

    private func diagAppend(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        diagLog.append("[\(stamp)] \(line)")
        print("[DIAG] \(line)")
    }

    // MARK: - Scan Helpers

    nonisolated private func matchesCamera(name: String, advData: [String: Any]) -> Bool {
        if name.uppercased().contains("ONE35") { return true }
        if let mfr = advData[CBAdvertisementDataManufacturerDataKey] as? Data, mfr.count >= 2 {
            return mfr[0] == manufacturerCompanyIDBytes.0 && mfr[1] == manufacturerCompanyIDBytes.1
        }
        return false
    }

    private func scheduleScanTimeout() {
        cancelScanTimer()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.peripheral == nil {
                self.central.stopScan()
                self.state = .scanTimeout
                self.statusMessage = "No camera found — wind the camera and try again"
            }
        }
        scanTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + scanTimeout, execute: item)
    }

    private func cancelScanTimer() {
        scanTimer?.cancel()
        scanTimer = nil
    }

    // MARK: - Roll Write Flow

    private func beginWriteRoll() {
        guard let peripheral, let authChar = characteristics[uuidFB00.uuidString] else {
            fail("Characteristics not yet discovered — connect first")
            return
        }

        rollCandidatesRemaining = resolveRollCandidates()
        rollWriteSucceeded = false

        if rollCandidatesRemaining.isEmpty {
            fail("No ROLL characteristic found (FB20/FB21/FB22/FB23 missing)")
            return
        }

        let token = tokenData()
        let label = "USER_TOKEN FB00"
        log("WRITE \(label) hex=\(token.hexString)")
        state = .authenticating

        pendingWrite = PendingWrite(
            uuid: uuidFB00, label: label, data: token, required: true,
            onSuccess: { [weak self] in
                self?.log("WRITE \(label) ok — encrypted link established")
                self?.state = .writingRoll
                self?.runNextRollStep()
            },
            onFailure: { [weak self] error in
                self?.fail("Auth failed: \(error?.localizedDescription ?? "unknown")\n\nOpen the official Flashback app, connect to the camera, then retry.")
            }
        )
        peripheral.writeValue(token, for: authChar, type: .withResponse)
    }

    private func resolveRollCandidates() -> [CBUUID] {
        let primary = uuidOverrides.rollPrimary.map { CBUUID(string: $0) } ?? uuidFB20
        let fallbacks = uuidOverrides.rollFallbacks?.map { CBUUID(string: $0) }
            ?? [uuidFB21, uuidFB22, uuidFB23]

        if characteristics[primary.uuidString] != nil { return [primary] }
        return fallbacks.filter { characteristics[$0.uuidString] != nil }
    }

    private func runNextRollStep() {
        guard let peripheral, !rollWriteSucceeded else { return }
        guard let nextUUID = rollCandidatesRemaining.first else {
            fail("All ROLL writes failed — camera may need firmware update")
            return
        }
        rollCandidatesRemaining.removeFirst()
        guard let char = characteristics[nextUUID.uuidString] else {
            runNextRollStep()
            return
        }
        let payload = encodeRollPayload(length: operationRollLength)
        let label = "ROLL via \(nextUUID.uuidString)"
        log("WRITE \(label) len=\(payload.count)")

        pendingWrite = PendingWrite(
            uuid: nextUUID, label: label, data: payload, required: false,
            onSuccess: { [weak self] in
                guard let self else { return }
                self.rollWriteSucceeded = true
                self.log("WRITE \(label) ok — roll length set to \(self.operationRollLength)")
                if self.pendingOperation == .rollOnly {
                    self.state = .connected
                } else {
                    self.beginWiFiTrigger()
                }
            },
            onFailure: { [weak self] _ in
                self?.runNextRollStep()
            }
        )
        peripheral.writeValue(payload, for: char, type: .withResponse)
    }

    // MARK: - WiFi-only Auth

    private func beginAuthForWiFi() {
        guard let peripheral, let authChar = characteristics[uuidFB00.uuidString] else {
            fail("Characteristics not yet discovered — connect first")
            return
        }
        let token = tokenData()
        let label = "USER_TOKEN FB00"
        log("WRITE \(label) hex=\(token.hexString)")
        state = .authenticating
        pendingWrite = PendingWrite(
            uuid: uuidFB00, label: label, data: token, required: true,
            onSuccess: { [weak self] in
                self?.log("WRITE \(label) ok — encrypted link established")
                self?.beginWiFiTrigger()
            },
            onFailure: { [weak self] error in
                self?.fail("Auth failed: \(error?.localizedDescription ?? "unknown")\n\nOpen the official Flashback app, connect to the camera, then retry.")
            }
        )
        peripheral.writeValue(token, for: authChar, type: .withResponse)
    }

    // MARK: - WiFi Trigger

    private func beginWiFiTrigger() {
        guard peripheral != nil else { return }
        state = .triggeringWiFi
        wifiStatus = .starting

        // Reuse the same credentials across launches so iOS auto-reconnects after
        // the first manual join. Credentials are generated once and stored in
        // UserDefaults; deleting the app resets them.
        let (ssid, password) = Self.loadOrGenerateAPCredentials()
        apSSID = ssid
        apPassword = password

        writeAPSSID(ssid: ssid, password: password)
    }

    private static func loadOrGenerateAPCredentials() -> (ssid: String, password: String) {
        let defaults = UserDefaults.standard
        if let ssid = defaults.string(forKey: "ap_ssid"),
           let pw = defaults.string(forKey: "ap_password"),
           !ssid.isEmpty, !pw.isEmpty {
            return (ssid, pw)
        }
        let ssid = "ONE35-" + String(format: "%04X", UInt16.random(in: 0...UInt16.max))
        let pw = randomPassword()
        defaults.set(ssid, forKey: "ap_ssid")
        defaults.set(pw, forKey: "ap_password")
        return (ssid, pw)
    }

    private func writeAPSSID(ssid: String, password: String) {
        guard let peripheral, let ssidChar = characteristics[uuidFB05.uuidString] else {
            diagAppend("FB05 not found — skipping SSID write")
            writeWiFiMode()
            return
        }
        let canWrite = ssidChar.properties.contains(.write) || ssidChar.properties.contains(.writeWithoutResponse)
        diagAppend("WRITE FB05 SSID='\(ssid)' writable=\(canWrite)")
        log("WRITE SSID FB05 = \(ssid)")
        pendingWrite = PendingWrite(
            uuid: uuidFB05, label: "SSID FB05", data: Data(ssid.utf8), required: false,
            onSuccess: { [weak self] in
                self?.diagAppend("FB05 SSID write ✓")
                self?.writeAPPassword(password: password)
            },
            onFailure: { [weak self] err in
                self?.diagAppend("FB05 SSID write ✗: \(err?.localizedDescription ?? "unknown")")
                self?.writeAPPassword(password: password)
            }
        )
        peripheral.writeValue(Data(ssid.utf8), for: ssidChar, type: .withResponse)
    }

    private func writeAPPassword(password: String) {
        guard let peripheral, let pwChar = characteristics[uuidFB06.uuidString] else {
            diagAppend("FB06 not found — skipping password write")
            writeWiFiMode()
            return
        }
        let canWrite = pwChar.properties.contains(.write) || pwChar.properties.contains(.writeWithoutResponse)
        diagAppend("WRITE FB06 PASSWORD writable=\(canWrite)")
        log("WRITE PASSWORD FB06")
        pendingWrite = PendingWrite(
            uuid: uuidFB06, label: "PASSWORD FB06", data: Data(password.utf8), required: false,
            onSuccess: { [weak self] in
                self?.diagAppend("FB06 password write ✓")
                self?.writeWiFiMode()
            },
            onFailure: { [weak self] err in
                self?.diagAppend("FB06 password write ✗: \(err?.localizedDescription ?? "unknown")")
                self?.writeWiFiMode()
            }
        )
        peripheral.writeValue(Data(password.utf8), for: pwChar, type: .withResponse)
    }

    private func writeWiFiMode() {
        guard let peripheral else { return }
        let modeUUID = uuidOverrides.wifiMode.map { CBUUID(string: $0) } ?? uuidFB01
        guard let modeChar = characteristics[modeUUID.uuidString] else {
            fail("WIFIMODE characteristic (FB01) not found")
            return
        }

        log("WRITE WIFIMODE FB01 → 0x02 (AP mode)")
        pendingWrite = PendingWrite(
            uuid: modeUUID, label: "WIFIMODE FB01", data: Data([0x02]), required: true,
            onSuccess: { [weak self] in self?.writeFB04() },
            onFailure: { [weak self] error in
                self?.fail("WiFi mode write failed: \(error?.localizedDescription ?? "unknown")")
            }
        )
        peripheral.writeValue(Data([0x02]), for: modeChar, type: .withResponse)
    }

    private static func randomPassword() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<8).map { _ in chars.randomElement()! })
    }

    private func writeFB04() {
        guard let peripheral else { return }
        let triggerUUID = uuidOverrides.wifiTrigger.map { CBUUID(string: $0) } ?? uuidFB04
        guard let triggerChar = characteristics[triggerUUID.uuidString] else {
            fail("CONNECT characteristic (FB04) not found")
            return
        }

        log("WRITE CONNECT FB04 → 0x01 (start WiFi)")
        pendingWrite = PendingWrite(
            uuid: triggerUUID, label: "CONNECT FB04", data: Data([0x01]), required: true,
            onSuccess: { [weak self] in self?.readWiFiStatus() },
            onFailure: { [weak self] error in
                self?.fail("WiFi trigger write failed: \(error?.localizedDescription ?? "unknown")")
            }
        )
        peripheral.writeValue(Data([0x01]), for: triggerChar, type: .withResponse)
    }

    private func readWiFiStatus() {
        guard let peripheral else { return }
        let statusUUID = uuidOverrides.wifiStatus.map { CBUUID(string: $0) } ?? uuidFB02
        guard let statusChar = characteristics[statusUUID.uuidString] else {
            // Can't confirm, but proceed anyway — the WiFi trigger was sent
            wifiStatus = .up(ip: "192.168.4.1")
            onWiFiConfirmed()
            return
        }
        log("READ WIFISTATUS FB02")
        peripheral.readValue(for: statusChar)
    }

    private func parseWiFiStatusData(_ data: Data) {
        guard !data.isEmpty else { return }
        if data[0] == 0x01 {
            let ip: String
            if data.count >= 5 {
                ip = "\(data[1]).\(data[2]).\(data[3]).\(data[4])"
            } else {
                ip = "192.168.4.1"
            }
            log("WIFISTATUS: connected, IP=\(ip)")
            wifiStatus = .up(ip: ip)
            onWiFiConfirmed()
        } else {
            // Not yet up — retry once after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.readWiFiStatus()
            }
        }
    }

    private func onWiFiConfirmed() {
        state = .connected
        statusMessage = "WiFi ready — join the camera network to transfer files"
        log("WiFi confirmed up — switching to Files tab")
        // FilesViewModel observes wifiStatus to switch tabs

        // Read FB05 back to verify our SSID write stuck. If the camera reports
        // a different (or empty) SSID, that value wins — it's what's actually
        // being broadcast. Result is handled in didUpdateValueFor.
        if let p = peripheral, let ssidChar = characteristics[uuidFB05.uuidString],
           ssidChar.properties.contains(.read) {
            diagAppend("Reading FB05 to verify AP SSID broadcast name…")
            p.readValue(for: ssidChar)
        }
    }

    // MARK: - Helpers

    private func tokenData() -> Data {
        Data(repeating: 0, count: 16)
    }

    private func encodeRollPayload(length: Int) -> Data {
        let body: [String: Int] = [
            "filmTypeId": 1,
            "length": length,
            "rollId": Int.random(in: rollIDRange)
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    private func log(_ msg: String) {
        print("[BLE] \(msg)")
        statusMessage = msg
    }

    private func fail(_ message: String) {
        lastError = message
        state = .failed(message)
        log("ERROR: \(message)")
    }

    private func resetState() {
        peripheral = nil
        characteristics = [:]
        pendingWrite = nil
        retryCounts = [:]
        rollCandidatesRemaining = []
        rollWriteSucceeded = false
        state = .idle
        wifiStatus = .off
        apSSID = nil
        apPassword = nil
        discoveredCameras = []
        peripheralsByID = [:]
        awaitingSelection = false
        selfTest = .idle
        discoverySettleTimer?.cancel()
    }

    // MARK: - Encryption Retry

    private func handleEncryptionError(for pending: PendingWrite) {
        let key = "\(pending.uuid.uuidString)-\(pending.label)"
        if retryCounts[key, default: 0] == 0 {
            retryCounts[key] = 1
            log("WRITE \(pending.label) insufficient encryption; retrying in 2s")
            DispatchQueue.main.asyncAfter(deadline: .now() + encryptionRetryDelay) { [weak self] in
                guard let self,
                      let p = self.peripheral,
                      let char = self.characteristics[pending.uuid.uuidString] else { return }
                self.log("RETRY WRITE \(pending.label)")
                p.writeValue(pending.data, for: char, type: .withResponse)
            }
        } else {
            // Already retried — bond is missing
            pendingWrite = nil
            pending.onFailure(nil)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                if case .scanning = self.state { self.startScan() }
            case .poweredOff:
                self.lastError = "Bluetooth is turned off"
                self.state = .failed("Bluetooth off")
            case .unauthorized:
                self.lastError = "Bluetooth permission denied — enable in Settings"
                self.state = .failed("Bluetooth unauthorized")
            default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? ""
        guard matchesCamera(name: name, advData: advertisementData) else { return }

        Task { @MainActor in
            // Already connecting/connected — ignore further adverts.
            guard self.peripheral == nil else { return }

            var mfrData: ManufacturerData?
            if let raw = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
                mfrData = ManufacturerData.parse(raw)
            }

            let camera = DiscoveredCamera(
                id: peripheral.identifier,
                name: name.isEmpty ? "ONE35 V2" : name,
                rssi: RSSI.intValue,
                manufacturerData: mfrData
            )

            self.peripheralsByID[peripheral.identifier] = peripheral
            if let idx = self.discoveredCameras.firstIndex(where: { $0.id == camera.id }) {
                self.discoveredCameras[idx].rssi = camera.rssi   // refresh signal
            } else {
                self.discoveredCameras.append(camera)
                self.log("Found \(camera.name) rssi=\(RSSI)")
            }

            // Wait briefly so nearby cameras can all show up before we decide
            // whether to auto-connect (one) or ask the user to pick (many).
            self.scheduleDiscoverySettle()
        }
    }

    private func scheduleDiscoverySettle() {
        discoverySettleTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.peripheral == nil else { return }
            if self.discoveredCameras.count == 1, let only = self.discoveredCameras.first {
                self.connect(toID: only.id)
            } else if self.discoveredCameras.count > 1 {
                self.awaitingSelection = true
                self.statusMessage = "\(self.discoveredCameras.count) cameras found — choose one"
            }
        }
        discoverySettleTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    func connect(toID id: UUID) {
        guard let p = peripheralsByID[id] else { return }
        discoverySettleTimer?.cancel()
        cancelScanTimer()
        central.stopScan()
        awaitingSelection = false
        peripheral = p
        p.delegate = self
        discoveredCamera = discoveredCameras.first(where: { $0.id == id })
        state = .connecting
        log("Connecting to \(discoveredCamera?.name ?? id.uuidString)…")
        central.connect(p)
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.log("Connected. Discovering services…")
            self.state = .discoveringServices
            peripheral.discoverServices([flashbackServiceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.fail("Connection failed: \(error?.localizedDescription ?? "unknown")")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.log("Disconnected: \(error?.localizedDescription ?? "clean")")
            if self.pendingWrite != nil {
                self.fail("Disconnected unexpectedly during operation")
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEController: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        Task { @MainActor in
            self.discoveredCamera?.rssi = RSSI.intValue
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let service = peripheral.services?.first(where: { $0.uuid == flashbackServiceUUID }) else {
                self.fail("Flashback service not found — is the camera wound?")
                return
            }
            self.state = .discoveringCharacteristics
            self.log("Discovered Flashback service. Discovering characteristics…")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            for char in service.characteristics ?? [] {
                self.characteristics[char.uuid.uuidString] = char
                self.log("Found characteristic \(char.uuid.uuidString)")
            }

            // Read IS_WOUND (FB10) and subscribe to changes — readable without encryption
            let woundUUID = self.uuidOverrides.isWound.map { CBUUID(string: $0) } ?? uuidFB10
            if let woundChar = self.characteristics[woundUUID.uuidString] {
                peripheral.readValue(for: woundChar)
                if woundChar.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: woundChar)
                }
            }

            self.state = .connected
            self.statusMessage = "Camera ready"
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            let uuid = characteristic.uuid
            let value = characteristic.value ?? Data()

            // Diagnostics: capture every characteristic's raw value + any error
            if let error {
                self.diagLog.append("\(uuid.uuidString): read error — \(error.localizedDescription)")
            } else {
                self.diagValues[uuid.uuidString] = value
            }

            if uuid == (self.uuidOverrides.isWound.map { CBUUID(string: $0) } ?? uuidFB10) {
                let wound = value.first == 0x01
                self.discoveredCamera?.isWound = wound
                self.log("IS_WOUND: \(wound ? "wound ✓" : "not wound ✗")")
            } else if uuid == (self.uuidOverrides.wifiStatus.map { CBUUID(string: $0) } ?? uuidFB02) {
                self.parseWiFiStatusData(value)
            } else if uuid == uuidFB05 {
                // FB05 read-back after WiFi trigger: the camera tells us the actual
                // AP broadcast name. It may differ from (or ignore) what we wrote.
                if let ssid = String(data: value, encoding: .utf8), !ssid.isEmpty {
                    self.diagAppend("FB05 read-back → '\(ssid)' (camera AP name confirmed)")
                    self.apSSID = ssid      // update to what camera actually reports
                } else {
                    self.diagAppend("FB05 read-back → empty. AP name may be fixed by firmware — look for any unknown network in WiFi settings.")
                    // Leave apSSID as the name we generated so the user has something
                    // to try, but the network may appear under a completely different name.
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            guard let pending = self.pendingWrite,
                  pending.uuid == characteristic.uuid else { return }

            if let error {
                let ns = error as NSError
                let isEncryptionError = ns.domain == CBATTError.errorDomain
                    && ns.code == CBATTError.insufficientEncryption.rawValue

                if isEncryptionError {
                    self.handleEncryptionError(for: pending)
                    return
                }

                self.pendingWrite = nil
                if pending.required {
                    self.fail("WRITE \(pending.label) failed: \(error.localizedDescription)")
                } else {
                    self.log("WRITE \(pending.label) failed (optional): \(error.localizedDescription)")
                    pending.onFailure(error)
                }
                return
            }

            self.pendingWrite = nil
            self.log("WRITE \(pending.label) ok")
            pending.onSuccess()
        }
    }
}

// MARK: - UUID Overrides

struct BLEUUIDOverrides {
    var serviceUUID: String?
    var auth: String?
    var rollPrimary: String?
    var rollFallbacks: [String]?
    var wifiMode: String?
    var wifiTrigger: String?
    var wifiStatus: String?
    var isWound: String?
}

// MARK: - Data helpers

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Mock support

#if DEBUG
extension BLEController {
    func activateMock() {
        isMockMode = true
        cancelScanTimer()
        central.stopScan()

        discoveredCamera = DiscoveredCamera(
            id: UUID(),
            name: "ONE35 V2 (Mock)",
            rssi: -62,
            manufacturerData: ManufacturerData(
                companyID: 0x0C16, model: 0x0136,
                serialNumber: 554_191_302, variant: 0,
                filmTypeID: 0, mediaRemaining: 14,
                batteryLevel: 80, flags: 0,
                firmwareMajor: 0, firmwareMinor: 6
            ),
            isWound: true
        )
        state = .connected
        statusMessage = "Mock camera connected (DEBUG)"
    }

    // Simulates the real write sequence including the encryption retry delay,
    // so the full UI flow (authenticating → writingRoll → triggeringWiFi → WiFi up)
    // can be tested without a physical camera.
    func simulateMockWriteFlow() async {
        state = .authenticating
        statusMessage = "WRITE USER_TOKEN FB00…"
        try? await Task.sleep(nanoseconds: 400_000_000)

        // Simulate the expected encryption retry on first connect
        statusMessage = "WRITE USER_TOKEN FB00 insufficient encryption; retrying in 2s"
        try? await Task.sleep(nanoseconds: 2_100_000_000)
        statusMessage = "WRITE USER_TOKEN FB00 ok — encrypted link established"
        try? await Task.sleep(nanoseconds: 200_000_000)

        state = .writingRoll
        statusMessage = "WRITE ROLL via FB20 len=30"
        try? await Task.sleep(nanoseconds: 300_000_000)
        statusMessage = "WRITE ROLL via FB20 ok — roll length set to \(operationRollLength)"
        try? await Task.sleep(nanoseconds: 200_000_000)

        state = .triggeringWiFi
        wifiStatus = .starting
        statusMessage = "WRITE WIFIMODE FB01 → 0x02 (AP mode)"
        try? await Task.sleep(nanoseconds: 300_000_000)
        statusMessage = "WRITE CONNECT FB04 → 0x01 (start WiFi)"
        try? await Task.sleep(nanoseconds: 500_000_000)

        wifiStatus = .up(ip: "192.168.4.1")
        state = .connected
        statusMessage = "WiFi ready — join the camera network to transfer files"
    }
}
#endif
