public enum PipelineToolDefinitions {
    /// MCP-compatible tool schemas for pipeline operations.
    /// Consumed by MCP server (tools/list) and by native clients (e.g. Navi).
    public static let all: [[String: Any]] = [
        [
            "name": "list_pipelines",
            "description": "List all available astrophoto processing pipelines with their IDs and descriptions.",
            "inputSchema": [
                "type": "object",
                "properties": [String: String](),
                "required": [String](),
            ] as [String: Any],
        ],
        [
            "name": "inspect_pipeline",
            "description": "Get detailed information about a pipeline: required inputs, tunable parameters, and processing steps.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "pipeline_id": [
                        "type": "string",
                        "description": "The pipeline ID to inspect (e.g. 'star_detection').",
                    ],
                ] as [String: Any],
                "required": ["pipeline_id"],
            ] as [String: Any],
        ],
        [
            "name": "run_pipeline",
            "description": "Execute an astrophoto pipeline on one or more FITS files and return the analysis results. Frames can be supplied from the archive via input_frameset_id. Use input_paths (array) for ad-hoc multi-frame pipelines such as frame_registration_quad. Metadata-only pipelines (e.g. frame_quality) update the source frame's archive record and produce no output file; output_path has no effect for these pipelines.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "pipeline_id": [
                        "type": "string",
                        "description": "Pipeline ID to run (e.g. 'star_detection', 'frame_registration_quad').",
                    ],
                    "input_frameset_id": [
                        "type": "string",
                        "description": "UUID of an archive FrameSet to use as input (from archive_frameset_list or archive_frameset_create). Takes precedence over input_dir, input_paths, and input_path.",
                    ],
                    "input_frame_id": [
                        "type": "string",
                        "description": "UUID of a single archive frame to use as input (from archive_find or archive_get). For single-frame pipelines such as star_detection, optical_quality, and collimation. Takes precedence over input_path.",
                    ],
                    "input_path": [
                        "type": "string",
                        "description": "Absolute path to a single input FITS file (single-frame pipelines).",
                    ],
                    "input_paths": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Array of absolute FITS file paths for multi-frame pipelines (e.g. frame_registration_quad). Takes precedence over input_path.",
                    ],
                    "input_dir": [
                        "type": "string",
                        "description": "Absolute path to a directory containing FITS files. All .fits/.fit/.fts files are loaded as a FrameSet (sorted by filename). Takes precedence over input_paths and input_path.",
                    ],
                    "input_name": [
                        "type": "string",
                        "description": "Pipeline input name. Omit for single-input pipelines (auto-detected).",
                    ],
                    "parameters": [
                        "type": "object",
                        "description": "Optional pipeline parameters as key-value pairs. Use inspect_pipeline to see available parameters.",
                    ],
                    "output_path": [
                        "type": "string",
                        "description": "Optional file path to save the output. For stacking pipelines (e.g. frame_stacking) this writes a FITS file containing the stacked image and registration table. For analysis pipelines (e.g. frame_registration_quad) it writes the result table. Use .csv extension with output_format=csv for a plain-text table. Has no effect for metadata-only pipelines (e.g. frame_quality).",
                    ],
                    "output_format": [
                        "type": "string",
                        "enum": ["fits", "csv"],
                        "description": "Output file format: 'fits' (BINTABLE, default) or 'csv'.",
                    ],
                ] as [String: Any],
                "required": ["pipeline_id"],
            ] as [String: Any],
        ],
    ]
}
