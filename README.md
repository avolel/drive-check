# drive-check

A PowerShell helper for safely unplugging USB drives on Windows. It also diagnoses and repairs drives that have stopped showing up.

The script lists the connected USB drives and lets you pick one. It then checks that no process has the drive open, flushes the write cache, and tells you when it is safe to unplug.

## Why this exists

Many USB enclosures, such as the WD Gaming Drive, tell Windows at the firmware level that they are **non-removable** (the SCSI RMB bit is clear). As a result:

- Explorer shows no **Eject** option for the drive.
- **Safely Remove Hardware** refuses with *"device is not removable"*.

These drives usually run with removal policy 3 (*quick removal*). Write caching is off, so every write is committed as soon as it is issued. The correct way to remove one is to flush the filesystem metadata, confirm that nothing has the volume open, and then pull the cable. This script does those steps for you.

> **Don't "eject" with `Disable-PnpDevice` or `Set-Disk -IsOffline`.**
> Both changes are saved against the device. They survive unplugging and rebooting, and the drive stays invisible until you undo them. If that has already happened, use `-Repair`.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 or PowerShell 7+
- An administrator session for `-Repair`. Everything else runs without elevation.

## Usage

```powershell
# Pick a USB drive from a menu and prepare it for unplugging
.\eject-h.ps1

# Prepare a specific drive without the menu (useful for shortcuts)
.\eject-h.ps1 -DriveLetter H

# Skip the open-handle scan (it takes about 2-5 seconds)
.\eject-h.ps1 -DriveLetter H -SkipHandleScan

# Diagnose a drive that is plugged in but not showing up (read-only)
.\eject-h.ps1 -Status

# Undo a persistent PnP disable or disk offline (run as Administrator)
.\eject-h.ps1 -Repair
```

If script execution is blocked, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\eject-h.ps1
```

### Parameters

| Parameter         | Description                                                                                         |
|-------------------|-----------------------------------------------------------------------------------------------------|
| *(none)*          | Eject mode: list mounted USB drives, check for open handles, flush the cache, report when safe.    |
| `-DriveLetter X`  | Select the drive by letter instead of from the menu.                                                |
| `-SkipHandleScan` | Eject mode only. Skip the open-handle scan.                                                         |
| `-Status`         | Report the state of the USB device, the disk and the volume. Makes no changes.                      |
| `-Repair`         | Clear `CM_PROB_DISABLED` (PnP disable) and `OfflineReason=Policy` (disk offline). Needs elevation.  |

## What each mode does

### Eject (default)

1. Lists mounted USB drives. Drives with several lettered partitions are handled as one drive.
2. Scans the system handle table (`NtQuerySystemInformation`) for files open on the drive and lists the processes holding them. Without elevation the scan only sees your own processes. Those are the ones that matter, because Defender and the search indexer cope with surprise removal.
3. Runs `Write-VolumeCache` on every volume of the drive.
4. Reports **SAFE TO UNPLUG**, or lists the processes you need to close first.

### Status

Checks the drive in three layers and stops at the first one that fails:

- **Device stack:** whether the USB device is present, and whether it has a PnP problem such as being disabled.
- **Disk:** whether the disk is online, its health, and its removal policy (write cache on or off).
- **Volume:** whether it has a drive letter, plus its filesystem, health and free space.

`-Status` also lists drives that `Get-Disk` cannot see, such as disabled USB storage devices that never produce a disk. It suggests a fix for each problem it finds.

### Repair

1. Re-enables the USB device if it has been disabled through PnP.
2. Brings the disk back online if it is offline.
3. Runs the `-Status` checks to confirm the result.

## Removal policies

| Policy | Meaning                               | Write cache | How to remove                       |
|--------|---------------------------------------|-------------|-------------------------------------|
| 1      | Expect no removal                     | –           | –                                   |
| 2      | Orderly removal ("Better performance") | On          | Flush, then unplug straight away    |
| 3      | Surprise removal ("Quick removal")    | Off         | Flush, then unplug                  |

## Supported drivers

The script recognises drives that use either USB mass-storage driver:

- `USBSTOR`: Bulk-Only Transport
- `UASPStor`: USB Attached SCSI, which most modern SSD and HDD enclosures use
