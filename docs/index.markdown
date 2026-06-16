---
layout: default
title: Home
---

# AstroKit

A unified Swift package bundling celestial dynamics, astrophotography image processing, and FITS archive management.

## What's included

| Component | Description |
|-----------|-------------|
| `AstroKit` | Celestial dynamics — ephemeris, coordinates, sidereal time, rise/transit/set |
| `VSOP` | High-precision planetary positions (VSOP87) |
| `AstrophotoKit` | Astrophotography — FITS I/O, Metal GPU pipelines, image processors |
| `AstrophotoArchiveKit` | FITS archive backed by SQLite + HEALPix, observing sessions |
| `ap` | CLI for running AstrophotoKit processing pipelines on FITS files |
| `ap-archive` | CLI for managing the AstrophotoArchiveKit archive |
| `astrokit-mcp` | MCP server exposing AstrophotoKit pipelines and archive to Claude |

## Documentation

| Topic | Link |
|-------|-------|
| Pipeline CLI (`ap`) | [ap.md](ap.md) |
| Archive CLI (`ap-archive`) | [ap-archive.md](ap-archive.md) |
| MCP server (`astrokit-mcp`) | [mcp.md](mcp.md) |

## Articles

Design documents and deep dives are published under [Articles](/AstroKit/articles/).
