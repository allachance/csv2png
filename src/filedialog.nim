## Native Windows file picker. Cancellation returns an empty sequence.

import std/[os, winlean]

const
  FileBufferChars = 32768
  OFN_ALLOWMULTISELECT = 0x00000200'u32
  OFN_EXPLORER = 0x00080000'u32
  OFN_PATHMUSTEXIST = 0x00000800'u32
  OFN_FILEMUSTEXIST = 0x00001000'u32

# Match the Win32 OPENFILENAMEW layout, including fields we leave zeroed.
type OPENFILENAMEW {.pure.} = object
  lStructSize: uint32
  hwndOwner: Handle
  hInstance: Handle
  lpstrFilter: WideCString
  lpstrCustomFilter: WideCString
  nMaxCustFilter: uint32
  nFilterIndex: uint32
  lpstrFile: WideCString
  nMaxFile: uint32
  lpstrFileTitle: WideCString
  nMaxFileTitle: uint32
  lpstrInitialDir: WideCString
  lpstrTitle: WideCString
  flags: uint32
  nFileOffset: uint16
  nFileExtension: uint16
  lpstrDefExt: WideCString
  lCustData: int
  lpfnHook: pointer
  lpTemplateName: WideCString
  pvReserved: pointer
  dwReserved: uint32
  flagsEx: uint32

proc getOpenFileNameW(p: ptr OPENFILENAMEW): int32
  {.importc: "GetOpenFileNameW", dynlib: "comdlg32", stdcall.}
  ## Display the Windows open-file dialog using the supplied configuration.

proc commDlgExtendedError(): uint32
  {.importc: "CommDlgExtendedError", dynlib: "comdlg32", stdcall.}
  ## Return the last common-dialog error code, or zero for cancellation.

proc parseInputFileSelection*(buffer: WideCString, bufferChars: int): seq[string] =
  ## Decode the bounded UTF-16, NUL-separated response from an Explorer dialog.
  var parts: seq[string] = @[]
  var offset = 0
  while offset < bufferChars:
    let start = offset
    while offset < bufferChars and uint16(buffer[offset]) != 0:
      inc offset
    if offset == bufferChars:
      raise newException(IOError, "Windows file picker returned an unterminated selection")
    if offset == start:
      if parts.len == 1:
        return parts # A single selection is already a full path.
      if parts.len > 1:
        for i in 1 ..< parts.len:
          result.add parts[0] / parts[i]
      return
    parts.add $cast[WideCString](addr buffer[start])
    inc offset
  if parts.len == 1:
    return parts
  raise newException(IOError, "Windows file picker returned an unterminated selection")

proc openInputFileDialog*(): seq[string] =
  ## Pick CSV or PNG files, returning an empty sequence on cancellation.
  var fileBuffer = newWideCString(FileBufferChars)
  # Win32 expects label/pattern pairs separated by NULs and a final extra NUL.
  let
    filterBuffer = newWideCString(
      "CSV and PNG files\0*.csv;*.png\0CSV files\0*.csv\0PNG files\0*.png\0\0"
    )
    titleBuffer = newWideCString("Select CSV or csv2png PNG files")

  var dialog = OPENFILENAMEW(
    lStructSize: uint32(sizeof(OPENFILENAMEW)),
    lpstrFile: fileBuffer,
    nMaxFile: uint32(FileBufferChars),
    lpstrFilter: filterBuffer,
    lpstrTitle: titleBuffer,
    flags: OFN_PATHMUSTEXIST or OFN_FILEMUSTEXIST or OFN_EXPLORER or OFN_ALLOWMULTISELECT,
  )

  if getOpenFileNameW(addr dialog) == 0:
    let error = commDlgExtendedError()
    if error != 0:
      raise newException(IOError, "Windows file picker failed (error " & $error & ")")
    return @[]

  parseInputFileSelection(fileBuffer, FileBufferChars)
