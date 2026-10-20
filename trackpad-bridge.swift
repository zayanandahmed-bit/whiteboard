// Trackpad bridge: reads absolute finger positions from the Mac trackpad
// (MultitouchSupport) and streams them to the whiteboard over a local WebSocket.
// Only listens on 127.0.0.1, so nothing leaves this Mac.
//
// Build:  swiftc -O -swift-version 5 trackpad-bridge.swift -o trackpad-bridge
// Run:    ./trackpad-bridge      (or double-click "Start Trackpad Bridge.command")

import Foundation
import Network

let PORT: UInt16 = 47800
setvbuf(stdout, nil, _IONBF, 0)

// ---------- WebSocket server ----------
let queue = DispatchQueue(label: "bridge")
var clients: [ObjectIdentifier: NWConnection] = [:]

func broadcast(_ text: String) {
    queue.async {
        guard !clients.isEmpty, let data = text.data(using: .utf8) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "f", metadata: [meta])
        for c in clients.values {
            c.send(content: data, contentContext: ctx, isComplete: true, completion: .idempotent)
        }
    }
}

func receiveLoop(_ c: NWConnection) {
    c.receiveMessage { _, _, _, error in
        if error == nil { receiveLoop(c) }
    }
}

let params = NWParameters.tcp
params.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: PORT)!)
params.allowLocalEndpointReuse = true

let listener: NWListener
do { listener = try NWListener(using: params) }
catch { print("Could not open port \(PORT): \(error)"); exit(1) }

listener.newConnectionHandler = { c in
    let id = ObjectIdentifier(c)
    c.stateUpdateHandler = { state in
        switch state {
        case .ready: clients[id] = c; print("Whiteboard connected (\(clients.count) open)")
        case .failed, .cancelled: clients[id] = nil; print("Whiteboard disconnected")
        default: break
        }
    }
    c.start(queue: queue)
    receiveLoop(c)
}
listener.stateUpdateHandler = { state in
    if case .failed(let e) = state { print("Server error: \(e)"); exit(1) }
}
listener.start(queue: queue)

// ---------- Multitouch (private framework) ----------
typealias MTContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
typealias CreateListFn = @convention(c) () -> Unmanaged<CFArray>
typealias RegisterFn = @convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void
typealias StartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void

guard let mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
      let s1 = dlsym(mt, "MTDeviceCreateList"),
      let s2 = dlsym(mt, "MTRegisterContactFrameCallback"),
      let s3 = dlsym(mt, "MTDeviceStart") else {
    print("Could not load the macOS multitouch framework."); exit(1)
}
let createList = unsafeBitCast(s1, to: CreateListFn.self)
let register = unsafeBitCast(s2, to: RegisterFn.self)
let start = unsafeBitCast(s3, to: StartFn.self)

// Each finger record is 96 bytes; normalized x/y (0…1, y measured from the bottom) sit at offsets 32/36.
let FINGER_SIZE = 96
var lastWasEmpty = false

let callback: MTContactCallback = { _, data, count, _, _ in
    let n = Int(count)
    if n == 0 || data == nil {
        if !lastWasEmpty { broadcast("{\"f\":[]}") }
        lastWasEmpty = true
        return 0
    }
    lastWasEmpty = false
    var parts: [String] = []
    parts.reserveCapacity(n)
    for i in 0..<n {
        let p = data!.advanced(by: i * FINGER_SIZE)
        let id = p.loadUnaligned(fromByteOffset: 16, as: Int32.self)
        let state = p.loadUnaligned(fromByteOffset: 20, as: Int32.self)
        let x = p.loadUnaligned(fromByteOffset: 32, as: Float.self)
        let y = p.loadUnaligned(fromByteOffset: 36, as: Float.self)
        let size = p.loadUnaligned(fromByteOffset: 48, as: Float.self)
        parts.append(String(format: "[%d,%.4f,%.4f,%d,%.3f]", id, x, 1 - y, state, size))
    }
    broadcast("{\"f\":[" + parts.joined(separator: ",") + "]}")
    return 0
}

let devices = createList().takeRetainedValue() as [AnyObject]
if devices.isEmpty { print("No trackpad found."); exit(1) }
for d in devices {
    let ptr = Unmanaged.passUnretained(d).toOpaque()
    register(ptr, callback)
    start(ptr, 0)
}

print("""

  ✅ Trackpad bridge is running (\(devices.count) touch device\(devices.count == 1 ? "" : "s")).
  Open the whiteboard and turn on "Tablet mode".
  Keep this window open while you present. Close it (⌘Q) when done.

""")
RunLoop.main.run()
