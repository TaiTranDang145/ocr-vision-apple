# Vision OCR API

Small macOS 26 API that renders each scanned-PDF page, uses Apple Vision document recognition, and returns one Markdown file. Build it with an Xcode version that includes the macOS 26 SDK.

```sh
swift run VisionOCRAPI                 # LAN: 0.0.0.0:8888
swift run VisionOCRAPI --self-test
curl -X POST http://MAC_LAN_IP:8888/ocr \
  -H 'Content-Type: application/pdf' \
  -H 'X-Filename: scanned-document.pdf' \
  --data-binary @scanned-document.pdf \
  -OJ
```

The endpoint accepts a PDF up to 200 MB and downloads `{X-Filename}.md`; omit `X-Filename` to get `ocr.md`. It recognizes Vietnamese and joins pages in order. For scanned PDFs it uses the largest embedded JPEG/JPEG2000 image to avoid OCRing added watermark/text layers, upscaling low-resolution scans toward 300 DPI; other PDFs fall back to rendering at up to 4× resolution (50 million pixels/page). Paragraphs are Markdown text and detected tables are semantic HTML `<table>` blocks inside the Markdown file.

Do not expose `0.0.0.0` directly to the Internet: this minimal server has no authentication or TLS. Put it behind an authenticated HTTPS reverse proxy if callers are outside a trusted network.
