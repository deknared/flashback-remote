import SwiftUI

// Fitness-style ring dashboard for the Camera tab: shots used vs roll length,
// with battery and signal as smaller stats beside it.
struct RollRingView: View {
    let shotsUsed: Int
    let rollTotal: Int
    let batteryPercent: Int
    let rssi: Int

    private var progress: Double {
        guard rollTotal > 0 else { return 0 }
        return min(1, max(0, Double(shotsUsed) / Double(rollTotal)))
    }

    private var ringColor: Color {
        progress >= 1 ? .red : .accentColor
    }

    var body: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: progress)
                VStack(spacing: 0) {
                    Text("\(shotsUsed)")
                        .font(.title2.bold())
                    Text("of \(rollTotal)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 92, height: 92)

            VStack(alignment: .leading, spacing: 10) {
                statRow(icon: "battery.100", label: "Battery", value: "\(batteryPercent)%",
                       tint: batteryPercent < 20 ? .red : .green)
                statRow(icon: rssiIcon, label: "Signal", value: "\(rssi) dBm", tint: .accentColor)
            }
            Spacer()
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.06)))
    }

    private var rssiIcon: String {
        rssi < -80 ? "wifi.exclamationmark" : "wifi"
    }

    private func statRow(icon: String, label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.semibold))
        }
        .frame(minWidth: 120)
    }
}
