---
layout: page
title: About
permalink: /about/
---

AstroKit is a unified Swift package that bundles celestial dynamics, astrophotography image processing, and FITS archive management into a single repository.

## Components

### AstroKit — Celestial dynamics
Swift library for astronomical calculations: ephemeris, solar system positions (VSOP87), coordinate transforms, sidereal time, and rise/transit/set computations.

### AstrophotoKit — Image processing
Swift library for astrophotography: fast FITS file reading and writing via CFITSIO, GPU-accelerated image processing with Metal shaders, and a full pipeline system covering star detection, FWHM/eccentricity measurement, collimation analysis, autofocus curves, frame calibration, registration, and stacking.

### AstrophotoArchiveKit — FITS archive
SQLite-backed archive with HEALPix spatial indexing. Supports search by object, coordinates, frame type, filter, date, processing level, and quality metrics. Features include:

- **Observing sessions**: raw light frames automatically grouped by night and imaging site
- **Frame lineage**: tracks which raw frames produced each processed or stacked result
- **Quality metrics**: per-frame FWHM, eccentricity, background noise, star count

### Tooling
- **`ap`**: CLI for running AstrophotoKit processing pipelines on FITS files
- **`ap-archive`**: CLI for managing the AstrophotoArchiveKit archive
- **`astrokit-mcp`**: MCP server exposing pipelines and archive to Claude Desktop and compatible clients
