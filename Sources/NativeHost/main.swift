import Foundation

// LockMicNativeHost: relays Chrome Native Messaging (4-byte LE length + JSON on stdio)
// to LockMic's local socket (newline-delimited JSON). Exits quietly when LockMic is not running.

let socketPath = NSHomeDirectory() + "/Library/Application Support/LockMic/sync.sock"

func connectSocket() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) }
    }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if rc != 0 { close(fd); return nil }
    return fd
}

func readExactly(_ fd: Int32, _ count: Int) -> Data? {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: count)
    while data.count < count {
        let n = read(fd, &buf, count - data.count)
        if n <= 0 { return nil }
        data.append(contentsOf: buf[0..<n])
    }
    return data
}

func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        var off = 0
        while off < data.count {
            let n = write(fd, raw.baseAddress! + off, data.count - off)
            if n <= 0 { return }
            off += n
        }
    }
}

signal(SIGPIPE, SIG_IGN)
// Not running / integration off: exit; the extension's port closes and it retries later.
guard let sock = connectSocket() else { exit(0) }

// socket -> stdout (framed)
let outThread = Thread {
    var pending = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(sock, &buf, buf.count)
        if n <= 0 { exit(0) }
        pending.append(contentsOf: buf[0..<n])
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[pending.startIndex..<nl])
            pending.removeSubrange(pending.startIndex...nl)
            var len = UInt32(line.count).littleEndian
            var frame = Data(bytes: &len, count: 4)
            frame.append(line)
            writeAll(STDOUT_FILENO, frame)
        }
    }
}
outThread.start()

// stdin (framed) -> socket
while let header = readExactly(STDIN_FILENO, 4) {
    let len = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
    guard len > 0, len < 64 * 1024, var body = readExactly(STDIN_FILENO, len) else { break }
    body.removeAll { $0 == 0x0A }
    body.append(0x0A)
    writeAll(sock, body)
}
exit(0)
