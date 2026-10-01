## Console ownership and result dialogs for standalone Windows launches.
import std/winlean

proc getConsoleProcessList(processList: ptr uint32, processCount: uint32): uint32
  {.importc: "GetConsoleProcessList", dynlib: "kernel32", stdcall.}

proc freeConsole(): int32
  {.importc: "FreeConsole", dynlib: "kernel32", stdcall.}

proc messageBoxW(owner: Handle, text, caption: WideCString, flags: uint32): int32
  {.importc: "MessageBoxW", dynlib: "user32", stdcall.}

proc detachOwnedConsole*(): bool =
  ## Never detach a shared terminal: command-line callers need output and exit codes.
  var processId: uint32
  if getConsoleProcessList(addr processId, 1) == 1:
    return freeConsole() != 0
  return false

proc showResultDialog*(message: string, failed: bool) =
  let
    text = newWideCString(message)
    caption = newWideCString(if failed: "csv2png - Conversion failed" else: "csv2png")
    icon = if failed: 0x00000010'u32 else: 0x00000040'u32
  discard messageBoxW(0, text, caption, icon)
