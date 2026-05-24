<img src="docs/assets/images/astrophotokit.png" alt="AstrophotoKit logo" width="200" height="200" style="display: block; margin: auto;"/>

# AstrophotoKit

A Swift package for astronomical image processing. Reads and writes FITS files via CFITSIO, runs GPU-accelerated processing pipelines using Metal, and exposes everything through a pipeline CLI, an archive CLI, and a Model Context Protocol server.

## Documentation

Full documentation: [oekalegon.org/AstrophotoKit](https://oekalegon.org/AstrophotoKit/)

| Topic | Link |
|-------|-------|
| Pipeline CLI (`ap`) | [docs/ap.md](docs/ap.md) |
| Archive CLI (`ap-archive`) | [docs/ap-archive.md](docs/ap-archive.md) |
| MCP server (`astrokit-mcp`) | [docs/mcp.md](docs/mcp.md) |

## What's included

| Component | Description |
|-----------|-------------|
| `AstrophotoKit` | Swift library — FITS I/O, Metal pipelines, image processors |
| `AstrophotoArchiveKit` | Swift library — FITS archive backed by SQLite + HEALPix |
| `ap` | CLI for running processing pipelines on FITS files |
| `ap-archive` | CLI for managing the FITS archive |
| `astrokit-mcp` | MCP server exposing pipelines and archive to Claude |

## Prerequisites

CFITSIO must be installed before building.

```bash
# macOS
brew install cfitsio

# Linux
sudo apt-get install libcfitsio-dev
```

## Building

```bash
swift build -c release
```

Binaries are placed in `.build/release/`. Copy whichever you need to your `PATH`:

```bash
cp .build/release/ap          /usr/local/bin/
cp .build/release/ap-archive  /usr/local/bin/
cp .build/release/astrokit-mcp /usr/local/bin/
```

## Versioning

The version string is `major.minor.patch+build` (e.g. `1.0.0+48`). Edit `version.txt` to set the semantic part; the build number increments automatically with each git commit.

```bash
ap --version          # 1.0.0+48
ap-archive --version  # 1.0.0+48
```

## Quick start

### Run a pipeline

```bash
ap run star_detection --input M51.fits
ap run frame_stacking --input input_frames:/path/to/lights/ --output stacked.fits
```

### Archive your FITS files

```bash
export ASTROARCHIVE_PATH=~/AstroArchive

ap-archive add ~/lights/ --recursive --copy
ap-archive find --object M51 --type light --filter Ha
ap-archive stats
```

### Connect to Claude

Add to `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "astrokit": {
      "command": "/usr/local/bin/astrokit-mcp"
    }
  }
}
```

Claude can then run pipelines and query the archive directly.

## Built-in pipelines

| ID | Description |
|----|-------------|
| `star_detection` | Detect stars, measure FWHM and eccentricity |
| `optical_quality` | Optical quality metrics |
| `collimation_reflector` | Mirror collimation analysis |
| `collimation_reflector_wavelet` | Wavelet-based collimation |
| `collimation_reflector_twophase` | Two-phase collimation |
| `collimation_reflector_radial` | Radial collimation analysis |
| `autofocus_focused` | Autofocus curve for focused images |
| `autofocus_donut` | Autofocus curve for donut (defocused) images |
| `dark_calibration` | Dark frame calibration |
| `frame_registration` | Align multiple frames to a common reference |
| `frame_stacking` | Register and stack frames into a master light |

## Requirements

- macOS 26+
- Swift 5.9+
- CFITSIO (`brew install cfitsio`)
- Metal-capable GPU (for image processing pipelines)
