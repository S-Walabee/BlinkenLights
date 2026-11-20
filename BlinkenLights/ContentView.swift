import SwiftUI

/// A single round LED.
struct LEDView: View {
    let isOn: Bool
    let color: Color
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: isOn
                        ? [Color.white.opacity(0.9), color, color.opacity(0.85)]
                        : [color.opacity(0.28), color.opacity(0.14), Color.black.opacity(0.6)],
                    center: UnitPoint(x: 0.35, y: 0.3),
                    startRadius: 0,
                    endRadius: size * 0.75
                )
            )
            .overlay(Circle().strokeBorder(Color.black.opacity(0.55), lineWidth: 0.75))
            .frame(width: size, height: size)
            .shadow(color: isOn ? color.opacity(0.9) : .clear, radius: isOn ? 4 : 0)
    }
}

/// Read (green) and write (red) LEDs plus the volume's name.
struct VolumeView: View {
    let volume: VolumeState
    let vertical: Bool

    var body: some View {
        HStack(spacing: 4) {
            LEDView(isOn: volume.reading, color: Color(red: 0.2, green: 1.0, blue: 0.3))
            LEDView(isOn: volume.writing, color: Color(red: 1.0, green: 0.18, blue: 0.15))
            Text(volume.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 1)
                .lineLimit(1)
                .padding(.leading, 2)
                .help(volume.isNetwork ? "\(volume.name) (network share)" : volume.name)
        }
        .frame(maxWidth: vertical ? .infinity : nil, alignment: .leading)
    }
}

struct ContentView: View {
    let monitor: VolumeMonitor
    let settings: AppSettings
    /// Called with the content's size whenever it changes, so the window can fit it.
    let onSizeChange: (CGSize) -> Void

    var body: some View {
        Group {
            if settings.isVertical {
                VStack(alignment: .leading, spacing: 5) { items }
            } else {
                HStack(spacing: 14) { items }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(white: 0.08).opacity(settings.backgroundOpacity))
        )
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
        .animation(nil, value: monitor.volumes)
    }

    @ViewBuilder private var items: some View {
        if monitor.volumes.isEmpty {
            Text("No volumes").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        ForEach(monitor.volumes) { volume in
            VolumeView(volume: volume, vertical: settings.isVertical)
        }
    }
}
