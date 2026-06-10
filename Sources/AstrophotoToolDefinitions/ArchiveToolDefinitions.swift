public enum ArchiveToolDefinitions {
    /// MCP-compatible tool schemas for all archive operations.
    /// Consumed by MCP server (tools/list) and by native clients (e.g. Navi).
    public static let all: [[String: Any]] = [
        [
            "name": "archive_add",
            "description": "Add a FITS file or directory of FITS files to the astrophoto archive. Reads metadata from FITS headers automatically.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": [
                        "type": "string",
                        "description": "Absolute path to a FITS file or directory.",
                    ],
                    "recursive": [
                        "type": "boolean",
                        "description": "Recurse into subdirectories (when path is a directory). Default false.",
                    ],
                ] as [String: Any],
                "required": ["path"],
            ] as [String: Any],
        ],
        [
            "name": "archive_search",
            "description": "Search the archive for frames, frame sets, or both. Equivalent to Finder search — returns files (frames) and folders (frame sets) together by default. Use kind to restrict to one type.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "kind": [
                        "type": "string",
                        "enum": ["both", "frames", "framesets"],
                        "description": "What to search: frames, framesets, or both (default: both).",
                    ],
                    "object_name": ["type": "string", "description": "Partial object name match (applies to both frames and frame sets)."],
                    "frame_types": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Frame types to include (light, dark, flat, bias, diagnostic). Applies to both.",
                    ],
                    "filters": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Optical filters (Hɑ, SII, OIII, R, G, B, L). Applies to both.",
                    ],
                    "processing_level": [
                        "type": "string",
                        "enum": ["raw", "calibrated", "stacked", "stretched"],
                        "description": "Filter by processing level. Applies to both.",
                    ],
                    "camera": ["type": "string", "description": "Camera name, exact match. Applies to both."],
                    "from_date": ["type": "string", "description": "Start date YYYY-MM-DD. Applies to both (date span overlap for frame sets)."],
                    "to_date": ["type": "string", "description": "End date YYYY-MM-DD. Applies to both."],
                    "name": ["type": "string", "description": "Partial match on frame set name (frame sets only)."],
                    "max_fwhm": ["type": "number", "description": "Frames only: median FWHM ≤ this value (pixels)."],
                    "min_stars": ["type": "integer", "description": "Frames only: at least this many detected stars."],
                    "max_background_noise": ["type": "number", "description": "Frames only: background noise ≤ this value."],
                    "max_eccentricity": ["type": "number", "description": "Frames only: median star eccentricity ≤ this value (0=circular)."],
                    "stacked": ["type": "boolean", "description": "Frames only: only stacked (master) frames. Shorthand for processing_level=stacked."],
                    "include_rejected": ["type": "boolean", "description": "Frames only: include rejected frames (default false)."],
                    "rejected_only": ["type": "boolean", "description": "Frames only: return only rejected frames."],
                    "ra": ["type": "number", "description": "Frames only: cone search centre RA (degrees)."],
                    "dec": ["type": "number", "description": "Frames only: cone search centre Dec (degrees)."],
                    "radius_deg": ["type": "number", "description": "Frames only: cone search radius (degrees)."],
                    "limit": ["type": "integer", "description": "Frames only: maximum number of frames to return."],
                ] as [String: Any],
                "required": [],
            ] as [String: Any],
        ],
        [
            "name": "archive_get",
            "description": "Show all stored information for a single archive frame by UUID.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Archive frame UUID (from archive_find)."],
                ] as [String: Any],
                "required": ["id"],
            ] as [String: Any],
        ],
        [
            "name": "archive_list_objects",
            "description": "List all objects in the archive with their frame counts.",
            "inputSchema": [
                "type": "object",
                "properties": [String: Any](),
                "required": [String](),
            ] as [String: Any],
        ],
        [
            "name": "archive_stats",
            "description": "Get archive statistics: frame counts by type/filter, disk usage, and objects.",
            "inputSchema": [
                "type": "object",
                "properties": [String: Any](),
                "required": [String](),
            ] as [String: Any],
        ],
        [
            "name": "archive_frameset_inspect",
            "description": "Dry-run: inspect which frames would be included in a frame set and report property distributions (cameras, filters, date span, temperature range, pixel scales, position angles, …) without writing to the database. Use this before archive_frameset_create to check frame compatibility.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "frame_type": ["type": "string", "enum": ["light", "dark", "flat", "bias", "diagnostic"], "description": "Frame type to inspect."],
                    "object_name": ["type": "string", "description": "Partial object name to match (e.g. 'M51')."],
                    "filters": ["type": "array", "items": ["type": "string"], "description": "Optical filters to include (Hɑ, SII, OIII, R, G, B, L)."],
                    "camera": ["type": "string", "description": "Camera name (exact match)."],
                    "from_date": ["type": "string", "description": "Start date YYYY-MM-DD."],
                    "to_date": ["type": "string", "description": "End date YYYY-MM-DD."],
                    "processing_level": ["type": "string", "enum": ["raw", "calibrated", "stacked", "stretched"], "description": "Filter by processing level."],
                    "calibrated": ["type": "boolean", "description": "Only calibrated frames."],
                    "temp_center": ["type": "number", "description": "Centre temperature in °C for dark frame grouping."],
                    "temp_tolerance": ["type": "number", "description": "Temperature tolerance ±°C (default 2.0)."],
                    "max_fwhm": ["type": "number", "description": "Only frames with median FWHM ≤ this value (pixels). Frames without quality data are excluded."],
                    "min_stars": ["type": "integer", "description": "Only frames with at least this many detected stars. Frames without quality data are excluded."],
                    "max_background_noise": ["type": "number", "description": "Only frames with background noise ≤ this value (ADU for frames processed with quality pipelines). Frames without quality data are excluded."],
                    "max_eccentricity": ["type": "number", "description": "Only frames with median star eccentricity ≤ this value (0=circular). Frames without quality data are excluded."],
                ] as [String: Any],
                "required": [],
            ] as [String: Any],
        ],
        [
            "name": "archive_frameset_create",
            "description": "Create a named frame set by querying the archive. All matched frames must share the same frame type and processing level. Mixed optical filters are blocked by default — set force=true to allow them (stored as a comma-separated list). Rejected frames are automatically excluded. Always returns the inspection report alongside the new set.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Name for the frame set. Auto-generated from query parameters if omitted."],
                    "frame_type": ["type": "string", "enum": ["light", "dark", "flat", "bias", "diagnostic"], "description": "Frame type to include (required — a set is homogeneous)."],
                    "object_name": ["type": "string", "description": "Partial object name to match (e.g. 'M51')."],
                    "filters": ["type": "array", "items": ["type": "string"], "description": "Optical filters to include (Hɑ, SII, OIII, R, G, B, L)."],
                    "camera": ["type": "string", "description": "Camera name (exact match)."],
                    "from_date": ["type": "string", "description": "Start date YYYY-MM-DD."],
                    "to_date": ["type": "string", "description": "End date YYYY-MM-DD."],
                    "processing_level": ["type": "string", "enum": ["raw", "calibrated", "stacked", "stretched"], "description": "Filter by processing level."],
                    "calibrated": ["type": "boolean", "description": "Only calibrated frames."],
                    "temp_center": ["type": "number", "description": "Centre temperature in °C for dark frame grouping."],
                    "temp_tolerance": ["type": "number", "description": "Temperature tolerance ±°C (default 2.0)."],
                    "max_fwhm": ["type": "number", "description": "Only frames with median FWHM ≤ this value (pixels). Frames without quality data are excluded."],
                    "min_stars": ["type": "integer", "description": "Only frames with at least this many detected stars. Frames without quality data are excluded."],
                    "max_background_noise": ["type": "number", "description": "Only frames with background noise ≤ this value (ADU for frames processed with quality pipelines). Frames without quality data are excluded."],
                    "max_eccentricity": ["type": "number", "description": "Only frames with median star eccentricity ≤ this value (0=circular). Frames without quality data are excluded."],
                    "force": ["type": "boolean", "description": "Allow mixed optical filters; stored as comma-separated list on the frame set (default false)."],
                ] as [String: Any],
                "required": ["frame_type"],
            ] as [String: Any],
        ],
        [
            "name": "archive_frameset_get",
            "description": "Get details of a frame set, including its member frames.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Frame set UUID."],
                ] as [String: Any],
                "required": ["id"],
            ] as [String: Any],
        ],
        [
            "name": "archive_frameset_quality",
            "description": "Display a per-frame quality summary for a frame set (star count, FWHM, eccentricity, background noise). Quality metrics are read from the archive; run ap-archive frameset quality <id> or ap run frame_quality --input @frameset:<id> first to populate them.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Frame set UUID."],
                ] as [String: Any],
                "required": ["id"],
            ] as [String: Any],
        ],
        [
            "name": "archive_frameset_exclude",
            "description": "Mark a frame as excluded within a specific frame set. Excluded frames are skipped during processing but remain in the set. Unlike the global reject flag, this is specific to one frame set.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "frameset_id": ["type": "string", "description": "Frame set UUID."],
                    "frame_id":    ["type": "string", "description": "Frame UUID to exclude."],
                    "reason":      ["type": "string", "description": "Optional reason for exclusion."],
                    "undo":        ["type": "boolean", "description": "Set to true to re-include the frame (clear the excluded flag)."],
                ] as [String: Any],
                "required": ["frameset_id", "frame_id"],
            ] as [String: Any],
        ],
        [
            "name": "archive_frameset_delete",
            "description": "Delete a frame set. Member frames are not removed from the archive.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Frame set UUID."],
                ] as [String: Any],
                "required": ["id"],
            ] as [String: Any],
        ],
        [
            "name": "archive_recent",
            "description": "List the most recently archived frames, newest first. Useful for seeing what was just added or produced by a pipeline run.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": [
                        "type": "integer",
                        "description": "Maximum number of frames to return (default: 15).",
                    ],
                ] as [String: Any],
                "required": [],
            ] as [String: Any],
        ],
        [
            "name": "archive_remove",
            "description": "Remove a frame from the archive by its UUID.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Archive frame UUID."],
                    "delete_file": ["type": "boolean", "description": "Also delete the FITS file from disk."],
                ] as [String: Any],
                "required": ["id"],
            ] as [String: Any],
        ],
        [
            "name": "archive_reject",
            "description": "Mark a frame as rejected (excluded from processing) or clear the rejection flag.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Archive frame UUID."],
                    "reason": ["type": "string", "description": "Optional reason for rejection."],
                    "undo": ["type": "boolean", "description": "Set to true to clear the rejection flag (un-reject)."],
                ] as [String: Any],
                "required": ["id"],
            ] as [String: Any],
        ],
        [
            "name": "archive_update_stretch",
            "description": "Save or clear the display stretch settings for an archived frame. The stretch is stored as two independent pieces: (1) normalization bounds (input_black / input_white) — the sub-range that was mapped to [0, 1] when the user pressed Normalize; and (2) slider positions (slider_black / slider_white) — where the black/white-point sliders currently sit within [0, 1] of the full data range. Both are independent of bit depth and sensor gain. Pass reset: true to clear everything. The underlying FITS file is never modified.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id":           ["type": "string",  "description": "Archive frame UUID."],
                    "input_black":  ["type": "number",  "description": "Normalized [0, 1] normalization black bound. Must be < input_white."],
                    "input_white":  ["type": "number",  "description": "Normalized [0, 1] normalization white bound. Must be > input_black."],
                    "slider_black": ["type": "number",  "description": "Black-point slider in [0, 1] of the full data range (independent of the normalization bounds)."],
                    "slider_white": ["type": "number",  "description": "White-point slider in [0, 1] of the full data range (independent of the normalization bounds)."],
                    "reset":        ["type": "boolean", "description": "When true, clears all stretch and slider state. Overrides all other parameters."],
                ] as [String: Any],
                "required": ["id"],
            ] as [String: Any],
        ],
        [
            "name": "archive_update_quality",
            "description": "Update quality metrics for an archived frame. Metrics are normally populated automatically after running a quality pipeline (frame_quality for light frames, calibration_quality for dark/bias/flat) via run_pipeline. Use this tool to set or correct them manually. Only supplied fields are updated; omitted fields are unchanged.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Archive frame UUID."],
                    "star_count": ["type": "integer", "description": "Number of detected stars (light frames)."],
                    "saturated_star_count": ["type": "integer", "description": "Number of saturated stars (peak ≥ 90 % full-scale)."],
                    "median_fwhm": ["type": "number", "description": "Median FWHM in pixels (average of major and minor axes)."],
                    "background_noise": ["type": "number", "description": "Background level in ADU (light frames, frame_quality pipeline) or noise sigma in ADU (calibration frames, calibration_quality pipeline). Legacy pipelines store a normalised 0–1 value."],
                    "median_eccentricity": ["type": "number", "description": "Median star eccentricity (0=circular, closer to 0 is rounder). Indicates optical quality and tracking accuracy."],
                    "hot_pixel_count": ["type": "integer", "description": "Approximate count of hot pixels (calibration frames, from calibration_quality pipeline)."],
                ] as [String: Any],
                "required": ["id"],
            ] as [String: Any],
        ],
        [
            "name": "archive_backfill_metadata",
            "description": "Re-read FITS headers for existing archived frames and fill in missing metadata. Fills observation strings (OBJECT → objectName, INSTRUME → camera, TELESCOP → telescope, OBSERVAT → site) and numeric acquisition data (EXPTIME → exposureTime, GAIN → gain, OFFSET → offset, CCD-TEMP → temperature, EGAIN → egain, FOCALLEN → focalLength, PIXSCALE → pixelScale, POSANGLE → positionAngle). Only fills fields that are currently nil — existing values are never overwritten. When exposureTime is recovered the frame's deduplication signature is recomputed. By default only raw frames are processed; pass include_stacked: true to also include calibrated and stacked frames.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "include_stacked": ["type": "boolean", "description": "Also process calibrated and stacked frames (default: false, raw only)."],
                ] as [String: Any],
                "required": [],
            ] as [String: Any],
        ],
    ]
}
