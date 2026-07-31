import AppKit
import Darwin
import Foundation
import Network
import PDFKit
import Vision

let maxPDFBytes = 200 * 1024 * 1024
let maxPagePixels = 50_000_000

func response(_ status: Int, type: String, body: Data, attachment: String? = nil) -> Data {
    let reason = status == 200 ? "OK" : status == 404 ? "Not Found" : "Bad Request"
    let disposition = attachment.map { "Content-Disposition: attachment; filename=\"\($0)\"\r\n" } ?? ""
    return Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\n\(disposition)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
}

func jsonResponse(_ status: Int, _ body: Any) -> Data {
    let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{\"error\":\"serialization failed\"}".utf8)
    return response(status, type: "application/json", body: data)
}

func render(_ page: PDFPage) throws -> CGImage {
    let bounds = page.bounds(for: .mediaBox)
    guard bounds.width > 0, bounds.height > 0 else { throw NSError(domain: "OCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "PDF page has invalid dimensions"]) }
    let scale = min(CGFloat(4), sqrt(CGFloat(maxPagePixels) / (bounds.width * bounds.height)))
    let width = Int((bounds.width * scale).rounded(.up)), height = Int((bounds.height * scale).rounded(.up))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "OCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not render PDF page"])
    }
    context.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: context)
    guard let image = context.makeImage() else { throw NSError(domain: "OCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create page image"]) }
    return image
}

func html(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\n", with: "<br>")
}

func tableHTML(_ table: DocumentObservation.Container.Table) -> String {
    "<table>\n" + table.rows.map { row in
        "  <tr>" + row.map { "<td>\(html($0.content.text.transcript))</td>" }.joined() + "</tr>"
    }.joined(separator: "\n") + "\n</table>"
}

func recognizeDocument(_ cgImage: CGImage) async throws -> String {
    guard let imageData = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "OCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode PDF page"])
    }
    var request = RecognizeDocumentsRequest()
    var options = request.textRecognitionOptions
    options.recognitionLanguages = [Locale.Language(identifier: "vi")]
    options.useLanguageCorrection = true
    request.textRecognitionOptions = options
    let observations = try await request.perform(on: imageData)
    guard let document = observations.first?.document else {
        throw NSError(domain: "OCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Vision could not recognize this page"])
    }
    let text = ([document.title?.transcript].compactMap { $0 } + document.paragraphs.map(\.transcript)).joined(separator: "\n\n")
    let tables = document.tables.enumerated().map { "### Table \($0.offset + 1)\n\n" + tableHTML($0.element) }.joined(separator: "\n\n")
    return [text, tables].filter { !$0.isEmpty }.joined(separator: "\n\n")
}

func markdown(_ pages: [String]) -> String {
    "# OCR result\n" + pages.enumerated().map { "\n## Page \($0.offset + 1)\n\n" + $0.element + "\n" }.joined()
}

func outputFilename(_ value: String?) -> String {
    let raw = value?.components(separatedBy: CharacterSet(charactersIn: "/\\\r\n\"")).joined(separator: "_") ?? "ocr.pdf"
    let base = URL(fileURLWithPath: raw).deletingPathExtension().lastPathComponent
    return (base.isEmpty ? "ocr" : base) + ".md"
}

func ocrMarkdown(_ data: Data) async throws -> String {
    guard let document = PDFDocument(data: data), document.pageCount > 0 else {
        throw NSError(domain: "OCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Body must be a non-empty PDF"])
    }
    var pages = [String]()
    for index in 0..<document.pageCount {
        guard let page = document.page(at: index) else { throw NSError(domain: "OCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read PDF page \(index + 1)"]) }
        pages.append(try await recognizeDocument(render(page)))
    }
    return markdown(pages)
}

func handle(_ data: Data) async -> Data {
    guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
          let header = String(data: data[..<separator.lowerBound], encoding: .utf8) else {
        return jsonResponse(400, ["error": "Invalid HTTP request"])
    }
    let lines = header.components(separatedBy: "\r\n")
    guard lines.first == "POST /ocr HTTP/1.1" || lines.first == "POST /ocr HTTP/1.0" else {
        return jsonResponse(404, ["error": "Use POST /ocr"])
    }
    var headers = [String: String]()
    for line in lines.dropFirst() where line.contains(":") {
        let pair = line.split(separator: ":", maxSplits: 1)
        headers[String(pair[0]).lowercased()] = String(pair[1]).trimmingCharacters(in: .whitespaces)
    }
    guard let length = headers["content-length"].flatMap(Int.init), length >= 0, length <= maxPDFBytes else {
        return jsonResponse(400, ["error": "Content-Length is required and must be at most \(maxPDFBytes) bytes"])
    }
    let body = Data(data[separator.upperBound...])
    guard body.count == length else { return jsonResponse(400, ["error": "Incomplete request body"]) }
    do {
        return response(200, type: "text/markdown; charset=utf-8", body: Data(try await ocrMarkdown(body).utf8), attachment: outputFilename(headers["x-filename"]))
    } catch {
        return jsonResponse(400, ["error": error.localizedDescription])
    }
}

func expectedRequestSize(_ data: Data) -> Int? {
    guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
          let header = String(data: data[..<separator.lowerBound], encoding: .utf8) else { return nil }
    let length = header.components(separatedBy: "\r\n").dropFirst().first { $0.lowercased().hasPrefix("content-length:") }
        .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }
    return length.map { separator.upperBound + $0 }
}

func receiveRequest(on connection: NWConnection, buffer: Data = Data()) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, _ in
        // ponytail: buffers one PDF; stream to a temporary file if 200 MB requests exhaust RAM.
        var buffer = buffer
        buffer.append(data ?? Data())
        guard buffer.count <= maxPDFBytes + 16 * 1024 else {
            connection.send(content: jsonResponse(400, ["error": "Request too large"]), completion: .contentProcessed { _ in connection.cancel() }); return
        }
        if let expected = expectedRequestSize(buffer) {
            if expected > maxPDFBytes + 16 * 1024 || buffer.count >= expected {
                Task { connection.send(content: await handle(buffer), completion: .contentProcessed { _ in connection.cancel() }) }
            } else if complete {
                connection.send(content: jsonResponse(400, ["error": "Incomplete request"]), completion: .contentProcessed { _ in connection.cancel() })
            } else {
                receiveRequest(on: connection, buffer: buffer)
            }
        } else if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
            Task { connection.send(content: await handle(buffer), completion: .contentProcessed { _ in connection.cancel() }) }
        } else if complete {
            connection.send(content: jsonResponse(400, ["error": "Incomplete request"]), completion: .contentProcessed { _ in connection.cancel() })
        } else {
            receiveRequest(on: connection, buffer: buffer)
        }
    }
}

let arguments = CommandLine.arguments
if arguments.contains("--self-test") {
    assert(markdown(["first", "second"]).contains("## Page 2\n\nsecond"))
    assert(outputFilename("hoa-don.pdf") == "hoa-don.md")
    print("ok")
    exit(0)
}
let host = arguments.dropFirst().first ?? "0.0.0.0"
let port = arguments.dropFirst(2).first.flatMap(UInt16.init) ?? 8888
guard let nwPort = NWEndpoint.Port(rawValue: port), let address = IPv4Address(host) else {
    fputs("Usage: VisionOCRAPI [host] [port]\n", stderr); exit(2)
}
let listener: NWListener
do {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(address), port: nwPort)
    listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { connection in connection.start(queue: .global()); receiveRequest(on: connection) }
    listener.start(queue: .main)
    print("Vision OCR API listening on http://\(host):\(port)/ocr")
    dispatchMain()
} catch {
    fputs("Could not listen: \(error)\n", stderr); exit(1)
}
