---
layout: page
title: About
permalink: /about/
---

AstroKit is a Swift package for astrophotography. It covers the full workflow from raw captures to processed results: astronomy calculations, GPU-accelerated image processing, a searchable FITS archive, and an MCP server that lets Claude query and analyse your data directly.

## Features

- **Astronomy calculations**: Ephemeris, solar system positions (VSOP87), coordinates, sidereal time, rise/transit/set times
- **FITS file support**: Fast reading and writing via CFITSIO
- **Metal GPU pipelines**: GPU-accelerated image processing with custom Metal shaders
- **Image processors**: Star detection, FWHM/eccentricity, collimation, autofocus, stacking, registration, calibration
- **FITS archive**: SQLite-backed archive with HEALPix spatial indexing; search by object, coordinates, frame type, filter, date, and quality metrics
- **Observing sessions**: Raw light frames are automatically grouped by night (sunset-to-sunrise) and imaging site (3 km radius)
- **Frame lineage**: Tracks which raw frames were used to produce each processed or stacked result
- **MCP server**: Exposes pipelines and archive to Claude Desktop, VS Code, or any MCP-compatible client
