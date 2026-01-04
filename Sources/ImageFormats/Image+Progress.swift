import CImageFormats
import LibPNG

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(WinSDK)
  import WinSDK
#endif

extension ImageFormats.Image<RGBA> {
  private final class PNGReadContext {
    let data: [UInt8]
    var offset = 0
    let strictRead: Bool
    init(_ data: [UInt8], strictRead: Bool) {
      self.data = data
      self.strictRead = strictRead
    }
  }

  public static func loadPNG(
    from data: [UInt8],
    progressHandler: ((Double) -> Void)? = nil,
    warningHandler: ((String) -> Void)? = nil,
    strictRead: Bool = false
  ) throws -> Self {
    // libpng "classic" API setup
    guard let pngPtr = png_create_read_struct(PNG_LIBPNG_VER_STRING, nil, nil, nil) else {
      throw ImageLoadingError.pngError(code: -1, message: "Failed to create read struct")
    }
    defer {
      var pngPtrCopy: png_structp? = pngPtr
      png_destroy_read_struct(&pngPtrCopy, nil, nil)
    }

    guard let infoPtr = png_create_info_struct(pngPtr) else {
      throw ImageLoadingError.pngError(code: -1, message: "Failed to create info struct")
    }

    // Set error/warning handlers: errors longjmp; warnings forwarded to Swift
    swift_png_set_error_handlers(pngPtr)
    defer { swift_png_clear_error_handlers(pngPtr) }

    // Install optional warning callback
    let warningBox = warningHandler.map { Unmanaged.passRetained(PNGWarningBox($0)) }
    if let warningBox {
      swift_png_set_warning_callback(pngPtr, pngWarningTrampoline, warningBox.toOpaque())
    }
    defer {
      if let warningBox { warningBox.release() }
    }

    // Make CRC issues warnings rather than hard failures
    png_set_crc_action(pngPtr, PNG_CRC_WARN_USE, PNG_CRC_WARN_DISCARD)

    // --- Custom read-from-memory setup ---
    let context = Unmanaged.passRetained(PNGReadContext(data, strictRead: strictRead))
    defer { context.release() }

    let readCallback: png_rw_ptr = { pngPtr, outBytes, byteCount in
      guard byteCount > 0 else { return }
      guard let outBytes else { return }
      let ctx = Unmanaged<PNGReadContext>.fromOpaque(png_get_io_ptr(pngPtr)!)
        .takeUnretainedValue()

      let available = ctx.data.count - ctx.offset
      let toCopy = min(Int(byteCount), available)
      if toCopy == Int(byteCount) {
        ctx.data.withUnsafeBytes { bytes in
          let src = bytes.baseAddress!.advanced(by: ctx.offset)
          memcpy(outBytes, src, toCopy)
        }
        ctx.offset += toCopy
      } else {
        if ctx.strictRead {
          // Not enough data available: signal an I/O error to libpng
          png_error(pngPtr, "unexpected EOF")
        } else {
          // Lax mode: copy what we have and zero-fill the rest, warn
          if toCopy > 0 {
            ctx.data.withUnsafeBytes { bytes in
              let src = bytes.baseAddress!.advanced(by: ctx.offset)
              memcpy(outBytes, src, toCopy)
            }
            ctx.offset += toCopy
          }
          let remaining = Int(byteCount) - toCopy
          if remaining > 0 {
            memset(outBytes.advanced(by: toCopy), 0, remaining)
          }
          png_warning(pngPtr, "short read; padded with zeros")
        }
      }
    }

    // libpng uses setjmp for errors; call into safe C wrapper
    if swift_png_safe_read(pngPtr, infoPtr, readCallback, context.toOpaque()) == 0 {
      let cmsg = swift_png_get_last_error(pngPtr)
      let message = cmsg != nil ? String(cString: cmsg!) : "libpng decoding error"
      throw ImageLoadingError.pngError(code: -1, message: message)
    }

    // --- Read image info ---
    let width = png_get_image_width(pngPtr, infoPtr)
    let height = png_get_image_height(pngPtr, infoPtr)
    let colorType = png_get_color_type(pngPtr, infoPtr)
    let bitDepth = png_get_bit_depth(pngPtr, infoPtr)

    // --- Transform to RGBA8 ---
    if bitDepth == 16 { png_set_strip_16(pngPtr) }
    if colorType == PNG_COLOR_TYPE_PALETTE { png_set_palette_to_rgb(pngPtr) }
    if colorType == PNG_COLOR_TYPE_GRAY && bitDepth < 8 {
      png_set_expand_gray_1_2_4_to_8(pngPtr)
    }
    if png_get_valid(pngPtr, infoPtr, PNG_INFO_tRNS) != 0 { png_set_tRNS_to_alpha(pngPtr) }
    if colorType == PNG_COLOR_TYPE_RGB || colorType == PNG_COLOR_TYPE_GRAY
      || colorType == PNG_COLOR_TYPE_PALETTE
    {
      png_set_filler(pngPtr, 0xFF, PNG_FILLER_AFTER)
    }
    if colorType == PNG_COLOR_TYPE_GRAY || colorType == PNG_COLOR_TYPE_GRAY_ALPHA {
      png_set_gray_to_rgb(pngPtr)
    }
    let numPasses = png_set_interlace_handling(pngPtr)
    if swift_png_safe_read_update_info(pngPtr, infoPtr) == 0 {
      let cmsg = swift_png_get_last_error(pngPtr)
      let message =
        cmsg != nil ? String(cString: cmsg!) : "libpng decoding error during update_info"
      throw ImageLoadingError.pngError(
        code: -1, message: message)
    }

    // --- Allocate image buffer ---
    let rowBytes = Int(png_get_rowbytes(pngPtr, infoPtr))
    var rgba = [UInt8](repeating: 0, count: rowBytes * Int(height))

    var readError: ImageLoadingError? = nil
    rgba.withUnsafeMutableBytes { ptr in
      let rowPointers = (0..<Int(height)).map {
        ptr.baseAddress! + rowBytes * $0
      }

      let totalRowReads = Int(numPasses) * Int(height)
      let updateInterval = max(1, totalRowReads / 16)  // update ~16 times total
      var rowsRead = 0

      for _ in 0..<Int(numPasses) {
        for (i, row) in rowPointers.enumerated() {
          if swift_png_safe_read_row(pngPtr, row.assumingMemoryBound(to: UInt8.self), nil)
            == 0
          {
            let cmsg = swift_png_get_last_error(pngPtr)
            let message =
              cmsg != nil
              ? String(cString: cmsg!) : "libpng decoding error while reading rows"
            readError = ImageLoadingError.pngError(
              code: -1, message: message)
            break
          }

          rowsRead += 1
          // only call progress handler every N rows or on the last row
          if rowsRead % updateInterval == 0 || rowsRead == totalRowReads || i == Int(height) - 1 {
            progressHandler?(Double(rowsRead) / Double(totalRowReads))
          }
        }
        if readError != nil {
          break
        }
      }
    }

    if let error = readError {
      throw error
    }

    if swift_png_safe_read_end(pngPtr, infoPtr) == 0 {
      let cmsg = swift_png_get_last_error(pngPtr)
      let message =
        cmsg != nil ? String(cString: cmsg!) : "libpng decoding error during read_end"
      throw ImageLoadingError.pngError(
        code: -1, message: message)
    }

    return Self(
      width: Int(width),
      height: Int(height),
      bytes: rgba
    )
  }
}

// Holds the Swift warning handler closure across C callbacks
private final class PNGWarningBox {
  let handler: (String) -> Void
  init(_ handler: @escaping (String) -> Void) { self.handler = handler }
}

// C-callback trampoline that forwards libpng warnings to Swift
private func pngWarningTrampoline(
  _ ctx: UnsafeMutableRawPointer?, _ msg: UnsafePointer<CChar>?
) {
  guard let ctx else { return }
  let box = Unmanaged<PNGWarningBox>.fromOpaque(ctx).takeUnretainedValue()
  if let msg {
    box.handler(String(cString: msg))
  }
}
