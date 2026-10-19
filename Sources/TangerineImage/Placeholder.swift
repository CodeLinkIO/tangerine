import TangerineCore

/// Entry point used by TangerineKit to register this engine's backends.
public enum ImageEngine {
    public static let conversionBackends: [any ConversionBackend] = []
    public static let toolBackends: [any ToolBackend] = []
}
