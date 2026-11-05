<#
.SYNOPSIS
    Safe mount/unmount helper for USB drives.

.DESCRIPTION
    Lists the USB drives connected to the computer, lets you pick one, checks
    that nothing holds it open, flushes its write cache, and tells you when it
    is safe to unplug.

    Many USB enclosures (e.g. WD Gaming Drive) report themselves NON-REMOVABLE
    at the firmware level (SCSI RMB bit clear), so the USBSTOR disk device
    exposes no Removable capability. Consequences:

      * Explorer shows no Eject verb on the drive.
      * Safely Remove Hardware refuses with "device is not removable".

    With removal policy 3 (expect surprise removal) write caching is DISABLED
    and every write commits as it is issued. The correct removal procedure is
    therefore: flush the metadata buffer, confirm nothing holds the volume,
    then physically unplug.

    Do NOT use Disable-PnpDevice or Set-Disk -IsOffline as an "eject". Both are
    persistent state changes keyed to the device, they survive replug and
    reboot, and they leave the drive invisible until explicitly undone.
    Use -Repair below if that has already happened.

.PARAMETER Status
    Report the health of the device stack, disk and volume. Read-only.

.PARAMETER Repair
    Clear the two sticky states that make a drive vanish:
    CM_PROB_DISABLED (PnP disable) and OfflineReason=Policy (disk offline).
    Requires an elevated session.

.PARAMETER SkipHandleScan
    Skip the open-handle enumeration (the slow part, ~2-5s).

.PARAMETER DriveLetter
    Pick the drive by letter instead of choosing from the menu.

.EXAMPLE
    .\eject-h.ps1
    Choose a USB drive and prepare it for unplugging.

.EXAMPLE
    .\eject-h.ps1 -DriveLetter H
    Prepare H: for unplugging without showing the menu.

.EXAMPLE
    .\eject-h.ps1 -Status
    Diagnose why a drive is not showing up.

.EXAMPLE
    .\eject-h.ps1 -Repair
    Undo a persistent disable / offline. Run elevated.
#>
[CmdletBinding(DefaultParameterSetName = 'Eject')]
param(
    [Parameter(ParameterSetName = 'Status')] [switch] $Status,
    [Parameter(ParameterSetName = 'Repair')] [switch] $Repair,
    [Parameter(ParameterSetName = 'Eject')]  [switch] $SkipHandleScan,
    [string] $DriveLetter
)

$ErrorActionPreference = 'Stop'

# Drivers that bind USB mass-storage devices: USBSTOR is the classic
# Bulk-Only Transport driver, UASPStor the USB Attached SCSI driver used by
# most modern SSD/HDD enclosures.
$UsbStorageServices = 'USBSTOR', 'UASPStor'

function Write-Head($t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Ok      ($t) { Write-Host "   [ ok ] $t" -ForegroundColor Green }
function Warn    ($t) { Write-Host "   [warn] $t" -ForegroundColor Yellow }
function Bad     ($t) { Write-Host "   [fail] $t" -ForegroundColor Red }
function Info    ($t) { Write-Host "          $t" -ForegroundColor DarkGray }

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ------------------------------------------------------------ drive discovery
# Disk.Path is the device interface path, e.g.
#   \\?\usbstor#disk&ven_wd&prod_...#serial&0#{53f56307-...}
# which maps to the PnP instance id USBSTOR\DISK&VEN_WD&PROD_...\SERIAL&0.
function ConvertTo-InstanceId([string] $Path) {
    ($Path -replace '^\\\\\?\\', '' -replace '#\{[^}]+\}$', '') -replace '#', '\'
}

# Walks up from the disk device to the USB mass-storage device it hangs off.
# For USBSTOR the disk's direct parent is the USB device; for UAS there is a
# SCSI adapter in between, so take the first ancestor in the USB\ namespace.
# The depth cap stops a malformed tree from looping forever.
function Get-UsbParent([string] $InstanceId) {
    $id = $InstanceId
    for ($i = 0; $i -lt 8 -and $id; $i++) {
        try { $id = (Get-PnpDeviceProperty -InstanceId $id -KeyName DEVPKEY_Device_Parent).Data }
        catch { return $null }
        if ($id -like 'USB\*') { return $id }
    }
    $null
}

# 1 = expect no removal, 2 = orderly removal (write cache on, "better
# performance"), 3 = surprise removal (write cache off, "quick removal").
# 0 means the property could not be read.
function Get-RemovalPolicy([string] $InstanceId) {
    try { [int] (Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName DEVPKEY_Device_RemovalPolicy).Data }
    catch { 0 }
}

# One entry per physical USB drive. Includes offline disks, disks without a
# drive letter, and present-but-disabled USB storage devices (no disk at all),
# so -Status and -Repair can still find a drive that has "vanished".
function Get-UsbDrive {
    $drives = @()
    foreach ($disk in @(Get-Disk | Where-Object BusType -eq 'USB')) {
        $diskId  = ConvertTo-InstanceId $disk.Path
        # A drive can carry several lettered partitions; unplugging takes all
        # of them, so every one is scanned and flushed. Partitions without a
        # letter report DriveLetter as [char]0, hence the regex test.
        $letters = @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
                     Where-Object { "$($_.DriveLetter)" -match '^[A-Za-z]$' } |
                     ForEach-Object { "$($_.DriveLetter)".ToUpper() })
        $labels  = @($letters | ForEach-Object {
            $v = Get-Volume -DriveLetter $_ -ErrorAction SilentlyContinue
            if ($v -and $v.FileSystemLabel) { "$($_): $($v.FileSystemLabel)" } else { "$($_):" }
        })
        $state = if ($disk.IsOffline) { 'offline' } elseif (-not $letters) { 'no drive letter' } else { 'ok' }
        $drives += [pscustomobject]@{
            Name          = $disk.FriendlyName
            Disk          = $disk
            DiskId        = $diskId
            UsbInstanceId = Get-UsbParent $diskId
            Letters       = $letters
            Display       = if ($labels) { $labels -join ', ' } else { '-' }
            State         = $state
        }
    }

    # A disabled USB device never produces a disk, so Get-Disk cannot see it.
    # Pick up any present USB storage device not already matched to a disk.
    # -PresentOnly drops phantom entries left behind by past plug-ins.
    $known = @($drives.UsbInstanceId)
    foreach ($usb in @(Get-PnpDevice -PresentOnly |
            Where-Object { $_.InstanceId -like 'USB\*' -and $_.Service -in $UsbStorageServices })) {
        if ($known -contains $usb.InstanceId) { continue }
        $drives += [pscustomobject]@{
            Name          = $usb.FriendlyName
            Disk          = $null
            DiskId        = $null
            UsbInstanceId = $usb.InstanceId
            Letters       = @()
            Display       = '-'
            State         = "device $($usb.Problem)"
        }
    }
    $drives
}

# Returns the drive to act on, or $null if there is none or the user quits.
# -DriveLetter bypasses the menu for scripted / shortcut use.
function Select-UsbDrive {
    param([object[]] $Drives)

    if ($DriveLetter) {
        $letter = $DriveLetter.TrimEnd(':', '\').ToUpper()
        $hit = $Drives | Where-Object { $_.Letters -contains $letter } | Select-Object -First 1
        if (-not $hit) { Bad "$($letter): is not a USB drive connected to this computer." }
        return $hit
    }

    if (-not $Drives) {
        Bad 'No USB drives found.'
        Info 'Run with -Status to diagnose a drive that is plugged in but not showing up.'
        return $null
    }

    Write-Head 'USB drives'
    for ($i = 0; $i -lt $Drives.Count; $i++) {
        $d = $Drives[$i]
        $size = if ($d.Disk) { '{0:N0} GB' -f ($d.Disk.Size / 1GB) } else { '-' }
        Write-Host ('   [{0}] {1,-24} {2,-28} {3,10}  {4}' -f ($i + 1), $d.Display, $d.Name, $size, $d.State)
    }
    Write-Host ''

    # With a single drive, Enter accepts it; with several, require a choice
    # so the wrong drive is never picked by accident.
    $default = if ($Drives.Count -eq 1) { '1' } else { '' }
    $prompt  = if ($default) { 'Select drive [1], q to quit' } else { "Select drive (1-$($Drives.Count)), q to quit" }
    while ($true) {
        $answer = (Read-Host "   $prompt").Trim()
        if (-not $answer) { $answer = $default }
        if ($answer -eq 'q') { return $null }
        $n = 0
        if ([int]::TryParse($answer, [ref] $n) -and $n -ge 1 -and $n -le $Drives.Count) {
            return $Drives[$n - 1]
        }
        Warn "Enter a number between 1 and $($Drives.Count)."
    }
}

# ---------------------------------------------------------------- handle scan
# Enumerates every file handle on the system via NtQuerySystemInformation and
# resolves the ones we have rights to duplicate. Only reports hits on the
# given drive letters.
# Without elevation this covers same-user processes, which is what matters:
# Defender and the search indexer release files as they go and tolerate
# surprise removal.
function Get-DriveHandle {
    param([string[]] $Letters)

    if (-not ('HQ' -as [type])) {
        Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public class HQ {
    [DllImport("ntdll.dll")]
    static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool DuplicateHandle(IntPtr sp, IntPtr sh, IntPtr tp, out IntPtr th, int acc, bool inh, int opt);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
    static extern int GetFinalPathNameByHandle(IntPtr h, StringBuilder sb, int len, int flags);
    [DllImport("kernel32.dll")]
    static extern int GetFileType(IntPtr h);

    [StructLayout(LayoutKind.Sequential)]
    struct ENTRY {
        public IntPtr Object;
        public IntPtr UniqueProcessId;
        public IntPtr HandleValue;
        public uint   GrantedAccess;
        public ushort CreatorBackTraceIndex;
        public ushort ObjectTypeIndex;
        public uint   HandleAttributes;
        public uint   Reserved;
    }

    public static List<string> Run() {
        var res = new List<string>();
        int len = 1 << 22, ret, status;
        IntPtr buf;
        while (true) {
            buf = Marshal.AllocHGlobal(len);
            status = NtQuerySystemInformation(64, buf, len, out ret);
            if (status == unchecked((int)0xC0000004)) { Marshal.FreeHGlobal(buf); len *= 2; continue; }
            break;
        }
        if (status != 0) return res;

        long count = Marshal.ReadIntPtr(buf).ToInt64();
        int  esz   = Marshal.SizeOf(typeof(ENTRY));
        IntPtr bas = new IntPtr(buf.ToInt64() + IntPtr.Size * 2);
        var cache  = new Dictionary<int, IntPtr>();
        var sb     = new StringBuilder(1024);

        for (long i = 0; i < count; i++) {
            var e = (ENTRY)Marshal.PtrToStructure(new IntPtr(bas.ToInt64() + i * esz), typeof(ENTRY));
            int pid = e.UniqueProcessId.ToInt32();
            if (pid <= 4) continue;

            IntPtr ph;
            if (!cache.TryGetValue(pid, out ph)) {
                ph = OpenProcess(0x0040 | 0x1000, false, pid);   // DUP_HANDLE | QUERY_LIMITED
                cache[pid] = ph;
            }
            if (ph == IntPtr.Zero) continue;

            IntPtr dup;
            if (!DuplicateHandle(ph, e.HandleValue, GetCurrentProcess(), out dup, 0, false, 2)) continue;
            try {
                if (GetFileType(dup) != 1) continue;             // FILE_TYPE_DISK
                sb.Length = 0; sb.EnsureCapacity(1024);
                if (GetFinalPathNameByHandle(dup, sb, 1023, 0) > 0)
                    res.Add(pid + "|" + sb.ToString());
            } finally { CloseHandle(dup); }
        }
        return res;
    }
}
'@
    }

    $prefixes = $Letters | ForEach-Object { '\\?\' + $_ + ':' }
    foreach ($hit in [HQ]::Run()) {
        $parts = $hit -split '\|', 2
        if ($parts.Count -ne 2) { continue }
        $path = $parts[1]
        if (-not ($prefixes | Where-Object { $path.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) })) { continue }
        $procId = [int] $parts[0]
        $procName = '?'
        try { $procName = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { }
        [pscustomobject]@{
            PID     = $procId
            Process = $procName
            Path    = $path
        }
    }
}

# -------------------------------------------------------------------- status
function Show-Status {
    param([object] $Drive)

    Write-Head "Device stack - $($Drive.Name)"
    if (-not $Drive.UsbInstanceId) {
        Warn 'Could not locate the parent USB device; skipping this check.'
    }
    else {
        $usb = Get-PnpDevice -InstanceId $Drive.UsbInstanceId -ErrorAction SilentlyContinue
        if (-not $usb -or "$($usb.Problem)" -match 'PHANTOM') {
            Bad 'USB device not present - drive is unplugged, or the cable/port is dead.'
            return $false
        }
        elseif ($usb.Problem -eq 'CM_PROB_NONE') {
            Ok "$($usb.FriendlyName): $($usb.Status)"
            Info $Drive.UsbInstanceId
        }
        else {
            Bad "USB device problem: $($usb.Problem)"
            if ("$($usb.Problem)" -match 'DISABLED') {
                Info 'A PnP disable is persisted in ConfigFlags. Fix: run this script with -Repair (elevated).'
            }
            return $false
        }
    }

    Write-Head 'Disk'
    $disk = $Drive.Disk
    if (-not $disk) { Bad 'No disk enumerated for this USB device.'; return $false }
    Info "disk $($disk.Number)  $($disk.FriendlyName)  $($disk.BusType)  $([math]::Round($disk.Size/1TB,2)) TB"
    if ($disk.IsOffline) {
        Bad "Disk is OFFLINE (reason: $($disk.OfflineReason))"
        Info 'Fix: run this script with -Repair (elevated).'
        return $false
    }
    Ok "Online, health $($disk.HealthStatus), read-only: $($disk.IsReadOnly)"
    $policy = Get-RemovalPolicy $Drive.DiskId
    switch ($policy) {
        3       { Info 'Removal policy 3 (surprise removal): write caching off.' }
        2       { Info 'Removal policy 2 (orderly removal): write caching on.' }
        1       { Info 'Removal policy 1 (expect no removal).' }
        default { Info 'Removal policy unknown.' }
    }

    Write-Head 'Volume'
    if (-not $Drive.Letters) {
        Bad 'No drive letter, though the disk is online.'
        Info 'The partition is intact; only the drive letter is missing. Assign one with:'
        Info "  Get-Partition -DiskNumber $($disk.Number) | Where-Object Type -in 'IFS','Basic' | Add-PartitionAccessPath -AssignDriveLetter"
        return $false
    }
    foreach ($letter in $Drive.Letters) {
        $vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
        if (-not $vol) { Bad "$($letter): has no volume."; continue }
        Ok "$($letter): $($vol.FileSystem)  $($vol.OperationalStatus)  health $($vol.HealthStatus)"
        if ($vol.Size) {
            $usedPct = [math]::Round((($vol.Size - $vol.SizeRemaining) / $vol.Size) * 100, 1)
            Info ("{0:N0} GB free of {1:N0} GB ({2}% used)" -f ($vol.SizeRemaining/1GB), ($vol.Size/1GB), $usedPct)
        }
    }
    return $true
}

# -------------------------------------------------------------------- repair
function Invoke-Repair {
    param([object] $Drive)

    if (-not (Test-Elevated)) {
        Bad 'Repair needs an elevated session.'
        Info 'Open Windows Terminal as Administrator (Win+X -> Terminal (Admin)) and re-run.'
        return
    }

    Write-Head 'Clearing persistent PnP disable'
    $usb = if ($Drive.UsbInstanceId) { Get-PnpDevice -InstanceId $Drive.UsbInstanceId -ErrorAction SilentlyContinue }
    if (-not $usb) {
        Warn 'USB device not present - plug the drive in first.'
    }
    elseif ("$($usb.Problem)" -match 'DISABLED') {
        Enable-PnpDevice -InstanceId $Drive.UsbInstanceId -Confirm:$false
        Ok 'Enable-PnpDevice issued.'
        Start-Sleep -Seconds 3
    }
    else { Ok "Nothing to clear (status: $($usb.Status))." }

    # Re-enumerate: the disk only appears once the USB device is enabled.
    $fresh = @(Get-UsbDrive) | Where-Object { $_.UsbInstanceId -and $_.UsbInstanceId -eq $Drive.UsbInstanceId } |
             Select-Object -First 1
    if ($fresh) { $Drive = $fresh }

    Write-Head 'Clearing persistent disk offline'
    $disk = $Drive.Disk
    if (-not $disk) {
        Warn 'Disk not enumerated yet.'
    }
    elseif ($disk.IsOffline) {
        Set-Disk -Number $disk.Number -IsOffline $false
        Ok 'Set-Disk -IsOffline $false issued.'
        Start-Sleep -Seconds 2
        $fresh = @(Get-UsbDrive) | Where-Object { $_.DiskId -eq $Drive.DiskId } | Select-Object -First 1
        if ($fresh) { $Drive = $fresh }
    }
    else { Ok 'Disk already online.' }

    [void](Show-Status $Drive)
}

# --------------------------------------------------------------------- eject
function Invoke-SafeRemove {
    param([object] $Drive)

    $letters = $Drive.Letters
    $names   = ($letters | ForEach-Object { "$($_):" }) -join ', '
    if (-not $letters -or ($Drive.Disk -and $Drive.Disk.IsOffline)) {
        Bad "$($Drive.Name) is not mounted - nothing to remove."
        Info 'Run with -Status to find out why.'
        return
    }

    $blockers = @()
    if (-not $SkipHandleScan) {
        Write-Head 'Checking for open handles'
        Info 'Scanning system handle table...'
        $blockers = @(Get-DriveHandle -Letters $letters)
        if ($blockers.Count -eq 0) {
            Ok "No accessible process holds a handle on $names"
        }
        else {
            Warn "$($blockers.Count) open handle(s) on $($names):"
            $blockers | Group-Object Process | Sort-Object Count -Descending |
                ForEach-Object { Info ("{0,-24} {1} handle(s)" -f $_.Name, $_.Count) }
            Info ''
            Info 'Close these before unplugging (Explorer windows, editors, media players).'
        }
    }

    Write-Head 'Flushing write cache'
    foreach ($letter in $letters) { Write-VolumeCache -DriveLetter $letter }
    Ok 'Filesystem metadata committed to disk.'

    Write-Head 'Result'
    if ($blockers.Count -gt 0) {
        Warn 'Safe to unplug once you close the processes listed above.'
    }
    else {
        Ok  "SAFE TO UNPLUG $names now."
        switch (Get-RemovalPolicy $Drive.DiskId) {
            3 {
                Info 'Removal policy is 3 (surprise removal): write caching is off, so'
                Info 'pulling the cable is the supported procedure for this drive.'
                Info 'If Safely Remove Hardware refuses it, that is expected,'
                Info 'not a fault. See the notes at the top of this script.'
            }
            2 {
                Info 'Removal policy is 2 (better performance): write caching is on.'
                Info 'The cache was just flushed - unplug now, before anything writes again.'
            }
        }
    }
}

# Eject only offers drives that are mounted; -Status and -Repair list every
# USB drive, since their job is to find the ones that are not.
$drives = @(Get-UsbDrive)
if ($PSCmdlet.ParameterSetName -eq 'Eject') {
    $drives = @($drives | Where-Object { $_.Letters -and $_.Disk -and -not $_.Disk.IsOffline })
}
$drive = Select-UsbDrive -Drives $drives
if ($drive) {
    switch ($PSCmdlet.ParameterSetName) {
        'Status' { [void](Show-Status $drive) }
        'Repair' { Invoke-Repair $drive }
        default  { Invoke-SafeRemove $drive }
    }
}
Write-Host ''
