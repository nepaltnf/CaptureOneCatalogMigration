# Capture One Session to Catalog Migrator

An AppleScript that batch imports hundreds of Capture One sessions into a single catalog, preserving all edits, ratings, color grades, and metadata. Designed for photographers who have years of work stored as individual sessions and want to consolidate everything into one browseable catalog.

## What It Does

The script crawls a folder of Capture One sessions, finds every `.cosessiondb` file, and imports each session's images into an open Capture One catalog. It runs unattended, paces itself to avoid overwhelming the application, and can be safely interrupted and resumed at any time.

Capture One reads the `.cos` sidecar files stored alongside each raw automatically, so all edits and ratings come through exactly as they were.

Once imported, Capture One's Folders panel mirrors the original archive folder structure, so every shoot is exactly where you would expect to find it.

## Storage Architecture

This workflow is designed around a two-volume setup:

- **Catalog volume** (fast local SSD): stores the catalog file and all proxy preview files, so browsing any shoot is instant
- **Archive volume** (NAS or external drive): stores the original raw files, which stay in place and are never moved or copied

When exporting a high resolution file or JPEG, Capture One reaches back to the archive volume, reads the full raw, applies all saved adjustments, and renders the output to a folder of your choice.

## Requirements

- Capture One 23 or later
- Your catalog open in Capture One before running the script
- Both your archive volume and catalog volume mounted
- Accessibility permission granted to Script Editor or Terminal in System Settings

## Setup

Open `co_session_migrator.applescript` in Script Editor and edit the four path properties near the top of the file:

```applescript
property pSearchRoot  : "/Volumes/YOUR_ARCHIVE_VOLUME/path/to/sessions"
property pCatalogName : "YourCatalogName"
property pLogPath     : "/Volumes/YOUR_CATALOG_VOLUME/co_session_import_log.txt"
property pResumePath  : "/Volumes/YOUR_CATALOG_VOLUME/co_session_done.txt"
```

- `pSearchRoot` is the root folder containing your session folders. The script recurses into all subfolders.
- `pCatalogName` is the name of your open catalog. A partial match is fine, no `.cocatalog` extension needed.
- `pLogPath` is where the import log will be written.
- `pResumePath` is the resume file that tracks completed sessions.

## Running

From Script Editor click Run, or from Terminal:

```
osascript co_session_migrator.applescript
```

The script will scan the archive on first run and save a cached session list to `co_session_list.txt` on your catalog volume. Subsequent runs read from this cache and start importing immediately. Delete the cache file if you add new sessions and want a fresh scan.

## Resume and Retry

Every successfully imported session is appended to the resume file. If the script is interrupted for any reason, re-running it skips everything already done and picks up where it left off. Sessions that failed will be retried automatically on the next run.

To start completely fresh, delete the resume file:

```
rm /Volumes/YOUR_CATALOG_VOLUME/co_session_done.txt
```

## Pacing

The script queues imports in batches and pauses between sessions to give Capture One time to process. The default settings work well for most setups:

```applescript
property pDelayPerSession : 20    -- seconds between sessions
property pBatchSize       : 10    -- sessions per batch
property pBatchDelay      : 120   -- seconds rest between batches
```

Raise `pDelayPerSession` to 60 or higher if Capture One feels sluggish, or if you have preview generation enabled.

## Dry Run

To test on a single session before running the full batch, set:

```applescript
property pMaxSessions : 1
```

Set it back to `0` to run all sessions.

## Session Structure

The script expects a typical Capture One session layout:

```
_CATEGORY/
  ClientName/
    SessionName/
      SessionName.cosessiondb
      Selects/
        image001.IIQ
        CaptureOne/
          Settings131/
            image001.cos
```

It imports from the `Selects/` subfolder (or whichever subfolders contain raw files) rather than the session root, which avoids Capture One treating the folder as a session open request. Raw files sitting directly in the session root are also handled for older or loosely packed sessions.

Supported raw formats: IIQ, CR2, CR3, NEF, ARW, DNG, RAF, ORF, RW2, PEF, SRW.

## Log File

A full log is written to the path set in `pLogPath` after each session. Each entry shows the session path, which subfolders were found, and whether the import succeeded, was skipped, or failed.
