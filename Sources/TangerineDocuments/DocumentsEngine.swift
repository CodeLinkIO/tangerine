import TangerineCore

/// Entry point used by TangerineKit to register this engine's backends.
///
/// Conversions:
/// - PDF → PNG, JPG, TIFF, HEIC (every page) and TXT, MD, DOCX, RTF, ODT, HTML, EPUB (text, OCR fallback)
/// - DOCX, DOC, RTF, RTFD, ODT, HTML, TXT, Markdown, Web Archive → PDF, DOCX, RTF, ODT, HTML, TXT, MD, EPUB
///
/// Tools: Merge PDF (PDFs and images), Split Pages, Compress (PDF).
public enum DocumentsEngine {
    public static let conversionBackends: [any ConversionBackend] = [PDFRasterBackend(), DocumentBackend()]
    public static let toolBackends: [any ToolBackend] = [PDFToolBackend()]
}
