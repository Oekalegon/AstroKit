---
layout: default
title: Home
---

# AstroKit

A Swift package for astrophotography — astronomy calculations, GPU-accelerated image processing, a FITS archive, and an MCP server for Claude.

## What's included

| Component | Description |
|-----------|-------------|
| `AstroKit` | Astronomy algorithms — ephemeris, coordinates, sidereal time, solar system |
| `VSOP` | High-precision planetary positions (VSOP87) |
| `AstrophotoKit` | FITS I/O, Metal GPU pipelines, image processors |
| `AstrophotoArchiveKit` | FITS archive backed by SQLite + HEALPix, observing sessions |
| `ap` | CLI for running processing pipelines on FITS files |
| `ap-archive` | CLI for managing the FITS archive |
| `astrokit-mcp` | MCP server exposing pipelines and archive to Claude |

## Documentation

| Topic | Link |
|-------|-------|
| Pipeline CLI (`ap`) | [ap.md](ap.md) |
| Archive CLI (`ap-archive`) | [ap-archive.md](ap-archive.md) |
| MCP server (`astrokit-mcp`) | [mcp.md](mcp.md) |

## Articles

Design documents and deep dives are published under [Articles](/AstroKit/articles/).
