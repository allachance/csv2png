import std/[unittest, os, strutils]
import ../src/[cli, codec, conversion, boundedinflate]
import zippy, zippy/crc

const
  pngSignature = "\x89PNG\r\n\x1a\n"
  chunkHeaderSize = 8 # length and type
  chunkOverhead = 12 # length, type, and CRC
  headerDataLength = 13

  headerOffset = pngSignature.len
  metadataOffset = headerOffset + chunkOverhead + headerDataLength
  metadataDataOffset = metadataOffset + chunkHeaderSize

proc chunkBytes(png: string, offset, dataLength: int): string =
  ## Extract a complete PNG chunk from a test fixture.
  png[offset ..< offset + chunkOverhead + dataLength]

proc updateChunkChecksum(png: var string, offset, dataLength: int) =
  ## Recalculate a fixture chunk's CRC after changing its type or data.
  # PNG CRC covers the chunk type and data, but not the length.
  let typeOffset = offset + 4
  let checksumOffset = offset + chunkHeaderSize + dataLength
  let checksum = crc32(unsafeAddr png[typeOffset], dataLength + 4)
  for i in 0 .. 3:
    png[checksumOffset + i] = char((checksum shr (24 - i * 8)) and 255)

proc append32(bytes: var string, value: int) =
  ## Append a fixture integer in big-endian 32-bit byte order.
  for shift in [24, 16, 8, 0]:
    bytes.add char((value shr shift) and 255)

proc appendTestChunk(png: var string, kind, data: string) =
  ## Append a fixture PNG chunk with a valid length and checksum.
  let offset = png.len
  png.append32(data.len)
  png.add kind & data & "\0\0\0\0"
  updateChunkChecksum(png, offset, data.len)

proc deflateFixture(fields: openArray[tuple[value, count: int]]): string =
  ## Pack RFC 1951 fields least-significant bit first, with an empty zlib checksum.
  result = "\x78\x01"
  var buffer = 0
  var buffered = 0
  for field in fields:
    for i in 0 ..< field.count:
      buffer = buffer or (((field.value shr i) and 1) shl buffered)
      inc buffered
      if buffered == 8:
        result.add char(buffer)
        buffer = 0
        buffered = 0
  if buffered > 0: result.add char(buffer)
  result.add "\0\0\0\x01"

proc rgbFixture(size: int, pixels: string): string =
  ## Build a two-pixel RGB fixture with the supplied byte count and scanlines.
  result = pngSignature
  result.appendTestChunk("IHDR", "\0\0\0\x02\0\0\0\x01\x08\x02\0\0\0")
  var metadata = "RGB1"
  metadata.append32(size)
  result.appendTestChunk("cdVd", metadata)
  result.appendTestChunk("IDAT", compress(pixels, dataFormat = dfZlib))
  result.appendTestChunk("IEND", "")

suite "csv2png":
  test "bounded inflater handles stored fixed and dynamic DEFLATE":
    # Independently specified fixed-Huffman and stored streams for "hello".
    for stream in ["\x78\x9c\xcb\x48\xcd\xc9\xc9\x07\x00\x06\x2c\x02\x15",
                   "\x78\x01\x01\x05\x00\xfa\xffhello\x06\x2c\x02\x15"]:
      check boundedUncompress(stream, 5) == "hello"
      for size in [0, 4, 6]:
        expect ValueError:
          discard boundedUncompress(stream, size)
    var bytes = ""
    for i in 0 .. 255: bytes.add char(i)
    for input in ["", "x", repeat("a", 70000), repeat(bytes, 300),
                  repeat("different words, with repeated overlapping matches\n", 2000)]:
      for level in 0 .. 9:
        let stream = compress(input, level = level, dataFormat = dfZlib)
        checkpoint "input length " & $input.len & ", compression level " & $level
        check boundedUncompress(stream, input.len) == input
        expect ValueError:
          discard boundedUncompress(stream, input.len + 1)
        if input.len > 0:
          expect ValueError:
            discard boundedUncompress(stream, input.len - 1)

  test "bounded inflater aligns stored blocks after non-byte-aligned Huffman blocks":
    # Empty nonfinal fixed block consumes 10 bits; the stored header then ends
    # at bit 13 and must discard three padding bits despite input prefetching.
    var fields = @[(0, 1), (1, 2), (0, 7), (1, 1), (0, 2), (7, 3),
                   (5, 16), (65530, 16)]
    for value in "hello": fields.add (ord(value), 8)
    let packed = deflateFixture(fields)
    let stream = packed[0 ..< packed.len - 4] & "\x06\x2c\x02\x15"
    check boundedUncompress(stream, 5) == "hello"
    # Reverse the block order to cover resetting the prefetched bit buffer.
    let reversed = "\x78\x01\x00\x05\x00\xfa\xffhello\x03\x00\x06\x2c\x02\x15"
    check boundedUncompress(reversed, 5) == "hello"
    for valid in [stream, reversed]:
      for length in 0 ..< valid.len - 4:
        let truncated = valid[0 ..< length] & valid[valid.len - 4 ..< valid.len]
        expect ValueError:
          discard boundedUncompress(truncated, 5)

  test "bounded inflater rejects bit and stored payload truncation before checksums":
    # Preserve Adler-32 so these exercise DEFLATE EOF rather than a short trailer.
    for deflate in ["", "\x01", "\x01\0", "\x01\0\0", "\x01\0\0\xff",
                    "\x01\x01\0\xfe\xff", "\x03", "\x05", "\x05\0"]:
      expect ValueError:
        discard boundedUncompress("\x78\x01" & deflate & "\0\0\0\x01", 0)
    # Zero-length stored blocks and sub-byte final padding are valid.
    check boundedUncompress("\x78\x01\x01\0\0\xff\xff\0\0\0\x01", 0) == ""
    check boundedUncompress("\x78\x01\x03\0\0\0\0\x01", 0) == ""

  test "bounded inflater rejects invalid dynamic trees and back references":
    # Dynamic header, with the first four code lengths in order 16, 17, 18, 0.
    let header = @[(1, 1), (2, 2), (0, 5), (0, 5), (0, 4)]
    for fields in [
      # Oversubscribed code-length tree.
      header & @[(1, 3), (1, 3), (1, 3), (1, 3)],
      # Repeat previous length before there is a previous length.
      header & @[(1, 3), (0, 3), (0, 3), (1, 3), (1, 1)],
      # Repeat zero overruns the combined literal and distance lengths.
      header & @[(0, 3), (0, 3), (1, 3), (1, 3), (1, 1), (127, 7), (1, 1), (127, 7)],
      # All lengths zero: no end-of-block symbol.
      header & @[(0, 3), (0, 3), (1, 3), (1, 3), (1, 1), (127, 7), (1, 1), (109, 7)],
      # Fixed length symbol 257 followed by distance 1, before any output.
      @[(1, 1), (1, 2), (64, 7), (0, 5)],
      # Reserved fixed literal/length symbol 286.
      @[(1, 1), (1, 2), (99, 8)]]:
      expect ValueError:
        discard boundedUncompress(deflateFixture(fields), 3)

  test "bounded inflater rejects truncation checksums headers and trailing data":
    let stream = compress("hello hello hello", dataFormat = dfZlib)
    for length in 0 ..< stream.len:
      expect ValueError:
        discard boundedUncompress(stream[0 ..< length], 17)
    for offset in [0, 1, stream.len - 1]:
      var damaged = stream
      damaged[offset] = char(ord(damaged[offset]) xor 1)
      expect ValueError:
        discard boundedUncompress(damaged, 17)
    for suffix in ["x", compress("", dataFormat = dfZlib)]:
      expect ValueError:
        discard boundedUncompress(stream & suffix, 17)
    # Reserved block type, bad stored length complement, missing dynamic tree.
    for deflate in ["\x07", "\x01\x01\x00\x00\x00x", "\x05\x00\x00"]:
      expect ValueError:
        discard boundedUncompress("\x78\x01" & deflate & "\0\0\0\x01", 0)
  test "actual opaque RGB channels and row-major padding":
    let png = encodeCsv("\xff\0\x80\x10\x20\x30\x40")
    check png[headerOffset + chunkHeaderSize ..< headerOffset + chunkHeaderSize + 13] ==
      "\0\0\0\x02\0\0\0\x02\x08\x02\0\0\0"
    let imageOffset = metadataOffset + chunkOverhead + 8
    let dataOffset = imageOffset + chunkHeaderSize
    let dataLength = png.len - chunkOverhead - dataOffset - 4
    check uncompress(png[dataOffset ..< dataOffset + dataLength], dfZlib) ==
      "\0\xff\0\x80\x10\x20\x30\0\x40\0\0\0\0\0"

  test "all byte values, channel remainders and row boundaries":
    var bytes = ""
    for i in 0 .. 255:
      bytes.add char(i)
    for size in 0 .. 256:
      check decodeCsv(encodeCsv(bytes[0 ..< size])) == bytes[0 ..< size]
    check decodeCsv(encodeCsv("abc\0\0")) == "abc\0\0"

  test "reject invalid decompressed scanlines and padding":
    for pixels in ["\0abcd\0", "\x05abcd\0\0", "\0abcd\0\x01",
                   "\0abcd\0\0extra"]:
      expect ValueError:
        discard decodeCsv(rgbFixture(4, pixels))
    check decodeCsv(rgbFixture(4, "\0abcd\0\0")) == "abcd"

  test "bounded RGB decompression rejects expansion and trailing streams":
    expect ValueError:
      discard decodeCsv(rgbFixture(1, repeat("\0", 1024 * 1024)))
    let png = rgbFixture(4, "\0abcd\0\0")
    let imageOffset = metadataOffset + chunkOverhead + 8
    var trailing = png[0 ..< imageOffset]
    trailing.appendTestChunk("IDAT", compress("\0abcd\0\0", dataFormat = dfZlib) & "extra")
    trailing.appendTestChunk("IEND", "")
    expect ValueError:
      discard decodeCsv(trailing)

  test "filters reconstruct left above and Paeth neighbors":
    let csv = "abcdefABCDEF"
    for filter in 0 .. 4:
      var pixels = ""
      for row in 0 .. 1:
        pixels.add char(filter)
        for channel in 0 .. 5:
          let i = row * 6 + channel
          let a = if channel >= 3: ord(csv[i - 3]) else: 0
          let b = if row > 0: ord(csv[i - 6]) else: 0
          let c = if row > 0 and channel >= 3: ord(csv[i - 9]) else: 0
          var predictor = 0
          case filter
          of 1: predictor = a
          of 2: predictor = b
          of 3: predictor = (a + b) div 2
          of 4:
            let p = a + b - c
            if abs(p - a) <= abs(p - b) and abs(p - a) <= abs(p - c): predictor = a
            elif abs(p - b) <= abs(p - c): predictor = b
            else: predictor = c
          else: discard
          pixels.add char((ord(csv[i]) - predictor) and 255)
      var png = pngSignature
      png.appendTestChunk("IHDR", "\0\0\0\x02\0\0\0\x02\x08\x02\0\0\0")
      png.appendTestChunk("tEXt", "key\0value")
      var metadata = "RGB1"
      metadata.append32(csv.len)
      png.appendTestChunk("cdVd", metadata)
      png.appendTestChunk("tEXt", "other\0value")
      let compressed = compress(pixels, dataFormat = dfZlib)
      png.appendTestChunk("IDAT", compressed[0 ..< 3])
      png.appendTestChunk("IDAT", "")
      png.appendTestChunk("IDAT", compressed[3 ..< compressed.len])
      png.appendTestChunk("tEXt", "last\0value")
      png.appendTestChunk("IEND", "")
      check decodeCsv(png) == csv

  test "reject interrupted IDAT unknown critical and damaged ancillary chunks":
    let original = rgbFixture(4, "\0abcd\0\0")
    let imageOffset = metadataOffset + chunkOverhead + 8
    let compressed = compress("\0abcd\0\0", dataFormat = dfZlib)
    for kind in ["tEXt", "ABCD", "teXt", "t1Xt"]:
      var png = original[0 ..< imageOffset]
      png.appendTestChunk("IDAT", compressed[0 ..< 3])
      png.appendTestChunk(kind, "key\0value")
      png.appendTestChunk("IDAT", compressed[3 ..< compressed.len])
      png.appendTestChunk("IEND", "")
      expect ValueError:
        discard decodeCsv(png)
    var damaged = original[0 ..< imageOffset]
    damaged.appendTestChunk("tEXt", "key\0value")
    damaged[damaged.len - 1] = char(ord(damaged[^1]) xor 1)
    damaged.add original[imageOffset ..< original.len]
    expect ValueError:
      discard decodeCsv(damaged)

  test "alternative dimensions have bounded sufficient capacity":
    check decodeCsv(rgbFixture(1, "\0a\0\0\0\0\0")) == "a"
    expect ValueError:
      discard decodeCsv(rgbFixture(7, "\0abcdef"))
    var png = rgbFixture(1, "\0a\0\0\0\0\0")
    for i in 0 .. 7:
      png[headerOffset + chunkHeaderSize + i] = '\xff'
    updateChunkChecksum(png, headerOffset, headerDataLength)
    expect ValueError:
      discard decodeCsv(png)

  test "reject unsupported transparent DEFLATE containers":
    for csv in ["", "a,b\r\n\x00\xff"]:
      var png = pngSignature
      png.appendTestChunk("IHDR", "\0\0\0\x01\0\0\0\x01\x08\x06\0\0\0")
      var payload = ""
      payload.append32(csv.len)
      payload.add compress(csv, dataFormat = dfZlib)
      png.appendTestChunk("cdVd", payload)
      png.appendTestChunk("IDAT", "\x78\x01\x01\x05\x00\xfa\xff\x00\x00\x00\x00\x00\x00\x05\x00\x01")
      png.appendTestChunk("IEND", "")
      expect ValueError:
        discard decodeCsv(png)

  test "preserve CSV bytes including empty files and Unicode":
    for csv in ["", "a,b\r\n1,\"x,y\"\r\n", "\xef\xbb\xbfna\xc3\xafve,\x00\n"]:
      let png = encodeCsv(csv)
      check png.startsWith(pngSignature)
      check "cdVd" in png
      check decodeCsv(png) == csv

  test "reject unrelated or damaged PNGs":
    expect ValueError:
      discard decodeCsv("hello")
    let png = encodeCsv("x,y\n")
    var corrupt = png
    let csvSizeOffset = metadataDataOffset + 4
    corrupt[csvSizeOffset] = char(corrupt[csvSizeOffset].ord xor 1)
    expect ValueError:
      discard decodeCsv(corrupt)
    for length in 0 ..< png.len:
      expect ValueError:
        discard decodeCsv(png[0 ..< length])
    expect ValueError:
      discard decodeCsv(png & "trailing bytes")
    expect ValueError:
      discard decodeCsv(pngSignature & "\xff\xff\xff\xff" &
                        png[headerOffset + 4 ..< png.len])
    # Old Zstandard containers use a different tag and cannot be restored.
    expect ValueError:
      discard decodeCsv(png.replace("cdVd", "csVd"))

  test "reject invalid structure and payloads with valid PNG checksums":
    let png = encodeCsv("x,y\n")
    let endingOffset = png.len - chunkOverhead
    let metadataDataLength = 8
    let imageOffset = metadataOffset + chunkOverhead + metadataDataLength
    let imageDataLength = endingOffset - imageOffset - chunkOverhead
    let header = chunkBytes(png, headerOffset, headerDataLength)
    let metadata = chunkBytes(png, metadataOffset, metadataDataLength)
    let image = chunkBytes(png, imageOffset, imageDataLength)
    let ending = chunkBytes(png, endingOffset, 0)
    for body in [header & image & metadata & ending,
                 header & metadata & metadata & image & ending,
                 header & metadata & ending,
                 header & image & ending]:
      expect ValueError:
        discard decodeCsv(pngSignature & body)
    let widthOffset = headerOffset + chunkHeaderSize
    let csvSizeOffset = metadataDataOffset + 4
    let formatMarkerOffset = metadataDataOffset
    let imageDataOffset = imageOffset + chunkHeaderSize
    # Invalid width, oversized/mismatched CSV size, RGB format marker, and image data.
    for change in [(offset: widthOffset + 3, value: '\x03'),
                   (offset: csvSizeOffset, value: '\xff'),
                   (offset: csvSizeOffset + 3, value: '\x00'),
                   (offset: formatMarkerOffset, value: '\x00'),
                   (offset: imageDataOffset, value: '\x00')]:
      var invalid = png
      invalid[change.offset] = change.value
      for chunk in [(offset: headerOffset, dataLength: headerDataLength),
                    (offset: metadataOffset, dataLength: metadataDataLength),
                    (offset: imageOffset, dataLength: imageDataLength)]:
        updateChunkChecksum(invalid, chunk.offset, chunk.dataLength)
      expect ValueError:
        discard decodeCsv(invalid)

  test "CLI arguments and output names":
    check parseArgs(@["table.CSV", "-o", "saved.png"]).outputPath == "saved.png"
    check parseArgs(@["--help"]).showHelp
    check defaultOutput("dir/table.CSV") == "dir/table.png"
    check defaultOutput("table.PNG") == "table.csv"
    expect ValueError:
      discard parseArgs(@["first.csv", "second.csv"])
    expect ValueError:
      discard parseArgs(@["--output"])
    expect ValueError:
      discard defaultOutput("file.txt")

  test "reject empty positional input paths":
    for args in [@[""], @["", "another.csv"], @["another.csv", ""]]:
      expect ValueError:
        discard parseArgs(args)

  test "files round trip and cannot be overwritten":
    let root = getTempDir() / "csv2png-test-" & $getCurrentProcessId()
    createDir(root)
    try:
      let original = root / "entr\xc3\xa9e.csv"
      let png = root / "archive.png"
      let restored = root / "restored.csv"
      writeFile(original, "\xef\xbb\xbfa,b\r\n1,\"x,\x00y\"\r\n")
      convertFile(original, png)
      convertFile(png, restored)
      check readFile(restored) == readFile(original)
      expect IOError:
        convertFile(original, png)
      expect IOError:
        convertFile(original, original)
      let blocked = root / "directory.png"
      createDir(blocked)
      expect OSError:
        convertFile(original, blocked)
      check dirExists(blocked)
      for kind, path in walkDir(root):
        check not extractFilename(path).startsWith(".csv2png-")
      let damaged = root / "damaged.png"
      writeFile(damaged, "not a PNG")
      expect ValueError:
        convertFile(damaged, root / "missing.csv")
      check not fileExists(root / "missing.csv")
      check readFile(restored) == readFile(original)
      removeFile(png)
      removeFile(restored)
      writeFile(original, "")
      convertFile(original, png)
      convertFile(png, restored)
      check readFile(restored) == ""
      removeFile(png)
      removeFile(restored)
      var large = newString(150_000)
      for i in 0 ..< large.len:
        large[i] = char(i mod 256)
      writeFile(original, large)
      convertFile(original, png)
      convertFile(png, restored)
      check readFile(restored) == large
    finally:
      removeDir(root)
