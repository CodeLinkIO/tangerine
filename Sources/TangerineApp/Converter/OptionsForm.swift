import SwiftUI
import TangerineKit

/// Conversion presets, shared by Settings (defaults) and the Converter window (per batch).
struct OptionsForm: View {
    @Binding var options: ConversionOptions

    private static let maxSizes: [Int?] = [nil, 4096, 2048, 1600, 1080, 720]
    private static let bitrates = [96, 128, 160, 192, 256, 320]
    private static let sampleRates: [Int?] = [nil, 44_100, 48_000, 96_000]
    private static let dpis = [72, 150, 300, 600]

    var body: some View {
        Form {
            Section("Images") {
                LabeledContent("Quality") {
                    HStack {
                        Slider(value: $options.imageQuality, in: 0.3...1, step: 0.05)
                        Text("\(Int(options.imageQuality * 100))").monospacedDigit().frame(width: 30, alignment: .trailing)
                    }
                }
                Picker("Max size", selection: $options.imageMaxPixelSize) {
                    ForEach(Self.maxSizes, id: \.self) { size in
                        Text(size.map { "\($0) px" } ?? "Original").tag(size)
                    }
                }
                Toggle("Remove metadata and location", isOn: $options.stripImageMetadata)
                Picker("Transparency → JPG", selection: $options.flattenBackground) {
                    Text("White background").tag(SolidColor.white)
                    Text("Black background").tag(SolidColor.black)
                }
            }
            Section("Video") {
                Picker("Resolution", selection: $options.videoResolution) {
                    ForEach(VideoResolution.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Codec", selection: $options.videoCodec) {
                    ForEach(VideoCodec.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent("Quality") {
                    Slider(value: $options.videoQuality, in: 0.2...1, step: 0.05)
                }
                Stepper("GIF: \(options.gifFPS) fps", value: $options.gifFPS, in: 5...30)
                Stepper("GIF width: \(options.gifWidth) px", value: $options.gifWidth, in: 160...1280, step: 40)
            }
            Section("Audio") {
                Picker("Bitrate", selection: $options.audioBitrateKbps) {
                    ForEach(Self.bitrates, id: \.self) { Text("\($0) kbps").tag($0) }
                }
                Picker("Sample rate", selection: $options.audioSampleRate) {
                    ForEach(Self.sampleRates, id: \.self) { rate in
                        Text(rate.map { "\(Double($0) / 1000, specifier: "%.1f") kHz" } ?? "Original").tag(rate)
                    }
                }
            }
            Section("PDF") {
                Picker("Page images", selection: $options.pdfDPI) {
                    ForEach(Self.dpis, id: \.self) { Text("\($0) DPI").tag($0) }
                }
            }
            Section {
                Button("Restore Defaults") { options = ConversionOptions() }
            }
        }
        .formStyle(.grouped)
    }
}
