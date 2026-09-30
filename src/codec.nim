## CSV bytes map directly to opaque RGB pixels, in row-major order.
## Encoder layout: PNG signature, IHDR, cdVd, IDAT, IEND. The RGB cdVd chunk
## contains "RGB1" and a big-endian byte count to distinguish zero padding.

import zippy, zippy/crc
import boundedinflate

const
  pngSignature = "\x89PNG\r\n\x1a\n"
  csvChunkType = "cdVd" # ancillary, private, reserved bit clear, safe to copy
  maxCsvSize* = 512 * 1024 * 1024
  maxPngSize* = maxCsvSize + 2 * 1024 * 1024
  uint32Bytes = 4
  chunkHeaderBytes = 8 # length followed by the four-byte chunk type
  chunkOverheadBytes = 12 # header plus checksum
  maxImageDataSize = maxCsvSize + 1024 * 1024 # allow scanline and compression overhead


type PngChunk = object
  dataOffset: int
  dataLength: int

proc appendUint32(bytes: var string, value: uint32) =
  ## Append a 32-bit unsigned integer in big-endian byte order.
  for shift in [24, 16, 8, 0]:
    bytes.add char((value shr shift) and 0xff'u32)

proc readUint32(bytes: string, offset: int): uint32 =
  ## Read a big-endian 32-bit unsigned integer at a caller-validated offset.
  result = 0'u32
  for i in 0 ..< uint32Bytes:
    result = (result shl 8) or uint32(bytes[offset + i].ord)

proc appendChunk(png: var string, kind, data: string) =
  ## Append a PNG chunk with its length, type, data, and checksum.
  png.appendUint32(uint32(data.len))
  let typeOffset = png.len
  png.add kind
  png.add data
  # PNG checksums cover the chunk type and data, but not the length.
  png.appendUint32(crc32(unsafeAddr png[typeOffset], png.len - typeOffset))

proc readValidatedChunk(png: string, offset: var int, expectedType: string): PngChunk =
  ## Validate the complete chunk before advancing to the next one.
  if png.len - offset < chunkOverheadBytes:
    raise newException(ValueError, "Incomplete PNG container")

  let dataLength = readUint32(png, offset)
  if uint64(dataLength) > uint64(png.len - offset - chunkOverheadBytes):
    raise newException(ValueError, "Truncated PNG chunk")

  result = PngChunk(dataOffset: offset + chunkHeaderBytes, dataLength: int(dataLength))
  let typeOffset = offset + uint32Bytes
  for i in typeOffset ..< result.dataOffset:
    if png[i] notin {'A'..'Z', 'a'..'z'}:
      raise newException(ValueError, "Invalid PNG chunk type")
  if png[typeOffset + 2] notin {'A'..'Z'}:
    raise newException(ValueError, "Invalid PNG chunk reserved bit")
  if png[typeOffset ..< result.dataOffset] != expectedType:
    raise newException(ValueError, "Expected PNG chunk: " & expectedType)

  let checksumOffset = result.dataOffset + result.dataLength
  let actualChecksum = crc32(unsafeAddr png[typeOffset], result.dataLength + uint32Bytes)
  if actualChecksum != readUint32(png, checksumOffset):
    raise newException(ValueError, "PNG checksum mismatch")
  offset = checksumOffset + uint32Bytes

proc validateCsvSize(csvSize: uint64) =
  ## Reject a CSV byte count that exceeds the 512 MiB limit.
  if csvSize > uint64(maxCsvSize):
    raise newException(ValueError, "CSV exceeds the 512 MiB limit")


proc imageDimensions(csvSize: int): tuple[width, height: int] =
  ## Choose near-square dimensions with enough RGB channels for the CSV bytes.
  let pixels = max(1, (csvSize + 2) div 3)
  var width = 1
  while width * width < pixels:
    inc width
  result = (width, (pixels + width - 1) div width)

proc rgbHeader(width, height: int): string =
  ## Construct an 8-bit RGB PNG header for the supplied dimensions.
  result = ""
  result.appendUint32(uint32(width))
  result.appendUint32(uint32(height))
  result.add "\x08\x02\x00\x00\x00"

proc rgbMetadata(csvSize: int): string =
  ## Construct RGB format metadata containing the original CSV byte count.
  result = "RGB1"
  result.appendUint32(uint32(csvSize))

proc encodeScanlines(csv: string, width, height: int): string =
  ## Map CSV bytes to unfiltered RGB rows with zero-filled unused channels.
  let stride = width * 3 + 1
  result = newString(stride * height)
  for i, value in csv:
    result[(i div (width * 3)) * stride + 1 + i mod (width * 3)] = value

proc encodeCsv*(csv: string): string =
  ## Coordinate construction of a PNG containing the CSV bytes as RGB pixels.
  validateCsvSize(uint64(csv.len))
  let (width, height) = imageDimensions(csv.len)
  result = pngSignature
  result.appendChunk("IHDR", rgbHeader(width, height))
  result.appendChunk(csvChunkType, rgbMetadata(csv.len))
  result.appendChunk("IDAT", compress(encodeScanlines(csv, width, height), dataFormat = dfZlib))
  result.appendChunk("IEND", "")

proc readRgbContainer(png: string, header: PngChunk,
                      offset: var int): tuple[csvSize, width, height: int, compressedImage: string] =
  ## Read compressed RGB image data after validating metadata and container structure.
  if header.dataLength != 13 or
      png[header.dataOffset + 8 ..< header.dataOffset + 13] != "\x08\x02\x00\x00\x00":
    raise newException(ValueError, "Unsupported RGB PNG header")
  while png.len - offset >= chunkOverheadBytes and
      png[offset + 4 ..< offset + 8] != csvChunkType:
    let kind = png[offset + 4 ..< offset + 8]
    if kind[0] notin {'a'..'z'}:
      raise newException(ValueError, "Expected RGB length metadata")
    discard readValidatedChunk(png, offset, kind)
  let metadata = readValidatedChunk(png, offset, csvChunkType)
  if metadata.dataLength != 8 or
      png[metadata.dataOffset ..< metadata.dataOffset + 4] != "RGB1":
    raise newException(ValueError, "Invalid RGB length metadata")
  let csvSize = readUint32(png, metadata.dataOffset + 4)
  validateCsvSize(uint64(csvSize))
  let width = uint64(readUint32(png, header.dataOffset))
  let height = uint64(readUint32(png, header.dataOffset + 4))
  if width == 0 or height == 0 or width > 0x7fffffff'u64 or
      height > 0x7fffffff'u64:
    raise newException(ValueError, "Invalid RGB dimensions")
  let capacity = width * height * 3
  if capacity < uint64(csvSize) or
      (width * 3 + 1) * height > uint64(maxImageDataSize):
    raise newException(ValueError, "Invalid or oversized RGB dimensions")
  var compressedImage = ""
  var seenImage = false
  var imageEnded = false
  while true:
    if png.len - offset < chunkOverheadBytes:
      raise newException(ValueError, "Incomplete PNG container")
    let kind = png[offset + 4 ..< offset + 8]
    let chunk = readValidatedChunk(png, offset, kind)
    if kind == "IDAT":
      if imageEnded or chunk.dataLength > maxImageDataSize - compressedImage.len:
        raise newException(ValueError, "Invalid RGB image data")
      seenImage = true
      compressedImage.add png[chunk.dataOffset ..< chunk.dataOffset + chunk.dataLength]
    elif kind == "IEND":
      if not seenImage or compressedImage.len == 0 or chunk.dataLength != 0 or offset != png.len:
        raise newException(ValueError, "Invalid PNG ending")
      break
    else:
      if kind == csvChunkType or kind[0] notin {'a'..'z'}:
        raise newException(ValueError, "Unsupported PNG chunk")
      if seenImage:
        imageEnded = true
  result = (int(csvSize), int(width), int(height), compressedImage)

proc paeth(a, b, c: int): int =
  ## Choose the nearest PNG Paeth neighbor, preserving the specified tie order.
  let p = a + b - c
  let pa = abs(p - a)
  let pb = abs(p - b)
  let pc = abs(p - c)
  if pa <= pb and pa <= pc: a
  elif pb <= pc: b
  else: c

proc unfilterScanlines(scanlines: var string, width, height: int) =
  ## Reconstruct RGB rows after validating their length and filter types.
  let stride = width * 3 + 1
  if scanlines.len != stride * height:
    raise newException(ValueError, "RGB image size mismatch")
  for row in 0 ..< height:
    let filter = ord(scanlines[row * stride])
    if filter > 4:
      raise newException(ValueError, "Unsupported PNG row filter")
    for channel in 0 ..< width * 3:
      let position = row * stride + 1 + channel
      let left = if channel >= 3: ord(scanlines[position - 3]) else: 0
      let above = if row > 0: ord(scanlines[position - stride]) else: 0
      let upperLeft = if row > 0 and channel >= 3:
                        ord(scanlines[position - stride - 3]) else: 0
      let predictor = case filter
        of 1: left
        of 2: above
        of 3: (left + above) div 2
        of 4: paeth(left, above, upperLeft)
        else: 0
      scanlines[position] = char((ord(scanlines[position]) + predictor) and 255)

proc validateRgbPadding(scanlines: string, csvSize, width, height: int) =
  ## Reject nonzero channels beyond the original CSV byte count.
  let channels = width * 3
  for i in csvSize ..< channels * height:
    if scanlines[(i div channels) * (channels + 1) + 1 + i mod channels] != '\0':
      raise newException(ValueError, "Nonzero RGB padding")

proc decodeScanlines(scanlines: string, csvSize, width: int): string =
  ## Extract CSV bytes from caller-validated unfiltered RGB rows.
  let stride = width * 3 + 1
  result = newString(csvSize)
  for i in 0 ..< csvSize:
    result[i] = scanlines[(i div (width * 3)) * stride + 1 + i mod (width * 3)]

proc decodeCsv*(png: string): string =
  ## Coordinate validated decoding of CSV bytes from RGB PNGs.
  if png.len > maxPngSize:
    raise newException(ValueError, "PNG exceeds the 514 MiB limit")
  if png.len < pngSignature.len or png[0 ..< pngSignature.len] != pngSignature:
    raise newException(ValueError, "Not a PNG file")
  var offset = pngSignature.len
  let header = readValidatedChunk(png, offset, "IHDR")
  let container = readRgbContainer(png, header, offset)
  var scanlines = boundedUncompress(container.compressedImage,
    (container.width * 3 + 1) * container.height)
  unfilterScanlines(scanlines, container.width, container.height)
  validateRgbPadding(scanlines, container.csvSize, container.width, container.height)
  result = decodeScanlines(scanlines, container.csvSize, container.width)

