import AppKit
import TangerineCore

/// Converts between text documents, and extracts text from PDFs into document formats.
struct DocumentBackend: ConversionBackend {
    let id = "documents"

    static let inputs: Set<FileFormat> = [.docx, .doc, .rtf, .rtfd, .odt, .html, .txt, .md, .webarchive]
    static let outputs: Set<FileFormat> = [.pdf, .docx, .rtf, .odt, .html, .txt, .md, .epub]
    static let pdfOutputs: Set<FileFormat> = [.txt, .md, .docx, .rtf, .odt, .html, .epub]

    func supports(from: FileFormat, to: FileFormat) -> Bool {
        guard from != to else { return false }
        if from == .pdf { return Self.pdfOutputs.contains(to) }
        return Self.inputs.contains(from) && Self.outputs.contains(to)
    }

    func convert(_ input: URL, from: FileFormat, to: FileFormat, output: OutputPlan,
                 context: ConversionContext) async throws -> [URL] {
        guard supports(from: from, to: to) else { throw ConversionError.unsupported(from: from, to: to.displayName) }
        let source = try await DocumentSource.load(input, format: from, context: context)
        try Task.checkCancellation()
        let destination = output.file(extension: to.fileExtension)
        do {
            try await Self.write(source, as: to, to: destination, title: output.baseName)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        context.progress(1)
        return [destination]
    }

    static func write(_ source: DocumentSource, as format: FileFormat, to url: URL, title: String) async throws {
        switch format {
        case .txt:
            try writeString(try await source.plainText, to: url)
        case .md:
            try writeString(try await source.markdown, to: url)
        case .html:
            try writeString(try await source.html(title: title), to: url)
        case .docx, .rtf, .odt, .doc:
            let text = try await source.attributedString
            let type: NSAttributedString.DocumentType = switch format {
            case .docx: .officeOpenXML
            case .rtf: .rtf
            case .odt: .openDocument
            default: .docFormat
            }
            let data = try text.data(from: NSRange(location: 0, length: text.length),
                                     documentAttributes: [.documentType: type])
            try data.write(to: url, options: .atomic)
        case .pdf:
            try PaginatedPDFWriter.write(try await source.attributedString, to: url, title: title)
        case .epub:
            try EPUBWriter.write(blocks: try await source.epubBlocks, fallbackTitle: title, to: url)
        default:
            throw ConversionError.unsupported(from: nil, to: format.displayName)
        }
    }

    private static func writeString(_ string: String, to url: URL) throws {
        try Data(string.utf8).write(to: url, options: .atomic)
    }
}
