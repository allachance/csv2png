# csv2png

A Windows-only Nim CLI for losslessly storing CSV files in PNG files with DEFLATE compression, and restoring them. CSV bytes (including encoding, BOM, and line endings) are preserved exactly; the contents are not parsed as rows.

The generated PNG is an opaque, 8-bit RGB image of colored data dots: every three raw CSV bytes become one pixel's red, green, and blue channels, in row-major order. Its width is the ceiling of the square root of the required pixel count, and its height is the number of rows needed. Unused channels and pixels are zero (black); an empty CSV produces one black pixel. PNG `IDAT` stores these actual pixels with zlib/DEFLATE compression and unfiltered scanlines. A private ancillary `cdVd` chunk contains the format marker `RGB1` and a big-endian 32-bit original byte length, so padding is removed without losing genuine trailing zero bytes.

**Decoding requires csv2png's `RGB1` length metadata and unchanged RGB bytes.** The decoder accepts all five standard PNG row filters, consecutive split `IDAT` chunks, additional ancillary chunks, and alternative dimensions with sufficient capacity and zero padding. Images must remain non-interlaced, 8-bit RGB. Image editors may strip metadata, convert the color format, or change pixel values, so resaving is not guaranteed to preserve the CSV; keep the original archive.

## Requirements

- Windows for building and running.
- Nim 2.2.10 or later for building. Nimble installs the pure-Nim `zippy` package during the build.
- **No compression DLL is needed to run the executable.**

## Build and test

```sh
nimble build
nimble test
```

`nimble release` builds an optimized executable at `build/csv2png.exe`.

**Compatibility:** Only RGB PNGs with `RGB1` length metadata are supported. Previous transparent 1×1 DEFLATE containers and initial Zstandard containers cannot be decoded; restore them with a compatible older executable before upgrading.

## Usage

```sh
csv2png data.csv                 # creates data.png
csv2png data.png                 # restores data.csv
csv2png data.csv -o archive.png  # choose a destination
csv2png --help
```

Output is staged in the destination directory and published only after a complete write, without replacing existing files (including the source CSV when converting back). With **no arguments**, a native Windows file picker opens for CSV or PNG input; canceling exits without writing anything. Errors print to stderr and exit nonzero.

## Example round trip

[`examples/sample.csv`](examples/sample.csv) includes quoted fields, commas, and escaped quotes. After `nimble build`, run the standalone [PowerShell example](examples/roundtrip.ps1) from the project root:

```powershell
.\examples\roundtrip.ps1
```

The script runs from its own directory, deletes any existing `sample.png` and `sample.restored.csv` before converting. It preserves `sample.csv` and leaves the regenerated outputs for inspection.

Or run these commands manually in PowerShell from the project root:

```powershell
.\csv2png.exe examples/sample.csv
.\csv2png.exe examples/sample.png -o examples/sample.restored.csv

```

The first command creates `examples/sample.png`; the second restores the CSV to a different filename because the original still exists. The PNG appears as colored RGB data dots, not a table visualization; small CSV files produce very small images, so zoom in to see individual pixels. To repeat the manual commands, remove only the generated `examples/sample.png` and `examples/sample.restored.csv` files first; the converter itself never overwrites existing outputs. The PowerShell script handles this cleanup automatically.

The decoder validates chunk bounds and checksums, container structure, length metadata, zero padding, and the zlib checksum. A pure-Nim fixed-buffer DEFLATE decoder checks every write against the expected output size; oversized compressed output is rejected without growing the output buffer. No compression DLL is required.

CSV input and restored data are limited to 512 MiB; PNG input is limited to 514 MiB. RGB scanline data and combined compressed image data are limited to 513 MiB. File sizes are checked before reading, and reads remain bounded if the file grows. These are per-buffer limits, not a total process memory budget: the input, compressed image data, decompressed scanlines, and restored CSV can coexist in memory. Large files still require substantial RAM, and untrusted files may consume significant memory and CPU within these limits.
