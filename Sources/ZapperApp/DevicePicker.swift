import SwiftUI
import ATVKit

/// What the panel shows until a TV is picked. Nothing connects on launch, so
/// this is the first screen whenever there are saved TVs.
///
/// TVs that answered the latest network scan come first; the rest are
/// history — TVs from another network, or ones that are off — and sit
/// folded away underneath.
struct DevicePicker: View {
    @ObservedObject var state: AppState
    @State private var showHistory = false

    private var nearby: [Device] { state.devicesNearby }
    private var history: [Device] { state.devicesElsewhere }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Choose a TV")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button {
                    Task { await state.discover() }
                } label: {
                    HStack(spacing: 5) {
                        if state.isScanning {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .bold))
                        }
                        Text(state.isScanning ? "Scanning" : "Scan")
                    }
                }
                .buttonStyle(PillButtonStyle())
                .disabled(state.isScanning)
            }

            if state.bridgePlugged {
                section(title: "Bluetooth · no Wi-Fi needed", count: 0) {
                    DeviceRow(state: state, device: .bluetoothBridge, isNearby: true)
                }
            }

            section(title: "On this network", count: nearby.count) {
                if nearby.isEmpty {
                    Text(state.isScanning
                         ? "Looking for TVs on this network…"
                         : "No saved TV answered on this network. Turn the TV on, then Scan.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 6)
                } else {
                    ForEach(nearby) { device in
                        DeviceRow(state: state, device: device, isNearby: true)
                    }
                }
            }

            if !history.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showHistory.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(showHistory ? 90 : 0))
                            Text("Saved, not found here (\(history.count))")
                                .font(.system(size: 11, weight: .semibold))
                            Spacer()
                        }
                        .foregroundStyle(Theme.textTertiary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showHistory {
                        VStack(spacing: 4) {
                            ForEach(history) { device in
                                DeviceRow(state: state, device: device, isNearby: false)
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.nearby)
    }

    private func section<Content: View>(title: String, count: Int,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(count > 0 ? "\(title) (\(count))" : title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            VStack(spacing: 4) { content() }
        }
    }
}

private struct DeviceRow: View {
    @ObservedObject var state: AppState
    let device: Device
    let isNearby: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: device.isBluetoothBridge ? "dot.radiowaves.left.and.right" : "tv")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isNearby ? Theme.accentSoft : Theme.textTertiary)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surfaceRaised))
                Circle()
                    .fill(isNearby ? Theme.online : Theme.textTertiary.opacity(0.6))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Theme.backgroundTop, lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(state.displayName(device))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isNearby ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering && !device.isBluetoothBridge {
                Button { state.forget(device) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Forget \(device.name)")
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(hovering ? Theme.surfaceRaised : Theme.surface))
        .contentShape(Rectangle())
        .onTapGesture { state.select(device.id) }
        .onHover { hovering = $0 }
        .help(isNearby ? "Connect to \(device.name)" : "Try \(device.name) anyway")
    }

    private var detail: String {
        if device.isBluetoothBridge { return "USB adapter · real mouse and typing" }
        if let used = device.lastConnected { return "Used " + AppState.relative(used) }
        var host = device.host
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        return host
    }
}
