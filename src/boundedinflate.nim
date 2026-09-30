## Fixed-output zlib decoder using zippy's bit reader and RFC 1951 tables.
## No native compression library or growable decompression buffer is used.
import zippy/[bitstreams, internal, adler32]

type Huffman = object
  counts: array[16, int]
  symbols: array[288, int]

proc invalid() {.noreturn.} =
  ## Reject invalid compressed input or an unexpected decompressed size.
  raise newException(ValueError, "Invalid compressed data or decompressed size")

proc bits(reader: var BitStreamReader, count: int): int =
  ## Read up to 16 bits while rejecting unsafe reader state and truncation.
  if count < 0 or count > 16 or reader.bitsBuffered < 0 or
      reader.bitsBuffered > 63 or reader.pos < 2 or reader.pos > reader.len:
    invalid()
  # zippy's refill uses an unchecked pointer and shifts by bitsBuffered. Only
  # refill below count (at most 16), never with a negative/full bit buffer.
  if reader.bitsBuffered < count:
    reader.fillBitBuffer()
  # readBits itself permits underflow. Reject truncation before consuming bits
  # so no negative state can reach another refill or byte-alignment operation.
  if reader.bitsBuffered < count:
    invalid()
  result = int(reader.readBits(count, false))

proc huffman(lengths: openArray[uint8], codeTree = false): Huffman =
  ## Build a canonical Huffman tree after validating its code lengths.
  result = Huffman()
  for length in lengths:
    if length > 15: invalid()
    inc result.counts[length]
  var remaining = 1
  for length in 1 .. 15:
    remaining = remaining * 2 - result.counts[length]
    if remaining < 0: invalid()
  # RFC 1951 permits a one-bit single-symbol literal/distance tree and an
  # empty distance tree for literal-only blocks, but not an incomplete code tree.
  let used = lengths.len - result.counts[0]
  if remaining != 0 and (codeTree or
      (used != 0 and not (used == 1 and result.counts[1] == 1))):
    invalid()
  var offsets = default(array[16, int])
  for length in 1 .. 14:
    offsets[length + 1] = offsets[length] + result.counts[length]
  for symbol, length in lengths:
    if length != 0:
      result.symbols[offsets[length]] = symbol
      inc offsets[length]

proc symbol(reader: var BitStreamReader, tree: Huffman): int =
  ## Decode one Huffman symbol, rejecting missing or truncated codes.
  var code, first, index = 0
  for length in 1 .. 15:
    code = (code shl 1) or reader.bits(1)
    let count = tree.counts[length]
    if code >= first and code - first < count:
      return tree.symbols[index + code - first]
    index += count
    first = (first + count) shl 1
  invalid()

proc readTrees(reader: var BitStreamReader, kind: int,
               literals, distances: var Huffman) =
  ## Build fixed trees or read and validate dynamic trees for a Huffman block.
  if kind == 1:
    literals = huffman(fixedLitLenCodeLengths)
    var distanceLengths = default(array[32, uint8])
    for length in distanceLengths.mitems: length = 5
    distances = huffman(distanceLengths)
  else:
    let literalCount = reader.bits(5) + 257
    let distanceCount = reader.bits(5) + 1
    let codeCount = reader.bits(4) + 4
    if literalCount > 286: invalid()
    var codeLengths = default(array[19, uint8])
    for i in 0 ..< codeCount:
      codeLengths[clclOrder[i]] = uint8(reader.bits(3))
    let codes = huffman(codeLengths, codeTree = true)
    var lengths = default(array[318, uint8])
    let total = literalCount + distanceCount
    var position = 0
    while position < total:
      let value = reader.symbol(codes)
      if value <= 15:
        lengths[position] = uint8(value)
        inc position
      else:
        var repeated: uint8 = 0
        var count: int
        case value
        of 16:
          if position == 0: invalid()
          repeated = lengths[position - 1]
          count = reader.bits(2) + 3
        of 17: count = reader.bits(3) + 3
        of 18: count = reader.bits(7) + 11
        else: invalid()
        if count > total - position: invalid()
        for i in position ..< position + count:
          lengths[i] = repeated
        position += count
    if lengths[256] == 0: invalid()
    literals = huffman(lengths.toOpenArray(0, literalCount - 1))
    distances = huffman(lengths.toOpenArray(literalCount, total - 1))

proc decodeStoredBlock(reader: var BitStreamReader, data: string,
                       decoded: var string, output: var int) =
  ## Copy a stored block after validating its length and input/output bounds.
  reader.skipRemainingBitsInCurrentByte()
  let length = reader.bits(16)
  if (length xor reader.bits(16)) != 65535 or length > decoded.len - output:
    invalid()
  let position = reader.pos - reader.bitsBuffered div 8
  if length > reader.len - position: invalid()
  if length > 0:
    copyMem(addr decoded[output], unsafeAddr data[position], length)
  reader.pos = position + length
  reader.bitsBuffered = 0
  reader.bitBuffer = 0
  output += length

proc decodeHuffmanBlock(reader: var BitStreamReader, literals, distances: Huffman,
                        windowSize: int, decoded: var string, output: var int) =
  ## Decode literals and bounded overlapping matches through the end-of-block symbol.
  while true:
    let value = reader.symbol(literals)
    if value < 256:
      if output >= decoded.len: invalid()
      decoded[output] = char(value)
      inc output
    elif value == 256:
      break
    else:
      let index = value - 257
      if index >= baseLengths.len: invalid()
      let length = int(baseLengths[index]) + reader.bits(int(baseLengthsExtraBits[index]))
      let distanceIndex = reader.symbol(distances)
      if distanceIndex >= baseDistances.len: invalid()
      let distance = int(baseDistances[distanceIndex]) +
        reader.bits(int(baseDistanceExtraBits[distanceIndex]))
      if distance > output or distance > windowSize or length > decoded.len - output:
        invalid()
      # Forward byte copies intentionally support overlapping LZ77 matches.
      for i in 0 ..< length:
        decoded[output + i] = decoded[output + i - distance]
      output += length

proc boundedUncompress*(data: string, expectedSize: int): string =
  ## Decode exactly expectedSize bytes, rejecting trailing data and bad Adler-32.
  if expectedSize < 0 or data.len < 6: invalid()
  let cmf = ord(data[0])
  let flg = ord(data[1])
  if (cmf and 15) != 8 or (cmf shr 4) > 7 or
      (cmf * 256 + flg) mod 31 != 0 or (flg and 32) != 0:
    invalid()
  let windowSize = 1 shl ((cmf shr 4) + 8)
  var reader = BitStreamReader(
    src: cast[ptr UncheckedArray[uint8]](data.cstring),
    len: data.len - 4, pos: 2)
  result = newString(expectedSize)
  var output = 0
  var finalBlock = false
  while not finalBlock:
    finalBlock = reader.bits(1) != 0
    let kind = reader.bits(2)
    if kind == 0:
      decodeStoredBlock(reader, data, result, output)
    elif kind in {1, 2}:
      var literals = Huffman()
      var distances = Huffman()
      readTrees(reader, kind, literals, distances)
      decodeHuffmanBlock(reader, literals, distances, windowSize, result, output)
    else:
      invalid()
  let consumed = reader.pos - reader.bitsBuffered div 8
  if output != expectedSize or consumed != data.len - 4:
    raise newException(ValueError, "Decompressed size " & $output & "/" & $expectedSize &
      "; compressed bytes consumed " & $consumed & "/" & $(data.len - 4))
  var checksum = 0'u32
  for i in data.len - 4 ..< data.len:
    checksum = (checksum shl 8) or uint32(ord(data[i]))
  if adler32(result) != checksum: invalid()
