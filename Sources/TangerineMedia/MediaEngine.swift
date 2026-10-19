import TangerineCore

/// Entry point used by TangerineKit to register the video and audio engines.
public enum MediaEngine {
    /// Native backends come first so Core Audio and AVFoundation handle what they can; ffmpeg fills the gaps.
    public static let conversionBackends: [any ConversionBackend] = [
        AVVideoBackend(),
        NativeAudioBackend(),
        FFmpegMediaBackend(),
    ]

    public static let toolBackends: [any ToolBackend] = [MediaToolBackend()]
}
