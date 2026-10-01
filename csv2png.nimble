import std/strutils

# Package
version = "0.2.0"
author = "Alex Lachance"
description = "Lossless CSV to RGB pixel PNG converter with DEFLATE compression"
license = "MIT"
srcDir = "src"
bin = @["csv2png"]

# Dependencies
requires "nim >= 2.2.10"
requires "zippy == 0.10.20"

# Build configuration
const
  exeName = "csv2png"
  buildDir = "build"
  cacheDir = buildDir & "/nimcache"
  distDir = "dist"
  resourceScript = exeName & ".rc"
  iconFile = "assets/csv2png.ico"
  target = "x86_64-windows-gnu"
  zigcc = "scripts/zigcc.bat"

# Build
proc compileResource(): string =
  result = buildDir & "/" & exeName & ".res"

  if not fileExists(resourceScript):
    quit("Missing resource script: " & resourceScript)

  if not fileExists(iconFile):
    quit("Missing application icon: " & iconFile)

  mkDir buildDir

  exec "zig rc --fo " & result & " " & resourceScript

proc compileExe() =
  let
    output = buildDir & "/" & exeName & ".exe"
    source = srcDir & "/" & exeName & ".nim"

  if not fileExists(zigcc):
    quit("Missing zig cc wrapper: " & zigcc)

  mkDir buildDir

  let resource = compileResource()

  var args: seq[string]
  args.add "nimble -y c"
  args.add "--verbosity:3"
  args.add "--cc:clang"
  args.add "--clang.exe:" & zigcc
  args.add "--clang.linkerexe:" & zigcc
  args.add "--passC:--target=" & target
  args.add "--passL:--target=" & target
  args.add "--passL:-s"
  args.add "--passL:" & resource
  args.add "-d:NimblePkgVersion=" & version
  args.add "--nimcache:" & cacheDir
  args.add "--out:" & output
  args.add "--os:windows"
  args.add "--cpu:amd64"
  args.add "-d:release"
  args.add "--opt:speed"
  args.add source

  exec args.join(" ")

# Distribution
proc assemblePackage() =
  let
    packageDir = distDir & "/" & exeName & "-v" & version & "-win_amd64"
    builtExe = buildDir & "/" & exeName & ".exe"

  if not fileExists(builtExe):
    quit("Missing built executable: " & builtExe)

  mkDir packageDir

  cpFile(builtExe, packageDir & "/" & exeName & ".exe")
  cpFile("README.md", packageDir & "/README.md")
  cpFile("LICENSE", packageDir & "/LICENSE")
  cpFile("THIRD-PARTY-NOTICES.md", packageDir & "/THIRD-PARTY-NOTICES.md")

proc assembleDistribution() =
  if dirExists(distDir):
    rmDir distDir

  assemblePackage()

# Tasks
task bin, "Build the release executable":
  compileExe()

task dist, "Build and assemble the distribution":
  compileExe()
  assembleDistribution()
