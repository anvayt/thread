import AVKit
import SwiftUI
import UIKit

// Thread looks like the phone it runs on: the system's colours, type,
// lists and controls, in light and dark, with Liquid Glass for the controls
// that float over content. The only branding is the name, in the system
// font, and the app icon (see `thread-backend/assets/BRAND.md`), so there
// is no palette or type scale here, only the few pieces several screens share.

/// A person in a list: their photo or initials, their name, and one line
/// about them.
struct PersonRow: View {
    let name: String
    var subtitle = ""
    /// Short status at the trailing edge, such as "New".
    var trailing = ""
    var trailingIsProblem = false
    var avatarSize: CGFloat = 40

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: name, size: avatarSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if !trailing.isEmpty {
                Spacer(minLength: 8)
                Text(trailing)
                    .font(.subheadline)
                    .foregroundStyle(trailingIsProblem ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The top of a person's page, set the way Contacts sets it: a large photo or
/// monogram, the name, and a line or two about them. Shown on a clear row at
/// the top of a list.
struct PersonHeader: View {
    let name: String
    var subtitle = ""
    var caption = ""
    var avatarSize: CGFloat = 104

    var body: some View {
        VStack(spacing: 10) {
            Avatar(name: name, size: avatarSize)
                .padding(.bottom, 4)
            Text(name)
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.center)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !caption.isEmpty {
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A square action under a `PersonHeader`, in glass, the way Contacts sets
/// Message and Call under a name.
struct HeaderAction: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HeaderActionLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
    }
}

/// The label of a `HeaderAction`, for use inside a `ShareLink` or `Menu`.
struct HeaderActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(height: 24)
            Text(title)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(Color.accentColor)
        .frame(width: 84, height: 60)
        .contentShape(.rect(cornerRadius: 16))
    }
}

/// Bars that follow the microphone level while Thread listens, the way
/// Voice Memos draws a recording as it happens.
struct LevelMeter: View {
    /// 0 to 1, as the microphone reports it.
    let level: Double
    var bars = 32
    var height: CGFloat = 40

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var history: [Double] = []

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, value in
                Capsule()
                    .frame(width: 3, height: max(3, height * value))
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: history)
        .onChange(of: level) { _, new in
            var next = history.isEmpty ? Array(repeating: 0, count: bars) : history
            next.removeFirst()
            // A little lift so quiet speech still reads as speech.
            next.append(min(1, max(0, new * 1.6)))
            history = next
        }
        .accessibilityHidden(true)
    }

    private var samples: [Double] {
        history.isEmpty ? Array(repeating: 0, count: bars) : history
    }
}

/// A small feature line: a symbol, a title and a sentence. Used by the
/// welcome sheet and the guide.
struct FeatureRow: View {
    let systemImage: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// States a problem in a list row.
struct ProblemLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

/// Opens Thread's page in the Settings app.
struct OpenSettingsButton: View {
    var body: some View {
        Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }
}

extension Double {
    /// Seconds as a clock reads them, "0:07", the way Voice Memos shows a
    /// recording's length.
    var clockText: String {
        Duration.seconds(self).formatted(.time(pattern: .minuteSecond))
    }
}

/// Apple's own sound-output picker, the one in Control Center: tapping it
/// lists the iPhone speaker and any Bluetooth devices, such as the glasses.
/// Apps cannot choose a Bluetooth speaker themselves, so this is how the
/// wearer sends cards to the glasses from inside Thread.
struct SoundOutputPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = .label
        picker.activeTintColor = .tintColor
        picker.accessibilityLabel = "Sound output"
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
