// workponents · files domain — a file IS a content-addressed row.
//
// The reinvention: files are not a separate filesystem, they are RECORDS in the
// workbook's SQLite — name/path/type/size/modified/content-hash. So a "drive"
// (wb-drive) is just a file/icon browser surface over a query on the SAME shared
// engine that backs tables / records / data-viz (../../data) — never a second
// store. A single file (wb-file) previews itself by type: image/audio/video
// inline (video rides the wavelet path when the Host can transcode), text
// inline, otherwise a typed icon + metadata. Content resolves through the
// Host/Dock seam when docked (the nexus holds the blob) and degrades to a `src`
// URL / inline `text` / typed placeholder standalone. wb-dropzone normalizes a
// drop/pick into content-addressed file records (sha256 over the bytes) and
// emits them for the page to register() or push to the nexus.
//
// Import this barrel to register the domain, or a single element file to stay
// lean. Standalone (zero deps, no build) by default.
export { WbDrive } from "./wb-drive.js";
export { WbFile } from "./wb-file.js";
export { WbDropzone } from "./wb-dropzone.js";
export {
  fileKind, kindGlyph, fmtBytes, fmtWhen, shortHash, extOf,
} from "./file-types.js";
