public enum FITSToolDefinitions {
    /// MCP-compatible tool schemas for FITS file inspection.
    /// Consumed by MCP server (tools/list) and by native clients (e.g. Navi).
    public static let all: [[String: Any]] = [
        [
            "name": "fits_headers",
            "description": "Read the full FITS header of a file and return it as JSON, grouped by topic (Object, Observation, Telescope & Optics, Camera, Site & Conditions, Astrometric Solution, Processing & Stacking, Quality, File Structure) with human readable names. Each entry includes the original FITS keyword and raw value; the response also contains the complete original header as a flat object. Provide either path or frame_id.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": [
                        "type": "string",
                        "description": "Absolute path to a FITS file.",
                    ],
                    "frame_id": [
                        "type": "string",
                        "description": "UUID of an archive frame (from archive_search, archive_get, or archive_recent). Used when path is not given.",
                    ],
                ] as [String: Any],
                "required": [String](),
            ] as [String: Any],
        ],
    ]
}
