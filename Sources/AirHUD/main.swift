import AppKit
import SwiftUI
import CoreWLAN
import Network

// MARK: - Pill Frame Preference Key
struct PillFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

// MARK: - Pass-Through Hosting View
final class AirHUDHostingView<Content: View>: NSHostingView<Content> {
    var pillFrame: NSRect = .zero
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitBounds = pillFrame.insetBy(dx: -4, dy: -4)
        if !hitBounds.isEmpty && !hitBounds.contains(point) {
            return nil
        }
        return super.hitTest(point)
    }
}

// MARK: - Snapping NSPanel Subclass
final class SnappingPanel: NSPanel {
    var onDragEnded: (() -> Void)?
    var isUserDragging: Bool = false
    
    override var canBecomeKey: Bool {
        false
    }
    
    override var canBecomeMain: Bool {
        false
    }
    
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            isUserDragging = false
        case .leftMouseDragged:
            isUserDragging = true
        case .leftMouseUp:
            if isUserDragging {
                isUserDragging = false
                super.sendEvent(event)
                onDragEnded?()
                return
            }
            isUserDragging = false
        default:
            break
        }
        super.sendEvent(event)
    }
}

// MARK: - Apple Instant Hotspot Device Model
struct AppleHotspotInfo {
    let name: String
    let generation: String
    let signalStrength: Int
    let batteryLife: Int
}

// MARK: - Apple Instant Hotspot Manager (Same API as macOS Control Center)
final class AppleInstantHotspotManager: NSObject {
    static let shared = AppleInstantHotspotManager()
    
    private var session: AnyObject?
    private(set) var discoveredDevices: [String: AppleHotspotInfo] = [:]
    var onUpdate: (() -> Void)?
    
    override init() {
        super.init()
        setupSession()
    }
    
    private func setupSession() {
        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/Sharing.framework") else { return }
        bundle.load()
        guard let sessionClass = NSClassFromString("SFRemoteHotspotSession") as? NSObject.Type else { return }
        
        let sess = sessionClass.init()
        sess.setValue(self, forKey: "delegate")
        self.session = sess
        sess.perform(Selector(("startBrowsing")))
    }
    
    @objc func session(_ session: AnyObject, updatedFoundDevices devices: [NSObject]) {
        var newDevices: [String: AppleHotspotInfo] = [:]
        for dev in devices {
            let desc = dev.description
            guard let name = dev.value(forKey: "deviceName") as? String, !name.isEmpty else { continue }
            let signal = (dev.value(forKey: "signalStrength") as? Int) ?? 0
            let battery = (dev.value(forKey: "batteryLife") as? Int) ?? 0
            let netType = (dev.value(forKey: "networkType") as? Int) ?? 0
            
            let gen: String
            if netType >= 8 || desc.contains("network type: 5G") {
                gen = "5G"
            } else {
                gen = "4G"
            }
            
            newDevices[name.lowercased()] = AppleHotspotInfo(
                name: name,
                generation: gen,
                signalStrength: signal,
                batteryLife: battery
            )
        }
        
        DispatchQueue.main.async {
            self.discoveredDevices = newDevices
            self.onUpdate?()
        }
    }
    
    func matchingDevice(for ssid: String) -> AppleHotspotInfo? {
        let lower = ssid.lowercased()
        if let direct = discoveredDevices[lower] {
            return direct
        }
        let cleanSSID = lower.replacingOccurrences(of: "’", with: "'")
        for (key, info) in discoveredDevices {
            let cleanKey = key.replacingOccurrences(of: "’", with: "'")
            if cleanKey == cleanSSID || cleanKey.contains(cleanSSID) || cleanSSID.contains(cleanKey) {
                return info
            }
        }
        if discoveredDevices.count == 1, let first = discoveredDevices.values.first {
            return first
        }
        return nil
    }
}

// MARK: - Network Monitor
final class AirHUDMonitor: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var isHotspot: Bool = false
    @Published var ssid: String = "Detecting..."
    @Published var rssi: Int = 0
    @Published var transmitRate: Double = 0.0
    @Published var cellularGeneration: String = "4G"
    @Published var signalBars: Int = 0
    @Published var latencyMs: Double = 0.0
    @Published var batteryLife: Int = 0
    
    private var timer: Timer?
    private var latencyTimer: Timer?
    private var activeConnection: NWConnection?
    private var recentLatencies: [Double] = []
    
    private let client = CWWiFiClient.shared()
    private var lastKnownSSID: String?
    
    // Tracks previous cellular generation exclusively for hotspot downgrade alerts
    private var previousHotspotGeneration: String?
    
    var onUpdate: (() -> Void)?
    
    func start() {
        AppleInstantHotspotManager.shared.onUpdate = { [weak self] in
            self?.poll()
        }
        
        poll()
        probeLatency()
        
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        
        latencyTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.probeLatency()
        }
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
        latencyTimer?.invalidate()
        latencyTimer = nil
        activeConnection?.cancel()
        activeConnection = nil
    }
    
    func probeLatency() {
        guard client.interface()?.rssiValue() != 0 else { return }
        
        let host = NWEndpoint.Host("1.1.1.1")
        let port = NWEndpoint.Port(integerLiteral: 443)
        let conn = NWConnection(host: host, port: port, using: .tcp)
        self.activeConnection = conn
        
        let startTime = DispatchTime.now()
        
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            switch state {
            case .ready:
                let endTime = DispatchTime.now()
                let nano = endTime.uptimeNanoseconds - startTime.uptimeNanoseconds
                let ms = Double(nano) / 1_000_000.0
                conn?.cancel()
                DispatchQueue.main.async {
                    self?.handleLatencyMeasurement(ms)
                }
            case .failed, .cancelled:
                conn?.cancel()
            default:
                break
            }
        }
        
        conn.start(queue: DispatchQueue.global(qos: .utility))
    }
    
    private func handleLatencyMeasurement(_ ms: Double) {
        self.latencyMs = ms
        recentLatencies.append(ms)
        if recentLatencies.count > 4 {
            recentLatencies.removeFirst()
        }
        self.poll()
    }
    
    func poll() {
        guard let iface = client.interface() else {
            DispatchQueue.main.async {
                self.isConnected = false
                self.isHotspot = false
                self.signalBars = 0
                self.rssi = 0
                self.ssid = "No Wi-Fi Interface"
                self.previousHotspotGeneration = nil
                self.onUpdate?()
            }
            return
        }
        
        let rssiVal = iface.rssiValue()
        let txRate = iface.transmitRate()
        let channel = iface.wlanChannel()?.channelNumber
        
        var detectedSSID = iface.ssid()
        var beaconInterval: Int = 0
        
        // Query cached scan results to identify the connected network
        if let cached = iface.cachedScanResults() {
            // Find network matching channel and closest in RSSI
            let onChannel = cached.filter { $0.wlanChannel?.channelNumber == channel && channel != nil }
            if let matched = onChannel.min(by: { abs($0.rssiValue - rssiVal) < abs($1.rssiValue - rssiVal) }) ?? cached.first {
                if detectedSSID == nil || detectedSSID?.isEmpty == true {
                    detectedSSID = matched.ssid
                }
                beaconInterval = matched.beaconInterval
            }
        }
        
        let connected = rssiVal != 0 && rssiVal > -100
        
        // Cache and persist SSID across polls so transient nil scans don't lose the network name
        if let currentSSID = detectedSSID, !currentSSID.isEmpty, currentSSID != "Connected" {
            self.lastKnownSSID = currentSSID
        } else if let cachedSSID = self.lastKnownSSID {
            detectedSSID = cachedSSID
        }
        
        let ssidString = detectedSSID ?? (connected ? "Connected" : "Disconnected")
        let ssidLower = ssidString.lowercased()
        
        // Comprehensive Hotspot Keywords & Detection
        let hotspotKeywords = [
            "iphone", "android", "galaxy", "hotspot", "pixel", "ipad", "cellular",
            "oneplus", "xiaomi", "redmi", "poco", "oppo", "vivo", "realme",
            "huawei", "honor", "motorola", "moto", "phone", "5g", "4g", "lte"
        ]
        
        var isHotspotNetwork = hotspotKeywords.contains(where: { ssidLower.contains($0) }) || beaconInterval >= 250
        
        // Secondary check: examine nearby cached networks with strong signal
        if !isHotspotNetwork, let cached = iface.cachedScanResults() {
            for net in cached where net.rssiValue >= -65 {
                let name = (net.ssid ?? "").lowercased()
                if hotspotKeywords.contains(where: { name.contains($0) }) {
                    isHotspotNetwork = true
                    if detectedSSID == nil || detectedSSID == "Connected" {
                        detectedSSID = net.ssid
                        self.lastKnownSSID = net.ssid
                    }
                    break
                }
            }
        }
        
        // Check Apple Instant Hotspot (macOS Control Center source of truth)
        let appleHotspot = AppleInstantHotspotManager.shared.matchingDevice(for: ssidString)
        if appleHotspot != nil {
            isHotspotNetwork = true
        }
        
        // 100% Autonomous Hotspot Detection
        let hotspotDetected = connected && isHotspotNetwork
        
        // Accurate Cellular 5G vs 4G Auto-Detection (Control Center + Background Speed/Latency)
        let gen: String
        if !connected {
            gen = "4G"
        } else if let apple = appleHotspot {
            // Read DIRECTLY from macOS Control Center / Instant Hotspot
            gen = apple.generation
        } else {
            // Fallback for Android / non-Apple hotspots using background latency & speed polling
            let avgLatency = recentLatencies.isEmpty ? latencyMs : (recentLatencies.reduce(0, +) / Double(recentLatencies.count))
            
            if ssidLower.contains("5g") && !ssidLower.contains("4g") {
                gen = (avgLatency > 80.0) ? "4G" : "5G"
            } else if ssidLower.contains("4g") || ssidLower.contains("lte") {
                gen = "4G"
            } else {
                // 5G latency is typically 15ms-45ms. 4G LTE is typically 55ms-120ms.
                if avgLatency > 0.0 {
                    gen = (avgLatency < 50.0) ? "5G" : "4G"
                } else {
                    gen = "4G"
                }
            }
        }
        
        // Map Wi-Fi / Hotspot signal strength to 4 ascending signal bars
        let bars: Int
        if !connected || rssiVal == 0 || rssiVal < -100 {
            bars = 0
        } else if let apple = appleHotspot, apple.signalStrength > 0 {
            // Exact cellular reception tower bars from Apple Control Center
            bars = min(4, max(1, apple.signalStrength))
        } else if rssiVal >= -60 {
            bars = 4
        } else if rssiVal >= -70 {
            bars = 3
        } else if rssiVal >= -80 {
            bars = 2
        } else {
            bars = 1
        }
        
        // Downgrade notification: only in case of hotspot, when moving from 5G to 4G
        if hotspotDetected && connected {
            if let prev = previousHotspotGeneration, prev == "5G" && gen == "4G" {
                sendDowngradeNotification(ssid: ssidString)
            }
            previousHotspotGeneration = gen
        } else {
            previousHotspotGeneration = nil
        }
        
        DispatchQueue.main.async {
            self.isConnected = connected
            self.isHotspot = hotspotDetected
            self.ssid = ssidString
            self.rssi = rssiVal
            self.transmitRate = txRate
            self.cellularGeneration = gen
            self.signalBars = bars
            self.batteryLife = appleHotspot?.batteryLife ?? 0
            self.onUpdate?()
        }
    }
    
    private func sendDowngradeNotification(ssid: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let script = """
            display notification "Personal Hotspot dropped from 5G to 4G (\(ssid))." with title "AirHUD" subtitle "Cellular Network Alert" sound name "Ping"
            """
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
            }
        }
    }
}

// MARK: - SwiftUI HUD View
struct AirHUDView: View {
    @ObservedObject var monitor: AirHUDMonitor
    var isNearRightSide: Bool
    var onClose: (() -> Void)?
    var onPillFrameChanged: ((CGRect) -> Void)?
    
    @State private var isHovered: Bool = false
    @State private var isCloseHovered: Bool = false
    
    var is5G: Bool {
        monitor.cellularGeneration == "5G"
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // Right-anchoring spacer when docked on the right side of the screen
            if isNearRightSide {
                Spacer(minLength: 0)
            }
            
            // The Glass Pill Widget
            HStack(spacing: 8) {
                // Revealed on Hover: Connection Icon
                if isHovered {
                    Group {
                        if !monitor.isConnected {
                            Image(systemName: "wifi.slash")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(Color.white.opacity(0.4))
                        } else if monitor.isHotspot {
                            Image(systemName: "personalhotspot")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(Color(red: 0.18, green: 0.58, blue: 1.0))
                                .shadow(color: Color.blue.opacity(0.4), radius: 4, x: 0, y: 0)
                        } else {
                            Image(systemName: "wifi")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(Color(red: 0.22, green: 0.95, blue: 0.55))
                                .shadow(color: Color.green.opacity(0.4), radius: 4, x: 0, y: 0)
                        }
                    }
                    .frame(width: 18, height: 18)
                    .layoutPriority(2)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
                
                // Compact State: ONLY the Badge is shown (5G / 4G / Wi-Fi / Offline)
                Group {
                    if !monitor.isConnected {
                        Text("Offline")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundColor(Color.white.opacity(0.55))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(
                                Capsule().fill(Color.white.opacity(0.1))
                            )
                            .overlay(
                                Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                            )
                    } else if monitor.isHotspot {
                        Text(monitor.cellularGeneration)
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(
                                    is5G
                                        ? Color(red: 0.16, green: 0.78, blue: 0.34) // Solid Green background for 5G
                                        : Color(red: 0.92, green: 0.22, blue: 0.25)  // Solid Red background for 4G
                                )
                            )
                            .shadow(
                                color: (is5G ? Color.green : Color.red).opacity(0.35),
                                radius: 4, x: 0, y: 1
                            )
                    } else {
                        Text("Wi-Fi")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundColor(Color(red: 0.25, green: 0.95, blue: 0.65))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(
                                Capsule().fill(Color.green.opacity(0.16))
                            )
                            .overlay(
                                Capsule().strokeBorder(Color.green.opacity(0.35), lineWidth: 1)
                            )
                    }
                }
                .fixedSize()
                .layoutPriority(2)
                
                // Revealed on Hover: Tower bars / Wi-Fi bars, dBm text, and Close button
                if isHovered {
                    // Cellular Tower Bar for Hotspot
                    if monitor.isHotspot && monitor.isConnected {
                        HStack(alignment: .bottom, spacing: 2.2) {
                            ForEach(0..<4) { index in
                                let isActive = index < monitor.signalBars
                                RoundedRectangle(cornerRadius: 1.2)
                                    .fill(
                                        isActive
                                            ? (is5G
                                                ? Color(red: 0.22, green: 0.95, blue: 0.45)
                                                : Color(red: 1.0, green: 0.28, blue: 0.32))
                                            : Color.white.opacity(0.22)
                                    )
                                    .frame(width: 3.5, height: [5.0, 8.5, 12.0, 16.0][index])
                            }
                        }
                        .frame(height: 16, alignment: .bottom)
                        .fixedSize()
                        .layoutPriority(2)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                    
                    // Wi-Fi signal bars for standard Wi-Fi
                    if !monitor.isHotspot && monitor.isConnected {
                        HStack(alignment: .bottom, spacing: 2.2) {
                            ForEach(0..<4) { index in
                                let isActive = monitor.isConnected && index < monitor.signalBars
                                RoundedRectangle(cornerRadius: 1.2)
                                    .fill(
                                        isActive
                                            ? Color.white
                                            : Color.white.opacity(0.22)
                                    )
                                    .frame(width: 3.5, height: [5.0, 8.5, 12.0, 16.0][index])
                            }
                        }
                        .frame(height: 16, alignment: .bottom)
                        .fixedSize()
                        .layoutPriority(1)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                    
                    // Signal strength text in dBm and phone battery life on hover
                    Text(monitor.isConnected ? (monitor.isHotspot ? (monitor.batteryLife > 0 ? "\(monitor.batteryLife)% 🔋 • \(monitor.rssi) dBm" : (monitor.latencyMs > 0 ? "\(Int(monitor.latencyMs))ms • \(monitor.rssi) dBm" : "\(monitor.rssi) dBm")) : "\(monitor.rssi) dBm") : "-- dBm")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(monitor.isConnected ? Color.white.opacity(0.92) : Color.white.opacity(0.45))
                        .lineLimit(1)
                        .fixedSize()
                        .layoutPriority(1)
                        .transition(.opacity)
                    
                    // Close / Hide button
                    Button(action: {
                        onClose?()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(
                                isCloseHovered
                                    ? Color.white
                                    : Color.white.opacity(0.5)
                            )
                            .scaleEffect(isCloseHovered ? 1.1 : 1.0)
                            .animation(.easeInOut(duration: 0.15), value: isCloseHovered)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isCloseHovered = hovering
                    }
                    .help("Hide AirHUD")
                    .fixedSize()
                    .layoutPriority(2)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .padding(.horizontal, isHovered ? 11 : 7)
            .padding(.vertical, isHovered ? 7 : 5)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.28), Color.white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Color.black.opacity(0.35), radius: 8, x: 0, y: 4)
            .contentShape(Rectangle())
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: PillFrameKey.self, value: proxy.frame(in: .global))
                }
            )
            .onPreferenceChange(PillFrameKey.self) { frame in
                if frame != .zero {
                    onPillFrameChanged?(frame)
                }
            }
            .onHover { hovering in
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    isHovered = hovering
                }
            }
            
            // Left-anchoring spacer when docked on the left side of the screen
            if !isNearRightSide {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(width: 290, height: 48)
    }
}

// MARK: - Application Delegate
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayPanel: SnappingPanel!
    private var hostingView: AirHUDHostingView<AirHUDView>!
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem?
    private var visibilityToggleMenuItem: NSMenuItem?
    private let monitor = AirHUDMonitor()
    
    // Fixed window frame size (290 gives full clearance for icon, badge, bars, battery, dBm, and close button)
    private let windowWidth: CGFloat = 290
    private let windowHeight: CGFloat = 48
    
    // Geometry metrics
    private let margin: CGFloat = 16
    private let snapThreshold: CGFloat = 35
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure as accessory app (LSUIElement behavior, hidden from Dock)
        NSApp.setActivationPolicy(.accessory)
        
        setupStatusBar()
        setupOverlayPanel()
        
        monitor.onUpdate = { [weak self] in
            self?.handleStateUpdate()
        }
        
        monitor.start()
        
        // Reposition on display parameter updates
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleDisplayChange()
        }
    }
    
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "personalhotspot", accessibilityDescription: "AirHUD")
            button.image?.isTemplate = true
        }
        
        let menu = NSMenu()
        
        let titleItem = NSMenuItem(title: "AirHUD", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        
        let statusItemMenu = NSMenuItem(title: "Detecting connection...", action: nil, keyEquivalent: "")
        statusItemMenu.isEnabled = false
        menu.addItem(statusItemMenu)
        self.statusMenuItem = statusItemMenu
        
        menu.addItem(NSMenuItem.separator())
        
        let toggleItem = NSMenuItem(
            title: "Hide HUD",
            action: #selector(toggleHUDVisibility),
            keyEquivalent: "h"
        )
        toggleItem.target = self
        menu.addItem(toggleItem)
        self.visibilityToggleMenuItem = toggleItem
        
        let resetPosItem = NSMenuItem(
            title: "Reset Position to Bottom-Right",
            action: #selector(resetPositionToBottomRight),
            keyEquivalent: "r"
        )
        resetPosItem.target = self
        menu.addItem(resetPosItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(
            title: "Quit AirHUD",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    @objc private func toggleHUDVisibility() {
        guard let panel = overlayPanel else { return }
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }
    
    @objc private func resetPositionToBottomRight() {
        positionPanelBottomRight()
        if let panel = overlayPanel {
            savePosition(panel.frame.origin)
        }
        updateViewHierarchy()
        showPanel()
    }
    
    private func hidePanel() {
        overlayPanel?.orderOut(nil)
        visibilityToggleMenuItem?.title = "Show HUD"
    }
    
    private func showPanel() {
        overlayPanel?.orderFrontRegardless()
        visibilityToggleMenuItem?.title = "Hide HUD"
    }
    
    private func handleStateUpdate() {
        if let button = statusItem.button {
            let symbolName: String
            if !monitor.isConnected {
                symbolName = "wifi.slash"
            } else if monitor.isHotspot {
                symbolName = "personalhotspot"
            } else {
                symbolName = "wifi"
            }
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "AirHUD")
            button.image?.isTemplate = true
        }
        
        if monitor.isConnected {
            if monitor.isHotspot {
                statusMenuItem?.title = "\(monitor.ssid) (Hotspot \(monitor.cellularGeneration), \(monitor.rssi) dBm)"
            } else {
                statusMenuItem?.title = "\(monitor.ssid) (Wi-Fi, \(monitor.rssi) dBm)"
            }
        } else {
            statusMenuItem?.title = "Disconnected (Offline)"
        }
    }
    
    private func setupOverlayPanel() {
        let panel = SnappingPanel(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        
        panel.isMovableByWindowBackground = true
        panel.ignoresMouseEvents = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        
        self.overlayPanel = panel
        
        // Restore position or default to bottom-right
        restoreOrSetInitialPosition()
        
        // Attach content view with initial orientation
        updateViewHierarchy()
        
        panel.onDragEnded = { [weak self] in
            self?.handleDragEnded()
        }
        
        panel.orderFrontRegardless()
    }
    
    private func updateViewHierarchy() {
        guard let panel = overlayPanel,
              let screen = panel.screen ?? NSScreen.main else { return }
        
        let isNearRight = (panel.frame.maxX > screen.visibleFrame.midX)
        
        var hudView = AirHUDView(monitor: monitor, isNearRightSide: isNearRight)
        hudView.onClose = { [weak self] in
            self?.hidePanel()
        }
        hudView.onPillFrameChanged = { [weak self] frame in
            self?.hostingView?.pillFrame = frame
        }
        
        let host = AirHUDHostingView(rootView: hudView)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.hostingView = host
    }
    
    // MARK: - Position Persistence
    private func savePosition(_ origin: CGPoint) {
        UserDefaults.standard.set(Double(origin.x), forKey: "AirHUD_lastX")
        UserDefaults.standard.set(Double(origin.y), forKey: "AirHUD_lastY")
    }
    
    private func loadSavedPosition() -> CGPoint? {
        if UserDefaults.standard.object(forKey: "AirHUD_lastX") != nil,
           UserDefaults.standard.object(forKey: "AirHUD_lastY") != nil {
            let x = CGFloat(UserDefaults.standard.double(forKey: "AirHUD_lastX"))
            let y = CGFloat(UserDefaults.standard.double(forKey: "AirHUD_lastY"))
            return CGPoint(x: x, y: y)
        }
        return nil
    }
    
    private func restoreOrSetInitialPosition() {
        guard let panel = overlayPanel,
              let screen = NSScreen.main else { return }
        
        let screenVisibleFrame = screen.visibleFrame
        
        if let saved = loadSavedPosition() {
            let minAllowedX = screenVisibleFrame.minX + margin
            let maxAllowedX = screenVisibleFrame.maxX - windowWidth - margin
            let clampedX = max(minAllowedX, min(saved.x, maxAllowedX))
            
            let minAllowedY = screenVisibleFrame.minY + margin
            let maxAllowedY = screenVisibleFrame.maxY - windowHeight - margin
            let clampedY = max(minAllowedY, min(saved.y, maxAllowedY))
            
            panel.setFrame(NSRect(x: clampedX, y: clampedY, width: windowWidth, height: windowHeight), display: true, animate: false)
        } else {
            positionPanelBottomRight()
            savePosition(panel.frame.origin)
        }
    }
    
    private func positionPanelBottomRight() {
        guard let panel = overlayPanel,
              let screen = NSScreen.main else { return }
        
        let screenVisibleFrame = screen.visibleFrame
        let x = screenVisibleFrame.maxX - windowWidth - margin
        let y = screenVisibleFrame.minY + margin
        
        panel.setFrame(NSRect(x: x, y: y, width: windowWidth, height: windowHeight), display: true, animate: false)
    }
    
    // MARK: - Edge & Corner Magnet Snapping
    private func handleDragEnded() {
        guard let panel = overlayPanel,
              let screen = panel.screen ?? NSScreen.main else { return }
        
        let snappedOrigin = calculateSnapOrigin(
            panelFrame: panel.frame,
            screenVisibleFrame: screen.visibleFrame
        )
        
        if snappedOrigin != panel.frame.origin {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrameOrigin(snappedOrigin)
            }, completionHandler: { [weak self] in
                self?.savePosition(snappedOrigin)
                self?.updateViewHierarchy()
            })
        } else {
            savePosition(panel.frame.origin)
            updateViewHierarchy()
        }
    }
    
    private func calculateSnapOrigin(panelFrame: NSRect, screenVisibleFrame: NSRect) -> CGPoint {
        let distLeft = panelFrame.minX - screenVisibleFrame.minX
        let distRight = screenVisibleFrame.maxX - panelFrame.maxX
        let distBottom = panelFrame.minY - screenVisibleFrame.minY
        let distTop = screenVisibleFrame.maxY - panelFrame.maxY
        
        var targetX = panelFrame.origin.x
        var targetY = panelFrame.origin.y
        
        // Edge snapping (flush with 16pt margin)
        if distLeft < snapThreshold {
            targetX = screenVisibleFrame.minX + margin
        } else if distRight < snapThreshold {
            targetX = screenVisibleFrame.maxX - windowWidth - margin
        }
        
        if distBottom < snapThreshold {
            targetY = screenVisibleFrame.minY + margin
        } else if distTop < snapThreshold {
            targetY = screenVisibleFrame.maxY - windowHeight - margin
        }
        
        // Keep clamped inside screen bounds
        let minAllowedX = screenVisibleFrame.minX + margin
        let maxAllowedX = screenVisibleFrame.maxX - windowWidth - margin
        targetX = max(minAllowedX, min(targetX, maxAllowedX))
        
        let minAllowedY = screenVisibleFrame.minY + margin
        let maxAllowedY = screenVisibleFrame.maxY - windowHeight - margin
        targetY = max(minAllowedY, min(targetY, maxAllowedY))
        
        return CGPoint(x: targetX, y: targetY)
    }
    
    private func handleDisplayChange() {
        guard let panel = overlayPanel,
              let screen = panel.screen ?? NSScreen.main else { return }
        let screenVisibleFrame = screen.visibleFrame
        
        let minAllowedX = screenVisibleFrame.minX + margin
        let maxAllowedX = screenVisibleFrame.maxX - windowWidth - margin
        let clampedX = max(minAllowedX, min(panel.frame.minX, maxAllowedX))
        
        let minAllowedY = screenVisibleFrame.minY + margin
        let maxAllowedY = screenVisibleFrame.maxY - windowHeight - margin
        let clampedY = max(minAllowedY, min(panel.frame.minY, maxAllowedY))
        
        panel.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
        savePosition(panel.frame.origin)
        updateViewHierarchy()
    }
}

// MARK: - App Entrypoint
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
