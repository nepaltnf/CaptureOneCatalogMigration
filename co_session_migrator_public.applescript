-- ============================================================
-- Capture One: Session-to-Catalog Batch Migrator
-- ============================================================
-- Crawls a folder of Capture One sessions (.cosessiondb files),
-- imports each session's images into an open Capture One catalog,
-- and logs all results. Edits, ratings, and metadata stored in
-- .cos sidecar files are preserved automatically.
--
-- The catalog and its preview files should live on a fast local
-- drive. Raw files can remain on a NAS or archive volume --
-- Capture One references them in place and only reads the full
-- raw when exporting.
--
-- REQUIREMENTS:
--   Capture One must be running with your catalog open.
--   Your archive volume must be mounted.
--   Your catalog volume must be mounted.
--
-- Run from Script Editor, or via Terminal:
--   osascript co_session_migrator.applescript
-- ============================================================

-- ── Pacing ───────────────────────────────────────────────────

property pDelayPerSession : 20
-- Seconds to pause after queuing each import.
-- Raise if Capture One feels sluggish (try 60 with previews on).

property pBatchSize : 10
-- Number of sessions per batch before a longer rest.

property pBatchDelay : 120
-- Seconds to rest between batches.

-- ── Dialog handling ──────────────────────────────────────────

property pDialogProbeTimeout : 15
-- Short timeout to detect blocked dialogs.

property pImportTimeout : 300
-- Full timeout after any dialog is dismissed.

property pDialogPollSeconds : 20
-- How long to poll for a dialog before giving up.

-- ── Paths ─────────────────────────────────────────────────────
-- Edit these four lines to match your setup.

property pSearchRoot      : "/Volumes/YOUR_ARCHIVE_VOLUME/path/to/sessions"
-- Root folder containing your Capture One session folders.
-- The script will recurse into all subfolders looking for .cosessiondb files.

property pCatalogName     : "YourCatalogName"
-- Partial name of your open catalog (no .cocatalog extension needed).

property pLogPath         : "/Volumes/YOUR_CATALOG_VOLUME/co_session_import_log.txt"
property pResumePath      : "/Volumes/YOUR_CATALOG_VOLUME/co_session_done.txt"
-- One successfully-imported session path per line.
-- Delete this file to start fresh. Re-running safely skips completed sessions.

property pSessionListPath : "/Volumes/YOUR_CATALOG_VOLUME/co_session_list.txt"
-- Cached list of all .cosessiondb paths found on first scan.
-- Avoids re-scanning the archive on subsequent runs.
-- Delete this file to force a fresh scan.

property pPreflightLog    : "/Volumes/YOUR_CATALOG_VOLUME/co_preflight_report.txt"

property pMaxSessions : 0
-- Set to 1 for a single dry-run test. Set to 0 to run all sessions.

-- ── Globals ───────────────────────────────────────────────────

global gLog

-- ══════════════════════════════════════════════════════════════
-- ENTRY POINT
-- ══════════════════════════════════════════════════════════════

on run
	set gLog to ""

	my logLine("=== Capture One Session-to-Catalog Migrator ===")
	my logLine("Started      : " & ((current date) as text))
	my logLine("Search root  : " & pSearchRoot)
	my logLine("Catalog      : " & pCatalogName)
	my logLine("Pacing       : " & pDelayPerSession & "s/session, batch " & ¬
		pBatchSize & "@" & pBatchDelay & "s rest")
	my logLine("Resume file  : " & pResumePath)
	my logLine("")

	-- ── Load already-completed sessions ────────────────────────
	set doneSessions to my loadDoneSessions()
	set doneCount to 0
	if doneSessions is not "" then
		set savedDelims to AppleScript's text item delimiters
		set AppleScript's text item delimiters to return
		set doneCount to (count of text items of doneSessions) - 1
		set AppleScript's text item delimiters to savedDelims
	end if
	if doneCount > 0 then
		my logLine("Resuming: " & doneCount & " session(s) already imported -- will skip them.")
	else
		my logLine("No resume file found -- starting fresh.")
	end if
	my logLine("")

	-- ── 1. Verify archive volume ───────────────────────────────
	try
		do shell script "test -d " & quoted form of pSearchRoot
	on error
		set msg to "Archive volume not mounted or path not found:" & return & pSearchRoot
		my logLine("FATAL -- " & msg)
		my writeLog()
		return
	end try

	-- ── 2. Find all .cosessiondb files (cached after first scan) ──
	set rawFind to ""
	set cacheExists to false
	try
		do shell script "test -f " & quoted form of pSessionListPath
		set cacheExists to true
	end try

	if cacheExists then
		my logLine("Session list  : loaded from cache (" & pSessionListPath & ")")
		set rawFind to do shell script "cat " & quoted form of pSessionListPath
	else
		my logLine("Session list  : scanning archive (first run -- this takes a few minutes on a NAS)...")
		my writeLog()
		try
			set rawFind to do shell script ¬
				"find " & quoted form of pSearchRoot & ¬
				" -name '*.cosessiondb' -type f 2>/dev/null | sort"
		on error err
			my logLine("FATAL -- find failed: " & err)
			my writeLog()
			error "find failed -- check log at: " & pLogPath
		end try
		try
			do shell script "echo " & quoted form of rawFind & " > " & quoted form of pSessionListPath
		end try
		my logLine("Session list  : saved to " & pSessionListPath)
	end if

	if rawFind is "" then
		my logLine("No .cosessiondb files found. Nothing to import.")
		my writeLog()
		return
	end if

	set sessionList to {}
	repeat with f in paragraphs of rawFind
		if (f as text) is not "" then set end of sessionList to (f as text)
	end repeat
	set totalSessions to count of sessionList
	my logLine("Sessions found: " & totalSessions)
	my logLine("")

	-- ── 3. Start ──────────────────────────────────────────────────────────
	my logLine("Starting import...")
	my logLine("")

	-- ── 4. Locate the catalog in Capture One ──────────────────
	set targetCatalog to missing value
	tell application "Capture One"
		repeat with d in documents
			if (name of d) contains pCatalogName then
				set targetCatalog to d
				exit repeat
			end if
		end repeat
	end tell

	if targetCatalog is missing value then
		set msg to "\"" & pCatalogName & "\" is not open in Capture One." & return & return & ¬
			"Open the catalog first, then re-run this script."
		my logLine("FATAL -- catalog not found among open Capture One documents.")
		my writeLog()
		return
	end if

	-- ── 5. Main import loop ────────────────────────────────────
	set successCount to 0
	set skipCount to 0
	set failCount to 0
	set sessionIndex to 0
	set batchCount to 0

	repeat with sessionDB in sessionList
		set sessionIndex to sessionIndex + 1

		set sessionFolder to do shell script "dirname " & quoted form of sessionDB

		if pMaxSessions > 0 and successCount >= pMaxSessions then
			my logLine("--- Dry-run limit reached (" & pMaxSessions & " session(s)). Set pMaxSessions to 0 to run all.")
			my writeLog()
			exit repeat
		end if

		if doneSessions contains (sessionFolder & return) then
			my logLine("--- [" & sessionIndex & "/" & totalSessions & "] SKIP (already imported): " & sessionFolder)
			set skipCount to skipCount + 1
			my writeLog()
		else
			set batchCount to batchCount + 1

			my logLine("--- [" & sessionIndex & "/" & totalSessions & "] " & sessionFolder)

			try
				set importResult to my importSessionFolder(targetCatalog, sessionFolder)
				if importResult is "no_images" then
					my logLine("    SKIP -- no raw images found in session subfolders")
					set skipCount to skipCount + 1
				else
					my logLine("    OK -- import queued")
					set successCount to successCount + 1
				end if
				my markDone(sessionFolder)
			on error errMsg number errNum
				my logLine("    FAIL -- " & errMsg & " (error " & errNum & ")")
				set failCount to failCount + 1
			end try

			my writeLog()

			if sessionIndex < totalSessions then
				delay pDelayPerSession
				if batchCount = pBatchSize then
					my logLine("")
					my logLine("=== Batch " & (sessionIndex div pBatchSize) & ¬
						" complete (" & sessionIndex & "/" & totalSessions & ¬
						") -- resting " & pBatchDelay & "s ===")
					my logLine("")
					my writeLog()
					delay pBatchDelay
					set batchCount to 0
				end if
			end if

		end if
	end repeat

	-- ── 6. Final summary ───────────────────────────────────────
	my logLine("")
	my logLine("Finished   : " & ((current date) as text))
	my logLine("Succeeded  : " & successCount)
	my logLine("Skipped    : " & skipCount)
	my logLine("Failed     : " & failCount)
	if failCount > 0 then
		my logLine("Re-run the script to retry failed sessions.")
	end if
	my logLine("Log: " & pLogPath)
	my writeLog()
end run

-- ════════════════════════════════════════════════════════════
-- importSessionFolder
--   Finds raw-image subfolders within the session and imports them.
--
--   Passing the session root to Capture One's import command causes
--   it to detect the .cosessiondb and import 0 images. Passing the
--   image subfolders directly bypasses this detection.
--
--   destination type = current location keeps files in place on disk,
--   which allows Capture One's Folders panel to mirror the archive's
--   folder structure automatically.
--
--   include existing adjustments = true tells Capture One to read
--   .cos sidecar files, preserving all edits, ratings, and metadata.
--
--   Returns "imported" on success, "no_images" if no raws found.
-- ════════════════════════════════════════════════════════════

on importSessionFolder(theDoc, sessionFolder)
	set imageFolders to my findImageFolders(sessionFolder)

	if (count of imageFolders) = 0 then
		return "no_images"
	end if

	my logLine("    Importing from " & (count of imageFolders) & " subfolder(s)...")

	using terms from application "Capture One"
		tell application "Capture One"
			tell (import settings of theDoc)
				set destination type to current location
				set destination collection to recent
				set include existing adjustments to true
				set include subfolders to true
				set exclude duplicates to true
			end tell
		end tell
	end using terms from

	try
		using terms from application "Capture One"
			tell application "Capture One"
				with timeout of pDialogProbeTimeout seconds
					import theDoc source imageFolders
				end timeout
			end tell
		end using terms from
		return "imported"
	on error probeErr number probeNum
		if probeNum is not -1712 then error probeErr number probeNum
	end try

	my logLine("    (probe timed out -- looking for dialog to dismiss...)")
	set dismissed to my dismissCaptureOneDialog()

	if not dismissed then
		error "Timed out and no dialog found -- may need manual attention" number -1712
	end if

	my logLine("    (dialog dismissed -- retrying import...)")

	using terms from application "Capture One"
		tell application "Capture One"
			with timeout of pImportTimeout seconds
				import theDoc source imageFolders
			end timeout
		end tell
	end using terms from
	return "imported"
end importSessionFolder

-- ════════════════════════════════════════════════════════════
-- findImageFolders
--   Returns subfolders of sessionFolder that contain raw files.
--   Skips Capture One internal folders and hidden/system folders.
--   Also handles sessions where raws sit directly in the root.
-- ════════════════════════════════════════════════════════════

on findImageFolders(sessionFolder)
	set skipList to {"CaptureOne", "Output", "Trash", ".~tmp~", "@eaDir", "@Recycle"}
	set rawPat to "\\( -iname '*.IIQ' -o -iname '*.CR2' -o -iname '*.CR3'" & ¬
		" -o -iname '*.NEF' -o -iname '*.ARW' -o -iname '*.DNG'" & ¬
		" -o -iname '*.RAF' -o -iname '*.ORF' -o -iname '*.RW2'" & ¬
		" -o -iname '*.PEF' -o -iname '*.SRW' \\)"
	set foundItems to {}

	set subdirsRaw to ""
	try
		set subdirsRaw to do shell script ¬
			"find " & quoted form of sessionFolder & ¬
			" -maxdepth 1 -mindepth 1 -type d 2>/dev/null"
	end try

	if subdirsRaw is not "" then
		set savedDelims to AppleScript's text item delimiters
		set AppleScript's text item delimiters to return
		set subdirs to text items of subdirsRaw
		set AppleScript's text item delimiters to savedDelims

		repeat with subdir in subdirs
			set subdirStr to subdir as text
			if subdirStr is not "" then
				set folderName to do shell script "basename " & quoted form of subdirStr
				if (folderName does not start with ".") and (folderName is not in skipList) then
					set imgCount to 0
					try
						set imgCount to (do shell script ¬
							"find " & quoted form of subdirStr & ¬
							" -maxdepth 4 " & rawPat & ¬
							" 2>/dev/null | wc -l | tr -d ' '") as integer
					end try
					if imgCount > 0 then
						set end of foundItems to subdirStr
						my logLine("      -> " & folderName & " (" & imgCount & " raw file(s))")
					end if
				end if
			end if
		end repeat
	end if

	-- Handle raws sitting directly in the session root
	set rootImgPaths to ""
	try
		set rootImgPaths to do shell script ¬
			"find " & quoted form of sessionFolder & ¬
			" -maxdepth 1 -type f " & rawPat & " 2>/dev/null"
	end try

	if rootImgPaths is not "" then
		set savedDelims to AppleScript's text item delimiters
		set AppleScript's text item delimiters to return
		set rootFiles to text items of rootImgPaths
		set AppleScript's text item delimiters to savedDelims

		set rootCount to 0
		repeat with f in rootFiles
			set fStr to f as text
			if fStr is not "" then
				set end of foundItems to fStr
				set rootCount to rootCount + 1
			end if
		end repeat
		if rootCount > 0 then
			my logLine("      -> (root level) " & rootCount & " raw file(s)")
		end if
	end if

	return foundItems
end findImageFolders

-- ════════════════════════════════════════════════════════════
-- dismissCaptureOneDialog
--   Polls Capture One for any modal dialog and clicks the first
--   affirmative button. Used to handle upgrade/warning dialogs
--   on old sessions. Returns true if a dialog was dismissed.
-- ════════════════════════════════════════════════════════════

on dismissCaptureOneDialog()
	set coProcess to missing value
	tell application "System Events"
		set candidates to every process whose name starts with "Capture One"
		if (count of candidates) > 0 then set coProcess to item 1 of candidates
	end tell
	if coProcess is missing value then return false

	set affirmativeLabels to {"Upgrade", "Update", "OK", "Yes", ¬
		"Continue", "Proceed", "Allow", "Open", "Convert"}

	repeat pDialogPollSeconds times
		try
			tell application "System Events"
				tell coProcess
					try
						set frontWin to window 1
						if exists (sheet 1 of frontWin) then
							set theSheet to sheet 1 of frontWin
							repeat with btn in buttons of theSheet
								if name of btn is in affirmativeLabels then
									click btn
									delay 1
									return true
								end if
							end repeat
							try
								keystroke return
								delay 1
								return true
							end try
						end if
					end try
					repeat with w in windows
						try
							set wRole to role of w
							if wRole is "AXSheet" or wRole is "AXWindow" then
								repeat with btn in buttons of w
									if name of btn is in affirmativeLabels then
										click btn
										delay 1
										return true
									end if
								end repeat
								try
									keystroke return
									delay 1
									return true
								end try
							end if
						end try
					end repeat
				end tell
			end tell
		end try
		delay 1
	end repeat

	return false
end dismissCaptureOneDialog

-- ════════════════════════════════════════════════════════════
-- LOGGING
-- ════════════════════════════════════════════════════════════

on logLine(msg)
	set gLog to gLog & msg & return
end logLine

on writeLog()
	try
		set fRef to open for access (POSIX file pLogPath) with write permission
		set eof of fRef to 0
		write gLog to fRef
		close access fRef
	on error
		try
			close access (POSIX file pLogPath)
		end try
	end try
end writeLog

-- ════════════════════════════════════════════════════════════
-- RESUME HANDLERS
-- ════════════════════════════════════════════════════════════

on loadDoneSessions()
	try
		return (do shell script "cat " & quoted form of pResumePath & " 2>/dev/null") & return
	on error
		return ""
	end try
end loadDoneSessions

on markDone(sessionFolder)
	try
		set fRef to open for access (POSIX file pResumePath) with write permission
		write (sessionFolder & return) to fRef starting at ((get eof fRef) + 1)
		close access fRef
	on error
		try
			close access (POSIX file pResumePath)
		end try
	end try
end markDone

on writePreflight(upgradeList, total)
	set pfText to "=== Capture One Pre-flight Report ===" & return
	set pfText to pfText & "Generated : " & ((current date) as text) & return
	set pfText to pfText & "Total sessions scanned : " & total & return & return
	try
		set fRef to open for access (POSIX file pPreflightLog) with write permission
		set eof of fRef to 0
		write pfText to fRef
		close access fRef
	on error
		try
			close access (POSIX file pPreflightLog)
		end try
	end try
end writePreflight
