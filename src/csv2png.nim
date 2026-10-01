import std/[os, strutils]
import ./cli
import ./conversion
import ./filedialog
import ./desktopui

type ConversionReporter* = proc(message: string, isError: bool) {.closure, gcsafe.}

proc reportConversion(reporter: ConversionReporter, message: string, isError: bool) =
  if reporter != nil:
    reporter(message, isError)
  elif isError:
    stderr.writeLine(message)
  else:
    echo message

proc resolveInputPaths(options: CliInput): seq[string] =
  ## Resolve the command-line input or open the file picker when no arguments exist.
  if options.inputPath.len != 0:
    return @[options.inputPath]

  if paramCount() != 0:
    raise newException(ValueError, "Missing input file")
  # With no arguments, cancellation returns an empty sequence.
  return openInputFileDialog()

proc convertInputFiles*(inputPaths: openArray[string], outputPath = "",
    reporter: ConversionReporter = nil): bool =
  ## Convert each input independently and report whether every conversion succeeded.
  if inputPaths.len > 1 and outputPath.len != 0:
    raise newException(ValueError, "An explicit output path requires exactly one input file")
  result = true
  for inputPath in inputPaths:
    try:
      let destination =
        if outputPath.len != 0: outputPath
        else: defaultOutput(inputPath)
      convertFile(inputPath, destination)
      reportConversion(reporter, "Created: " & destination, false)
    except CatchableError as e:
      reportConversion(reporter, "csv2png: " & inputPath & ": " & e.msg, true)
      result = false

proc runApplication(desktopMode: bool): bool =
  ## Handle help or cancellation, otherwise convert the selected files.
  let options = parseArgs(commandLineParams())
  if options.showHelp:
    echo usage
    return true

  let inputPaths = resolveInputPaths(options)
  if not desktopMode:
    return convertInputFiles(inputPaths, options.outputPath)
  if inputPaths.len == 0:
    return true

  var messages: seq[string] = @[]
  result = convertInputFiles(inputPaths, options.outputPath,
    proc(message: string, isError: bool) = messages.add(message))
  showResultDialog(messages.join("\n\n"), failed = not result)

proc main() =
  ## Run the application and report recoverable errors with a nonzero exit code.
  let desktopMode = paramCount() == 0 and detachOwnedConsole()
  try:
    if not runApplication(desktopMode):
      quit(1)
  except CatchableError as e:
    if desktopMode:
      showResultDialog("csv2png: " & e.msg, failed = true)
    else:
      stderr.writeLine("csv2png: " & e.msg)
    quit(1)

when isMainModule:
  main()
