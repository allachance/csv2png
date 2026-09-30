## Convert files using the in-memory codec and publish output without overwriting.

import std/[os, strutils, tempfiles, winlean]
import ./codec

proc prepareStagedFile(file: File, data, outputPath: string) =
  ## Prepare staged output for publication by writing all bytes and flushing to disk.
  let handle = Handle(getOsFileHandle(file))
  var bytesWritten: int32 = 0
  if winlean.writeFile(handle, data.cstring, int32(data.len), addr bytesWritten, nil) == 0:
    raiseOSError(osLastError(), outputPath)
  if int(bytesWritten) != data.len:
    raise newException(IOError, "Incomplete write: " & outputPath)
  if flushFileBuffers(handle) == 0:
    raiseOSError(osLastError(), outputPath)

proc publishStagedFile(stagedPath, outputPath: string) =
  ## Move a closed staged file to its destination without replacing anything.
  # Zero flags refuse replacement even if a concurrent process created the target.
  if moveFileExW(newWideCString(stagedPath), newWideCString(outputPath), 0) == 0:
    raiseOSError(osLastError(), outputPath)

proc writeOutputWithoutOverwrite(outputPath, data: string) =
  ## Manage the staged output lifecycle through publication and cleanup.
  # Stage beside the destination so publication stays on the same filesystem.
  let outputDir = parentDir(absolutePath(outputPath))
  let temp = createTempFile(".csv2png-", ".tmp", outputDir)
  try:
    try:
      prepareStagedFile(temp.cfile, data, outputPath)
    finally:
      temp.cfile.close()
    publishStagedFile(temp.path, outputPath)
  finally:
    removeFile(temp.path)

proc validateConversionPaths(inputPath, outputPath: string) =
  ## Reject a missing source or an existing destination before conversion.
  if not fileExists(inputPath):
    raise newException(IOError, "Input file not found: " & inputPath)
  if fileExists(outputPath):
    raise newException(IOError, "Output file already exists: " & outputPath)

proc readBoundedFile(inputPath: string, limit: int): string =
  ## Check before allocation and enforce the limit again if the file grows.
  let file = open(inputPath, fmRead)
  defer: file.close()
  if getFileSize(file) > int64(limit):
    raise newException(ValueError, "Input file exceeds the size limit: " & inputPath)
  result = ""
  var buffer = default(array[64 * 1024, char])
  while true:
    let count = file.readBuffer(addr buffer[0], min(buffer.len, limit - result.len + 1))
    if count == 0:
      break
    if count > limit - result.len:
      raise newException(ValueError, "Input file exceeds the size limit: " & inputPath)
    let offset = result.len
    result.setLen(offset + count)
    copyMem(addr result[offset], addr buffer[0], count)

proc readConvertedData(inputPath: string): string =
  ## Bound input reads before selecting the in-memory codec.
  case splitFile(inputPath).ext.toLowerAscii()
  of ".csv": encodeCsv(readBoundedFile(inputPath, maxCsvSize))
  of ".png": decodeCsv(readBoundedFile(inputPath, maxPngSize))
  else: raise newException(ValueError, "Expected a .csv or .png input file")

proc convertFile*(inputPath, outputPath: string) =
  ## Coordinate file conversion without replacing an existing destination.
  validateConversionPaths(inputPath, outputPath)
  let outputData = readConvertedData(inputPath)
  writeOutputWithoutOverwrite(outputPath, outputData)
