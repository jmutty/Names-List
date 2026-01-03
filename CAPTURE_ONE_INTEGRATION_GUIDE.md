# Capture One Integration Guide

## Overview

Your Names List app now integrates directly with Capture One, eliminating the need for copy/paste workflows. The app will automatically detect if Capture One is running and communicate with it via AppleScript.

## Features

### CSV Mode Integration
- **What it does**: When you click a name in CSV mode, the app sends a tab-delimited payload to Capture One: `Group_First Name Last Name_<TAB>Barcode` (or `Manual Sort_First Name Last Name_<TAB>Barcode` when Group is empty or "No Group"). The AppleScript then sets:
  - "Capture Name" = `Group_First Name Last Name` (or `Manual Sort_First Name Last Name`)
  - "Next Capture Metadata" → "Copyright Notice" = `Barcode`
- **Buddy mode**: The app sends `Group_Buddy_<TAB>Barcode1,Barcode2` (or `Manual Sort_Buddy_<TAB>Barcode1,Barcode2` when Group is empty or "No Group") so the name updates appropriately and the metadata contains all barcodes.
- **Fallback**: Still copies to clipboard if Capture One is not running or if there's an error

### Manual Mode Integration  
- **What it does**: When you click the main action button in Manual mode, the generated name is automatically set in Capture One's "Capture Name Format" field
- **Fallback**: Still copies to clipboard if Capture One is not running or if there's an error

## How to Use

### Setup
1. **Open Capture One** first (the app name should be exactly "Capture One")
2. **Open a document/session** in Capture One
3. **Launch Names List app**
4. The app will show a connection status indicator at the top of each mode

### CSV Mode Workflow
1. Load your CSV file as usual
2. Verify "Capture One Connected" status shows green checkmark
3. Click any name - the barcode will be automatically set in Capture One's copyright notice field
4. Take your photo - the copyright notice will be embedded automatically

### Manual Mode Workflow
1. Set up your teams as usual
2. Verify "Capture One Connected" status shows green checkmark  
3. Click the main action button - the name format will be automatically set in Capture One
4. Take your photo - it will be named according to the format you set

## Status Indicators

- **Green checkmark**: "Capture One Connected" - Integration is working
- **Orange triangle**: "Capture One Not Running" - App not detected, will use clipboard fallback
- **Error messages**: Displayed in red if there are communication issues

## Troubleshooting

### Connection Issues
- Make sure Capture One is running and has a document/session open
- Click the "Refresh" button to re-check connection
- Restart both applications if needed

### AppleScript Permissions
- macOS may ask for permission to control Capture One
- Grant the permission when prompted
- If denied, go to System Preferences → Security & Privacy → Privacy → Automation and enable Names List to control Capture One

### Capture One Requirements
- Must have a document/session open (not just the application)
- Works with both Session and Catalog documents
- Tested with Capture One Pro (should work with other versions)

## Technical Details

### CSV Mode - Name + Barcode
The integration sets both:
- `capture name` of the current document to the literal text `Group_First Name Last Name_` (or `Manual Sort_First Name Last Name_` when Group is empty or "No Group")
- `status copyright notice` of the `next capture settings` to the subject's `Barcode`

This means:
- Every new capture will be named exactly as provided and will embed the barcode in metadata
- The setting persists until you change it
- Works with all supported camera types

### Manual Mode - Capture Name Format
The integration sets the `capture name format` property of the current document. This means:
- Every new capture will follow the naming pattern you set
- You can use Capture One's token system (the app sets the literal text)
- The format persists until you change it

## Benefits

1. **No more copy/paste**: Direct integration eliminates manual steps
2. **Faster workflow**: One click sets everything up in Capture One
3. **Fewer errors**: No risk of forgetting to paste or pasting wrong content
4. **Seamless experience**: Works transparently with your existing workflow
5. **Fallback safety**: Still works if Capture One isn't available

## AppleScript Setup (Required)

To enable the CSV Mode behavior described above, install/update the following AppleScript file:

- Path: `~/Library/Scripts/Capture One Scripts/CSV Data.scpt`

Script contents:

```applescript
-- CSV Data.scpt
set clip to the clipboard as text
set nameValue to ""
set barcodeValue to ""

set AppleScript's text item delimiters to {tab}
set parts to text items of clip
set AppleScript's text item delimiters to {""}

if (count of parts) ≥ 2 then
    set nameValue to item 1 of parts
    set barcodeValue to item 2 of parts
else
    -- Backward compatibility: barcode-only
    set barcodeValue to clip
end if

tell application "Capture One"
    try
        if nameValue is not "" then
            tell current document to set capture name to nameValue
        end if
        if barcodeValue is not "" then
            tell (next capture settings of current document) to set status copyright notice to barcodeValue
        end if
    on error errMsg
        -- Silent fail to avoid blocking
    end try
end tell
```

Notes:
- The script is backward-compatible: if the clipboard contains no tab, it treats the value as a raw barcode and updates only the copyright field (legacy behavior).
- Ensure the folder path exists; you may need to create `Capture One Scripts`.

## Support

If you encounter issues:
1. Check the connection status indicator
2. Look for error messages in the app
3. Verify Capture One has a document open
4. Check macOS privacy permissions for automation
5. Try the "Refresh" button to reconnect

The integration maintains full backward compatibility - if Capture One isn't available, the app works exactly as before with clipboard copying.
