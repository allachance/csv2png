import std/os
import ./cli
import ./conversion
import ./filedialog

proc resolveInputPath(options: CliInput): string =
  ## Resolve the command-line input or open the file picker when no arguments exist.
  if options.inputPath.len != 0:
    return options.inputPath

  if paramCount() != 0:
    raise newException(ValueError, "Missing input file")
  # With no arguments, cancellation returns an empty path.
  return openInputFileDialog()

proc runApplication() =
  ## Handle help or cancellation, otherwise convert the selected file.
  let options = parseArgs(commandLineParams())
  if options.showHelp:
    echo usage
    return

  let inputPath = resolveInputPath(options)
  if inputPath.len == 0:
    return # file picker cancelled

  let outputPath =
    if options.outputPath.len != 0: options.outputPath
    else: defaultOutput(inputPath)
  convertFile(inputPath, outputPath)
  echo "Created: ", outputPath

proc main() =
  ## Run the application and report recoverable errors with a nonzero exit code.
  try:
    runApplication()
  except CatchableError as e:
    stderr.writeLine("csv2png: " & e.msg)
    quit(1)

when isMainModule:
  main()
