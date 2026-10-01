## Command-line arguments for converting a single CSV or PNG file.
import std/[os, strutils]

type CliInput* = object
  inputPath*: string
  outputPath*: string
  showHelp*: bool

const usage* = """Usage: csv2png [input.csv|input.png] [-o output]

Convert CSV bytes to RGB pixels in a PNG, or restore the CSV
from a PNG created by this tool. Windows only.
With no arguments, select one or more files in a native file picker.
The default output is beside the input, with the opposite extension.
Existing output files are never overwritten.
CSV limit: 512 MiB. PNG input limit: 514 MiB. See README for memory usage.

Options:
  -o, --output PATH   Set the destination file
  -h, --help          Show this help
"""

proc parseArgs*(args: openArray[string]): CliInput =
  ## Parse input, output, and help arguments, rejecting invalid options.
  result = CliInput()
  var i = 0
  while i < args.len:
    let arg = args[i]
    case arg
    of "-h", "--help":
      result.showHelp = true
      return
    of "-o", "--output":
      inc i
      if i >= args.len or args[i].len == 0:
        raise newException(ValueError, "Missing output path")
      if result.outputPath.len != 0:
        raise newException(ValueError, "Output specified more than once")
      result.outputPath = args[i]
    else:
      if arg.len == 0:
        raise newException(ValueError, "Missing input file")
      if arg.startsWith("-"):
        raise newException(ValueError, "Unknown option: " & arg)
      if result.inputPath.len != 0:
        raise newException(ValueError, "Expected exactly one input file")
      result.inputPath = arg
    inc i

proc defaultOutput*(inputPath: string): string =
  ## Derive the output path by swapping a CSV or PNG extension.
  let ext = splitFile(inputPath).ext.toLowerAscii()
  case ext
  of ".csv": changeFileExt(inputPath, ".png")
  of ".png": changeFileExt(inputPath, ".csv")
  else: raise newException(ValueError, "Expected a .csv or .png input file")
