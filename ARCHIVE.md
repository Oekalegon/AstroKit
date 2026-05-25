# Archiving Astrophotogical data

Part of *AstrophotographyKit* is an archiving functionality for astrophotography frames and data (in tabular form). We assume frames and tabular data is stored in FITS format. The archive is at a specific file location on disk (preferably a large one). A sqlite database is located at the folder specified by the path. Usually a user will have an environmental value set for the path.

The archive allows finding frames by object or celestial coordinates, frame type (bias/light/dark,...), filter used, camera, optical train properties as far as they are known, camera temperature, timestamp, etc... The level of processing should also be clear, i.e. whether it is a stacked image, whether it is calibrated (and with which calibration frames), whether it is stretched. Frames that are unusable (e.g. due to telescope movement or tracking errors) can be flagged as **rejected** with an optional reason; rejected frames are excluded from all queries by default so they never reach a processing pipeline.

The frames should be copied to (sub)folders in the archive folder, i.e. by object/date/frame-type/filter.

Tables in the FITS files should also be archived and searchable.

Statistical functions should also be available; 
* Number of objects
* Number of frames
* Number of frames by type
* Number of frames by type and filter
* Number of processed frames by object
* Used size by the archive on the drive
* Remaining size on the drive
* etc...

This should include a Swift importable `AstrophotoArchiveKit`, a CLI and an MCP.