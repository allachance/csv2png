version = "0.1.0"
author = "Alex Lachance"
description = "Lossless CSV to RGB pixel PNG converter with DEFLATE compression"
license = "MIT"
srcDir = "src"
bin = @["csv2png"]

requires "nim >= 2.2.10"
requires "zippy >= 0.10.20 & < 0.11.0"

task release, "Build an optimized csv2png executable in build/":
  exec "nimble build -d:release"
  mkDir "build"
  cpFile "csv2png.exe", "build/csv2png.exe"
