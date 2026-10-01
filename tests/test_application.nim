import std/[os, strutils, unittest]
import ../src/[codec, csv2png]

proc runTests() =
  suite "application reporting":
    test "report successful conversions with Unicode paths":
      let root = getTempDir() / ("csv2png-report-" & $getCurrentProcessId())
      createDir(root)
      try:
        let input = root / "entr\xc3\xa9e.csv"
        writeFile(input, "a,b\r\n1,2\r\n")
        var messages: seq[string] = @[]
        var errors: seq[bool] = @[]
        check convertInputFiles([input], reporter = proc(message: string, isError: bool) =
          messages.add(message)
          errors.add(isError))
        check messages == @["Created: " & changeFileExt(input, ".png")]
        check errors == @[false]
        check decodeCsv(readFile(changeFileExt(input, ".png"))) == readFile(input)
      finally:
        removeDir(root)

    test "report failures and continue processing remaining files":
      let root = getTempDir() / ("csv2png-report-errors-" & $getCurrentProcessId())
      createDir(root)
      try:
        let
          blocked = root / "blocked.csv"
          valid = root / "valid.csv"
          missing = root / "missing.csv"
        writeFile(blocked, "blocked")
        writeFile(changeFileExt(blocked, ".png"), "existing output")
        writeFile(valid, "valid")
        var messages: seq[string] = @[]
        var errors: seq[bool] = @[]
        check not convertInputFiles([blocked, missing, valid],
          reporter = proc(message: string, isError: bool) =
            messages.add(message)
            errors.add(isError))
        check errors == @[true, true, false]
        check messages.len == 3
        check messages[0].startsWith("csv2png: " & blocked & ": ")
        check messages[1].startsWith("csv2png: " & missing & ": ")
        check messages[2] == "Created: " & changeFileExt(valid, ".png")
        check readFile(changeFileExt(blocked, ".png")) == "existing output"
        check decodeCsv(readFile(changeFileExt(valid, ".png"))) == "valid"
      finally:
        removeDir(root)

    test "cancellation has no conversion reports":
      var calls = 0
      check convertInputFiles([], reporter = proc(message: string, isError: bool) =
        inc calls)
      check calls == 0

    test "explicit output still requires a single input":
      expect ValueError:
        discard convertInputFiles(["first.csv", "second.csv"], "output.png")

runTests()
