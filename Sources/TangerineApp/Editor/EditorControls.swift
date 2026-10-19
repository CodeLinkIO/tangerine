import SwiftUI

enum EditorStyle {
    /// Tangerine orange, #F35B28.
    static let accent = Color(.sRGB, red: 0xF3 / 255, green: 0x5B / 255, blue: 0x28 / 255, opacity: 1)
    static let sidebarWidth: CGFloat = 300
}

/// A compact slider with a label, value readout, center-anchored fill and double-click to reset.
struct EditorSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -1...1
    var defaultValue: Double = 0
    var format: (Double) -> String = { EditorFormatting.signedValue($0) }
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onReset: () -> Void

    @State private var isDragging = false

    private var span: Double { range.upperBound - range.lowerBound }

    private func fraction(_ v: Double) -> CGFloat {
        CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(value == defaultValue ? .secondary : .primary)
            }
            .font(.callout)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onReset)

            GeometryReader { geometry in
                let width = geometry.size.width
                let knob: CGFloat = 14
                let track = width - knob
                let current = fraction(value), zero = fraction(defaultValue)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.14))
                        .frame(height: 4)
                        .padding(.horizontal, knob / 2)
                    Capsule()
                        .fill(EditorStyle.accent)
                        .frame(width: abs(current - zero) * track, height: 4)
                        .offset(x: knob / 2 + min(current, zero) * track)
                    if zero > 0, zero < 1 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.35))
                            .frame(width: 1, height: 8)
                            .offset(x: knob / 2 + zero * track - 0.5)
                    }
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                        .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                        .frame(width: knob, height: knob)
                        .scaleEffect(isDragging ? 1.12 : 1)
                        .offset(x: current * track)
                }
                .frame(height: 18)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            if !isDragging {
                                isDragging = true
                                onEditingChanged(true)
                            }
                            let f = min(max((drag.location.x - knob / 2) / max(track, 1), 0), 1)
                            value = range.lowerBound + Double(f) * span
                        }
                        .onEnded { _ in
                            isDragging = false
                            onEditingChanged(false)
                        }
                )
                .simultaneousGesture(TapGesture(count: 2).onEnded(onReset))
            }
            .frame(height: 18)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            let step = span / 50
            value = min(max(value + (direction == .increment ? step : -step), range.lowerBound), range.upperBound)
        }
    }
}

/// Small rounded toggle button used for aspect presets and fills.
struct EditorChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? EditorStyle.accent.opacity(0.18) : Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isSelected ? EditorStyle.accent : Color.clear, lineWidth: 1.2)
                )
                .foregroundStyle(isSelected ? EditorStyle.accent : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Square icon button with a tooltip.
struct EditorIconButton: View {
    let symbol: String
    let help: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isActive ? EditorStyle.accent.opacity(0.18) : Color.primary.opacity(0.06))
                )
                .foregroundStyle(isActive ? EditorStyle.accent : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Header row for inspector groups.
struct EditorGroupHeader: View {
    let title: String
    var resetEnabled = false
    var onReset: (() -> Void)?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            Spacer()
            if let onReset {
                Button("Reset", action: onReset)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(!resetEnabled)
            }
        }
    }
}
