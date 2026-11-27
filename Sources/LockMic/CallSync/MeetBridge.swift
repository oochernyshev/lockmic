import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "MeetBridge")

/// Google Meet sync. The browser extension talks to the `LockMicNativeHost` helper over
/// Chrome Native Messaging; the helper relays newline-delimited JSON to this Unix socket.
/// Only mute state crosses the link: `{"t":"state","muted":b,"inCall":b}` from the
/// extension and `{"t":"set","muted":b}` back.
@MainActor
final class MeetBridge: CallService {
    let id = CallServiceID.meet
    var onEvent: ((CallServiceEvent) -> Void)?
    var hasActiveCall: Bool { !clients.isEmpty && lastInCall }
    var appDetected: Bool { !clients.isEmpty }
    var status: CallServiceStatus {
        guard listenFD >= 0 else { return .off }
        if clients.isEmpty { return .waiting }
        return lastInCall ? .inCall : .connected
    }

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private final class Client {
        let fd: Int32
        var buffer = Data()
        var source: DispatchSourceRead?
        init(fd: Int32) { self.fd = fd }
    }
    private var clients: [Int32: Client] = [:]
    private var lastInCall = false

    func start() {
        guard listenFD < 0 else { return }
        let path = NativeHostPaths.socketPath
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            return
        }
        chmod(path, 0o600)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        acceptSource = source
        installNativeHostManifests()
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        for client in clients.values { client.source?.cancel(); close(client.fd) }
        clients.removeAll()
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(NativeHostPaths.socketPath)
        lastInCall = false
    }

    func push(muted: Bool) {
        send(["t": "set", "muted": muted])
    }

    // MARK: - Socket

    private func accept() {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        let client = Client(fd: fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            self.read(client)
        }
        source.resume()
        client.source = source
        clients[fd] = client
    }

    private func read(_ client: Client) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(client.fd, &chunk, chunk.count)
        if n <= 0 {
            client.source?.cancel()
            close(client.fd)
            clients[client.fd] = nil
            if clients.isEmpty, lastInCall {
                lastInCall = false
            }
            return
        }
        client.buffer.append(contentsOf: chunk[0..<n])
        while let nl = client.buffer.firstIndex(of: 0x0A) {
            let line = client.buffer[client.buffer.startIndex..<nl]
            client.buffer.removeSubrange(client.buffer.startIndex...nl)
            handle(Data(line))
        }
        if client.buffer.count > 64 * 1024 { client.buffer.removeAll() }
    }

    private func handle(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["t"] as? String == "state" else { return }
        let inCall = obj["inCall"] as? Bool ?? false
        let muted = obj["muted"] as? Bool
        lastInCall = inCall
        onEvent?(CallServiceEvent(muted: muted, inCall: inCall))
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        for client in clients.values {
            data.withUnsafeBytes { _ = Darwin.write(client.fd, $0.baseAddress, data.count) }
        }
    }

    // MARK: - Native messaging manifests (Chrome, Chromium, Edge, Brave, Arc)

    static let extensionID = "nhmoleeoakfddmigjffopbmhhfaimebd"

    private func installNativeHostManifests() {
        guard let host = Bundle.main.executableURL?
            .deletingLastPathComponent().appendingPathComponent("LockMicNativeHost"),
            FileManager.default.isExecutableFile(atPath: host.path) else { return }
        let manifest: [String: Any] = [
            "name": NativeHostPaths.hostName,
            "description": "LockMic mute sync",
            "path": host.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(Self.extensionID)/"],
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        let support = NSHomeDirectory() + "/Library/Application Support"
        let dirs = [
            "Google/Chrome", "Google/Chrome Beta", "Chromium", "Microsoft Edge",
            "BraveSoftware/Brave-Browser", "Arc/User Data",
        ]
        for dir in dirs {
            let root = "\(support)/\(dir)"
            guard FileManager.default.fileExists(atPath: root) else { continue }
            let hostDir = root + "/NativeMessagingHosts"
            try? FileManager.default.createDirectory(atPath: hostDir, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: "\(hostDir)/\(NativeHostPaths.hostName).json"))
        }
    }
}
