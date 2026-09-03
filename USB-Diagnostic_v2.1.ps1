#requires -Version 5.1

<#
USB FLASH DRIVE DIAGNOSTIC TOOL
Version 2.1

Non-destructive by default.

Usage:

    .\USB-Diagnostic_v2.ps1

    .\USB-Diagnostic_v2.ps1 -DriveLetter D

    .\USB-Diagnostic_v2.ps1 -DriveLetter D -WriteTest

    .\USB-Diagnostic_v2.ps1 -DriveLetter D -WriteTest -TestSizeMB 100

    .\USB-Diagnostic_v2.ps1 -DriveLetter D -WriteTest -AttemptClearReadOnly

IMPORTANT:
    - Normal diagnostic mode does not modify the drive.
    - -WriteTest writes temporary test data and reads it back.
    - -AttemptClearReadOnly modifies Windows disk metadata.
    - Write-test failures are classified before affecting the final verdict.
#>

param(
    [ValidatePattern("^[A-Za-z]$")]
    [string]$DriveLetter,

    [switch]$WriteTest,

    [ValidateRange(1, 2048)]
    [int]$TestSizeMB = 20,

    [switch]$AttemptClearReadOnly
)

$ErrorActionPreference = "Continue"

# ============================================================
# STATE
# ============================================================

$script:Results = @()

$script:Disk = $null
$script:Partition = $null
$script:Volume = $null

$script:SoftwareReadOnly = $false
$script:DiskPartReadOnly = $false
$script:VolumeReadOnly = $false

$script:FilesystemProblem = $false
$script:StorageErrors = $false
$script:PnpErrors = $false

$script:WriteFailed = $false
$script:ReadFailed = $false
$script:HashMismatch = $false
$script:WritePassed = $false

$script:WriteTestAttempted = $false
$script:WriteTestCancelled = $false
$script:TestInfrastructureFailed = $false

$script:WriteFailureClass = $null
$script:WriteFailureMessage = $null

$script:ReliabilityAvailable = $false
$script:HardwareWarning = $false

# ============================================================
# OUTPUT
# ============================================================

function Add-Result {
    param(
        [string]$Test,

        [ValidateSet("PASS","WARN","FAIL","INFO")]
        [string]$Status,

        [string]$Message
    )

    $script:Results += [PSCustomObject]@{
        Test    = $Test
        Status  = $Status
        Message = $Message
    }

    switch ($Status) {

        "PASS" {
            Write-Host "[PASS] $Test" -ForegroundColor Green
            Write-Host "       $Message"
        }

        "WARN" {
            Write-Host "[WARN] $Test" -ForegroundColor Yellow
            Write-Host "       $Message"
        }

        "FAIL" {
            Write-Host "[FAIL] $Test" -ForegroundColor Red
            Write-Host "       $Message"
        }

        "INFO" {
            Write-Host "[INFO] $Test" -ForegroundColor Cyan
            Write-Host "       $Message"
        }
    }
}

function Section {
    param([string]$Title)

    Write-Host ""
    Write-Host "============================================================" `
        -ForegroundColor Cyan

    Write-Host " $Title" -ForegroundColor Cyan

    Write-Host "============================================================" `
        -ForegroundColor Cyan
}

# ============================================================
# WRITE ERROR CLASSIFICATION
# ============================================================

function Classify-WriteError {

    param(
        [System.Exception]$Exception
    )

    $message = $Exception.Message

    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = $Exception.ToString()
    }

    $lower = $message.ToLowerInvariant()

    # --------------------------------------------------------
    # ACCESS / WRITE PROTECTION
    # --------------------------------------------------------

    if (
        $lower -match "write protected" -or
        $lower -match "write-protected" -or
        $lower -match "media is write protected" -or
        $lower -match "access is denied" -or
        $lower -match "access denied"
    ) {

        return "WRITE_PROTECTED"
    }

    # --------------------------------------------------------
    # DEVICE NOT READY / REMOVED
    # --------------------------------------------------------

    if (
        $lower -match "device is not ready" -or
        $lower -match "device not ready" -or
        $lower -match "device attached to the system is not functioning" -or
        $lower -match "device does not recognize the command" -or
        $lower -match "device has been removed"
    ) {

        return "DEVICE_ERROR"
    }

    # --------------------------------------------------------
    # I/O / MEDIA ERROR
    # --------------------------------------------------------

    if (
        $lower -match "i/o error" -or
        $lower -match "io error" -or
        $lower -match "input/output" -or
        $lower -match "data error" -or
        $lower -match "cyclic redundancy check" -or
        $lower -match "media error" -or
        $lower -match "hardware error"
    ) {

        return "MEDIA_ERROR"
    }

    # --------------------------------------------------------
    # PATH / TEST INFRASTRUCTURE
    # --------------------------------------------------------

    if (
        $lower -match "could not find a part of the path" -or
        $lower -match "path not found" -or
        $lower -match "directory not found" -or
        $lower -match "cannot find path"
    ) {

        return "PATH_ERROR"
    }

    # --------------------------------------------------------
    # DISK FULL
    # --------------------------------------------------------

    if (
        $lower -match "not enough space" -or
        $lower -match "insufficient disk space" -or
        $lower -match "there is not enough space"
    ) {

        return "NO_SPACE"
    }

    # --------------------------------------------------------
    # FILESYSTEM
    # --------------------------------------------------------

    if (
        $lower -match "file system" -or
        $lower -match "filesystem" -or
        $lower -match "directory" -and $lower -match "corrupt"
    ) {

        return "FILESYSTEM_ERROR"
    }

    # --------------------------------------------------------
    # UNKNOWN
    # --------------------------------------------------------

    return "UNKNOWN"
}

# ============================================================
# ADMIN CHECK
# ============================================================

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()

$principal = New-Object Security.Principal.WindowsPrincipal($identity)

$isAdmin = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if ($isAdmin) {

    Add-Result "Administrator privileges" "PASS" `
        "Running as Administrator."
}
else {

    Add-Result "Administrator privileges" "WARN" `
        "Not running as Administrator. Some tests may be incomplete."
}

# ============================================================
# DRIVE SELECTION
# ============================================================

if (-not $DriveLetter) {

    Section "REMOVABLE DRIVES"

    $removable = Get-CimInstance Win32_LogicalDisk |
        Where-Object {
            $_.DriveType -eq 2
        }

    if (-not $removable) {

        Write-Host "No removable drives detected." `
            -ForegroundColor Red

        exit 1
    }

    foreach ($d in $removable) {

        $size = if ($d.Size) {

            "{0:N2} GB" -f ($d.Size / 1GB)

        }
        else {

            "Unknown"
        }

        Write-Host "$($d.DeviceID)  $($d.VolumeName)  $size"
    }

    Write-Host ""

    $DriveLetter = Read-Host "Enter the drive letter"

    if ($DriveLetter -notmatch "^[A-Za-z]$") {

        Write-Host "Invalid drive letter." `
            -ForegroundColor Red

        exit 1
    }
}

$DriveLetter = $DriveLetter.ToUpper()

$DrivePath = "$DriveLetter`:"

# ============================================================
# VOLUME
# ============================================================

Section "VOLUME"

$script:Volume = Get-Volume `
    -DriveLetter $DriveLetter `
    -ErrorAction SilentlyContinue

if (-not $script:Volume) {

    Add-Result "Volume detection" "FAIL" `
        "Windows cannot access $DrivePath."

    Write-Host ""
    Write-Host "VERDICT: UNKNOWN" -ForegroundColor Yellow

    exit 1
}

Add-Result "Volume detection" "PASS" `
    "$DrivePath detected."

Add-Result "Filesystem" "INFO" `
    "$($script:Volume.FileSystem)"

Add-Result "Volume label" "INFO" `
    "$($script:Volume.FileSystemLabel)"

if ($script:Volume.Size) {

    Add-Result "Capacity" "INFO" `
        ("{0:N2} GB total, {1:N2} GB free." -f `
        ($script:Volume.Size / 1GB),
        ($script:Volume.SizeRemaining / 1GB))
}

# ============================================================
# MAP PHYSICAL DISK
# ============================================================

Section "PHYSICAL DISK"

try {

    $script:Partition = Get-Partition `
        -DriveLetter $DriveLetter `
        -ErrorAction Stop

    $script:Disk = Get-Disk `
        -Number $script:Partition.DiskNumber `
        -ErrorAction Stop
}
catch {

    Add-Result "Physical disk mapping" "FAIL" `
        "Could not map $DrivePath to a physical disk."

    Write-Host ""
    Write-Host "VERDICT: UNKNOWN" -ForegroundColor Yellow

    exit 1
}

Add-Result "Physical disk mapping" "PASS" `
    "Disk $($script:Disk.Number) mapped successfully."

Add-Result "Disk model" "INFO" `
    "$($script:Disk.FriendlyName)"

Add-Result "Bus type" "INFO" `
    "$($script:Disk.BusType)"

Add-Result "Disk status" "INFO" `
    "$($script:Disk.OperationalStatus)"

Add-Result "Disk health" "INFO" `
    "$($script:Disk.HealthStatus)"

Add-Result "Disk size" "INFO" `
    ("{0:N2} GB" -f ($script:Disk.Size / 1GB))

# ============================================================
# POWERSHELL READ-ONLY STATE
# ============================================================

Section "WINDOWS READ-ONLY STATE"

if ($script:Disk.IsReadOnly) {

    $script:SoftwareReadOnly = $true

    Add-Result "Physical disk read-only" "WARN" `
        "Windows reports the physical disk as READ-ONLY."
}
else {

    Add-Result "Physical disk read-only" "PASS" `
        "Physical disk is not marked read-only."
}

if ($script:Partition.IsReadOnly) {

    $script:VolumeReadOnly = $true
    $script:SoftwareReadOnly = $true

    Add-Result "Partition read-only" "WARN" `
        "Windows reports the partition as READ-ONLY."
}
else {

    Add-Result "Partition read-only" "PASS" `
        "Partition is not marked read-only."
}

# ============================================================
# REGISTRY WRITE PROTECTION
# ============================================================

Section "WINDOWS WRITE-PROTECTION POLICY"

try {

    $policy = Get-ItemProperty `
        "HKLM:\SYSTEM\CurrentControlSet\Control\StorageDevicePolicies" `
        -ErrorAction SilentlyContinue

    if ($policy -and $policy.WriteProtect -eq 1) {

        $script:SoftwareReadOnly = $true

        Add-Result "Registry write protection" "WARN" `
            "StorageDevicePolicies\WriteProtect = 1."
    }
    else {

        Add-Result "Registry write protection" "PASS" `
            "No global Windows write-protection policy detected."
    }

}
catch {

    Add-Result "Registry write protection" "INFO" `
        "Could not inspect StorageDevicePolicies."
}

# ============================================================
# DISKPART CROSS-CHECK
# ============================================================

Section "DISKPART CROSS-CHECK"

$diskpartScript = Join-Path `
    $env:TEMP `
    "usbdiag-diskpart-$([Guid]::NewGuid()).txt"

$diskpartOutput = Join-Path `
    $env:TEMP `
    "usbdiag-diskpart-output-$([Guid]::NewGuid()).txt"

@"
select disk $($script:Disk.Number)
attributes disk
select partition $($script:Partition.PartitionNumber)
attributes partition
exit
"@ | Set-Content `
    -Path $diskpartScript `
    -Encoding ASCII

try {

    diskpart.exe /s $diskpartScript `
        > $diskpartOutput 2>&1

    $dpText = Get-Content `
        $diskpartOutput `
        -Raw `
        -ErrorAction SilentlyContinue

    if ($dpText -match "Read-only\s*:\s*Yes") {

        $script:DiskPartReadOnly = $true
        $script:SoftwareReadOnly = $true

        Add-Result "DiskPart disk state" "WARN" `
            "DiskPart reports the disk as READ-ONLY."
    }
    elseif ($dpText -match "Read-only\s*:\s*No") {

        Add-Result "DiskPart disk state" "PASS" `
            "DiskPart reports the disk as writable."
    }
    else {

        Add-Result "DiskPart disk state" "INFO" `
            "DiskPart disk state could not be interpreted."
    }

    if ($dpText -match "Current Read-only State\s*:\s*Yes") {

        $script:DiskPartReadOnly = $true

        Add-Result "DiskPart current read-only state" "WARN" `
            "DiskPart reports the current device state as READ-ONLY."
    }
    elseif ($dpText -match "Current Read-only State\s*:\s*No") {

        Add-Result "DiskPart current read-only state" "PASS" `
            "DiskPart reports the current device state as writable."
    }

}
catch {

    Add-Result "DiskPart cross-check" "WARN" `
        "DiskPart could not be executed."
}

Remove-Item `
    $diskpartScript,
    $diskpartOutput `
    -Force `
    -ErrorAction SilentlyContinue

# ============================================================
# OPTIONAL CLEAR READ-ONLY
# ============================================================

if ($AttemptClearReadOnly) {

    Section "CLEARING WINDOWS READ-ONLY STATE"

    Write-Host ""
    Write-Host "This modifies Windows disk metadata." `
        -ForegroundColor Yellow

    $answer = Read-Host "Type CLEAR to continue"

    if ($answer -eq "CLEAR") {

        try {

            Set-Disk `
                -Number $script:Disk.Number `
                -IsReadOnly $false `
                -ErrorAction Stop

            Add-Result "Clear physical disk read-only" "PASS" `
                "Windows disk read-only flag was cleared."
        }
        catch {

            Add-Result "Clear physical disk read-only" "FAIL" `
                "Windows could not clear the disk read-only state: $($_.Exception.Message)"
        }

        try {

            Set-Partition `
                -DiskNumber $script:Disk.Number `
                -PartitionNumber $script:Partition.PartitionNumber `
                -IsReadOnly $false `
                -ErrorAction Stop

            Add-Result "Clear partition read-only" "PASS" `
                "Partition read-only flag was cleared."
        }
        catch {

            Add-Result "Clear partition read-only" "WARN" `
                "Could not clear partition read-only state."
        }
    }
    else {

        Add-Result "Clear read-only state" "INFO" `
            "User cancelled the operation."
    }
}

# ============================================================
# FILESYSTEM
# ============================================================

Section "FILESYSTEM"

if ([string]::IsNullOrWhiteSpace($script:Volume.FileSystem)) {

    $script:FilesystemProblem = $true

    Add-Result "Filesystem detection" "FAIL" `
        "Windows does not recognize a filesystem on this volume."
}
else {

    Add-Result "Filesystem detection" "PASS" `
        "Detected $($script:Volume.FileSystem)."
}

# ============================================================
# CHKDSK READ-ONLY SCAN
# ============================================================

Section "FILESYSTEM INTEGRITY"

Write-Host "Running CHKDSK read-only scan..." `
    -ForegroundColor Gray

$chkdsk = & chkdsk $DrivePath /scan 2>&1

$chkdskText = $chkdsk -join "`n"

if (
    $chkdskText -match "found no problems" -or
    $chkdskText -match "found no problems" -or
    $chkdskText -match
        "Windows has scanned the file system and found no problems"
) {

    Add-Result "CHKDSK scan" "PASS" `
        "No obvious filesystem errors detected."
}
elseif (
    $chkdskText -match "found problems" -or
    $chkdskText -match "errors found" -or
    $chkdskText -match "corrupt"
) {

    $script:FilesystemProblem = $true

    Add-Result "CHKDSK scan" "WARN" `
        "CHKDSK reported possible filesystem corruption."
}
else {

    Add-Result "CHKDSK scan" "INFO" `
        "CHKDSK completed, but its output was inconclusive."
}

# ============================================================
# STORAGE RELIABILITY
# ============================================================

Section "STORAGE RELIABILITY"

try {

    $reliability = Get-StorageReliabilityCounter `
        -PhysicalDisk $script:Disk `
        -ErrorAction Stop

    if ($reliability) {

        $script:ReliabilityAvailable = $true

        Add-Result "Reliability counters" "PASS" `
            "Storage reliability counters are available."

        if ($reliability.Temperature) {

            Add-Result "Temperature" "INFO" `
                "$($reliability.Temperature) C"
        }

        if ($reliability.ReadErrorsTotal -gt 0) {

            $script:HardwareWarning = $true

            Add-Result "Read errors" "WARN" `
                "$($reliability.ReadErrorsTotal) read errors reported."
        }
        else {

            Add-Result "Read errors" "PASS" `
                "No read errors reported by the reliability interface."
        }

        if ($reliability.WriteErrorsTotal -gt 0) {

            $script:HardwareWarning = $true

            Add-Result "Write errors" "WARN" `
                "$($reliability.WriteErrorsTotal) write errors reported."
        }
        else {

            Add-Result "Write errors" "PASS" `
                "No write errors reported by the reliability interface."
        }

        if ($reliability.MediaErrors -gt 0) {

            $script:HardwareWarning = $true

            Add-Result "Media errors" "FAIL" `
                "$($reliability.MediaErrors) media errors reported."
        }
    }

}
catch {

    Add-Result "Reliability counters" "INFO" `
        "This USB device does not expose Windows storage reliability counters. This is common for flash drives."
}

# ============================================================
# USB / PNP DEVICE
# ============================================================

Section "USB / PNP DEVICE"

try {

    $diskNumber = $script:Disk.Number

    $diskCim = Get-CimInstance Win32_DiskDrive |
        Where-Object {
            $_.Index -eq $diskNumber
        }

    if ($diskCim) {

        Add-Result "USB device model" "INFO" `
            "$($diskCim.Model)"

        Add-Result "USB interface" "INFO" `
            "$($diskCim.InterfaceType)"

        Add-Result "USB status" "INFO" `
            "$($diskCim.Status)"

        if ($diskCim.Status -ne "OK") {

            $script:PnpErrors = $true

            Add-Result "USB device status" "FAIL" `
                "Windows reports device status: $($diskCim.Status)."
        }
    }

}
catch {

    Add-Result "USB device inspection" "WARN" `
        "Could not inspect the USB device."
}

# ============================================================
# PNP ERROR DEVICES
# ============================================================

try {

    $problemDevices = Get-PnpDevice `
        -PresentOnly `
        -ErrorAction Stop |
        Where-Object {
            $_.Status -ne "OK"
        }

    $usbProblems = $problemDevices |
        Where-Object {
            $_.Class -match "USB|DiskDrive"
        }

    if ($usbProblems) {

        $script:PnpErrors = $true

        foreach ($device in $usbProblems) {

            Add-Result "PnP device error" "WARN" `
                "$($device.FriendlyName) reports status $($device.Status)."
        }
    }
    else {

        Add-Result "PnP USB errors" "PASS" `
            "No present USB/Disk PnP errors detected."
    }

}
catch {

    Add-Result "PnP error scan" "INFO" `
        "Could not inspect PnP devices."
}

# ============================================================
# WINDOWS STORAGE EVENTS
# ============================================================

Section "WINDOWS STORAGE EVENT LOG"

try {

    $events = Get-WinEvent `
        -FilterHashtable @{
            LogName   = "System"
            StartTime = (Get-Date).AddDays(-7)
        } `
        -ErrorAction Stop |
        Where-Object {

            $_.ProviderName -match
                "disk|USBSTOR|storahci|stornvme"

        }

    if ($events) {

        $shown = 0
        $relevantEvents = @()

        foreach ($event in $events) {

            # Only count events that are actually indicative
            # of storage/device problems.

            $isError = (
                $event.LevelDisplayName -match "Error|Critical"
            )

            $isRelevantId = (
                $event.Id -in @(
                    7,      # Disk bad block
                    11,     # Disk controller error
                    15,     # Device not ready
                    51,     # Paging I/O error
                    55,     # Filesystem corruption
                    57,     # Delayed write
                    129,    # Storport reset
                    153,    # I/O retry
                    157,    # Disk surprise removal
                    140     # Filesystem/storage related
                )
            )

            if ($isError -or $isRelevantId) {

                $relevantEvents += $event
            }
        }

        if ($relevantEvents.Count -gt 0) {

            $script:StorageErrors = $true

            foreach ($event in $relevantEvents) {

                if ($shown -ge 10) {
                    break
                }

                Write-Host ""
                Write-Host "Event ID $($event.Id)" `
                    -ForegroundColor Yellow

                Write-Host "$($event.ProviderName)"

                $msg = $event.Message

                if ($msg.Length -gt 300) {

                    $msg = $msg.Substring(0,300) + "..."
                }

                Write-Host $msg

                $shown++
            }

            Add-Result "Storage event log" "WARN" `
                "$($relevantEvents.Count) relevant storage errors found in the last 7 days."
        }
        else {

            Add-Result "Storage event log" "PASS" `
                "No relevant storage errors found in the last 7 days."
        }

    }
    else {

        Add-Result "Storage event log" "PASS" `
            "No relevant storage errors found in the last 7 days."
    }

}
catch {

    Add-Result "Storage event log" "INFO" `
        "Could not inspect the System event log."
}

# ============================================================
# WRITE / READ TEST
# ============================================================

if ($WriteTest) {

    Section "WRITE / READ VERIFICATION"

    Write-Host ""
    Write-Host "This test writes $TestSizeMB MB of temporary data." `
        -ForegroundColor Yellow

    $answer = Read-Host "Type YES to continue"

    if ($answer -ne "YES") {

        $script:WriteTestCancelled = $true

        Add-Result "Write test" "INFO" `
            "User cancelled the write test."
    }
    else {

        $script:WriteTestAttempted = $true

        $testDir = Join-Path `
            $DrivePath `
            ".usbdiag"

        $testFile = Join-Path `
            $testDir `
            "verification-$([Guid]::NewGuid().ToString()).bin"

        $localTest = Join-Path `
            $env:TEMP `
            "usbdiag-source-$([Guid]::NewGuid().ToString()).bin"

        $localCopy = Join-Path `
            $env:TEMP `
            "usbdiag-readback-$([Guid]::NewGuid().ToString()).bin"

        $markerFile = $null

        # ----------------------------------------------------
        # GENERATE LOCAL TEST DATA
        # ----------------------------------------------------

        try {

            Write-Host "Generating test data..." `
                -ForegroundColor Gray

            $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

            $buffer = New-Object byte[] (1MB)

            $stream = [System.IO.File]::Open(
                $localTest,
                [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )

            try {

                for ($i = 0; $i -lt $TestSizeMB; $i++) {

                    $rng.GetBytes($buffer)

                    $stream.Write(
                        $buffer,
                        0,
                        $buffer.Length
                    )
                }

                $stream.Flush()
            }
            finally {

                $stream.Close()
                $rng.Dispose()
            }

            Add-Result "Local test data" "PASS" `
                "Generated $TestSizeMB MB of test data."

        }
        catch {

            $script:TestInfrastructureFailed = $true

            Add-Result "Local test data" "FAIL" `
                "Could not generate local test data: $($_.Exception.Message)"
        }

        # ----------------------------------------------------
        # CREATE AND VERIFY USB TEST DIRECTORY
        # ----------------------------------------------------

        if (-not $script:TestInfrastructureFailed) {

            try {

                Write-Host "Preparing USB test directory..." `
                    -ForegroundColor Gray

                # Create the directory if it does not exist.
                if (-not (Test-Path -LiteralPath $testDir)) {

                    New-Item `
                        -ItemType Directory `
                        -Path $testDir `
                        -Force `
                        -ErrorAction Stop |
                        Out-Null
                }

                # Verify using Get-Item rather than relying only on
                # Test-Path -PathType Container.
                $dirItem = Get-Item `
                    -LiteralPath $testDir `
                    -Force `
                    -ErrorAction Stop

                if (-not $dirItem.PSIsContainer) {

                    throw "The USB test path exists but is not a directory."
                }

                # ------------------------------------------------
                # REAL SMALL WRITE TEST
                # ------------------------------------------------

                $markerFile = Join-Path `
                    $testDir `
                    "usbdiag-marker-$([Guid]::NewGuid().ToString()).tmp"

                $markerText = "USB-DIAGNOSTIC-MARKER-$([Guid]::NewGuid().ToString())"

                Write-Host "Testing basic file creation..." `
                    -ForegroundColor Gray

                [System.IO.File]::WriteAllText(
                    $markerFile,
                    $markerText,
                    [System.Text.Encoding]::UTF8
                )

                # Verify that the marker exists.
                $markerItem = Get-Item `
                    -LiteralPath $markerFile `
                    -Force `
                    -ErrorAction Stop

                if (-not $markerItem -or $markerItem.Length -le 0) {

                    throw "USB marker file was created but could not be verified."
                }

                # Read the marker back.
                $markerReadback = [System.IO.File]::ReadAllText(
                    $markerFile,
                    [System.Text.Encoding]::UTF8
                )

                if ($markerReadback -ne $markerText) {

                    throw "USB marker file was written but read-back verification failed."
                }

                # Remove marker.
                Remove-Item `
                    -LiteralPath $markerFile `
                    -Force `
                    -ErrorAction Stop

                Add-Result "USB test directory" "PASS" `
                    "Directory creation, file creation, write, read, and cleanup succeeded."

            }
            catch {

                $classification = Classify-WriteError $_.Exception

                if ($classification -eq "WRITE_PROTECTED") {

                    $script:WriteFailed = $true
                    $script:WriteFailureClass = $classification
                    $script:WriteFailureMessage = $_.Exception.Message

                    Add-Result "USB test directory" "FAIL" `
                        "The USB device rejected a basic write as WRITE-PROTECTED: $($_.Exception.Message)"
                }
                elseif ($classification -eq "MEDIA_ERROR") {

                    $script:WriteFailed = $true
                    $script:WriteFailureClass = $classification
                    $script:WriteFailureMessage = $_.Exception.Message

                    Add-Result "USB test directory" "FAIL" `
                        "The USB device returned a media/I/O error: $($_.Exception.Message)"
                }
                elseif ($classification -eq "DEVICE_ERROR") {

                    $script:WriteFailed = $true
                    $script:WriteFailureClass = $classification
                    $script:WriteFailureMessage = $_.Exception.Message

                    Add-Result "USB test directory" "FAIL" `
                        "The USB device returned a device error: $($_.Exception.Message)"
                }
                elseif ($classification -eq "PATH_ERROR") {

                    # PATH_ERROR during directory creation on a READ-ONLY device
                    # is evidence of write protection, not infrastructure failure.
                    if ($script:SoftwareReadOnly -or $script:DiskPartReadOnly) {

                        $script:WriteFailed = $true
                        $script:WriteFailureClass = "WRITE_PROTECTED"
                        $script:WriteFailureMessage = $_.Exception.Message

                        Add-Result "USB test directory" "FAIL" `
                            "The USB device rejected directory creation (read-only device): $($_.Exception.Message)"
                    }
                    else {

                        $script:TestInfrastructureFailed = $true

                        Add-Result "USB test directory" "FAIL" `
                            "The diagnostic path could not be accessed: $($_.Exception.Message)"
                    }
                }
                else {

                    $script:WriteFailed = $true
                    $script:WriteFailureClass = $classification
                    $script:WriteFailureMessage = $_.Exception.Message

                    Add-Result "USB test directory" "FAIL" `
                        "Basic USB file write/read test failed: $($_.Exception.Message)"
                }
            }
        }

        # ----------------------------------------------------
        # WRITE
        # ----------------------------------------------------

        if (
            -not $script:TestInfrastructureFailed -and
            -not $script:WriteFailed
        ) {

            try {

                Write-Host "Writing $TestSizeMB MB to USB..." `
                    -ForegroundColor Gray

                Copy-Item `
                    -LiteralPath $localTest `
                    -Destination $testFile `
                    -Force `
                    -ErrorAction Stop

                # Verify that Windows can see the file.
                if (-not (
                    Test-Path `
                        -LiteralPath $testFile `
                        -PathType Leaf
                )) {

                    throw "Write operation returned successfully, but the destination file cannot be found."
                }

                $sourceLength = (
                    Get-Item `
                        -LiteralPath $localTest `
                        -ErrorAction Stop
                ).Length

                $destinationLength = (
                    Get-Item `
                        -LiteralPath $testFile `
                        -ErrorAction Stop
                ).Length

                if ($sourceLength -ne $destinationLength) {

                    throw (
                        "Write size mismatch. " +
                        "Expected $sourceLength bytes, " +
                        "found $destinationLength bytes."
                    )
                }

                $script:WritePassed = $true

                Add-Result "Sequential write" "PASS" `
                    "Successfully wrote and verified $TestSizeMB MB."

            }
            catch {

                $classification = Classify-WriteError $_.Exception

                $script:WriteFailed = $true
                $script:WriteFailureClass = $classification
                $script:WriteFailureMessage = $_.Exception.Message

                switch ($classification) {

                    "WRITE_PROTECTED" {

                        Add-Result "Sequential write" "FAIL" `
                            "Device rejected the write as WRITE-PROTECTED: $($_.Exception.Message)"
                    }

                    "MEDIA_ERROR" {

                        Add-Result "Sequential write" "FAIL" `
                            "Storage media returned an I/O/media error: $($_.Exception.Message)"
                    }

                    "DEVICE_ERROR" {

                        Add-Result "Sequential write" "FAIL" `
                            "USB storage device returned a device error: $($_.Exception.Message)"
                    }

                    "NO_SPACE" {

                        Add-Result "Sequential write" "FAIL" `
                            "The drive does not have enough free space for the requested test."
                    }

                    "FILESYSTEM_ERROR" {

                        Add-Result "Sequential write" "FAIL" `
                            "Filesystem prevented the write: $($_.Exception.Message)"
                    }

                    "PATH_ERROR" {

                        $script:TestInfrastructureFailed = $true

                        Add-Result "Sequential write" "FAIL" `
                            "Diagnostic test path failed: $($_.Exception.Message)"
                    }

                    default {

                        Add-Result "Sequential write" "FAIL" `
                            "Write failed with unclassified error: $($_.Exception.Message)"
                    }
                }
            }
        }

        # ----------------------------------------------------
        # READ
        # ----------------------------------------------------

        if (
            $script:WritePassed -and
            (Test-Path -LiteralPath $testFile)
        ) {

            try {

                Write-Host "Reading data back..." `
                    -ForegroundColor Gray

                Copy-Item `
                    -LiteralPath $testFile `
                    -Destination $localCopy `
                    -Force `
                    -ErrorAction Stop

                $script:ReadFailed = $false

                Add-Result "Sequential read" "PASS" `
                    "Successfully read the test data back."

                # ------------------------------------------------
                # SIZE CHECK
                # ------------------------------------------------

                $originalLength = (
                    Get-Item `
                        -LiteralPath $localTest `
                        -ErrorAction Stop
                ).Length

                $readLength = (
                    Get-Item `
                        -LiteralPath $localCopy `
                        -ErrorAction Stop
                ).Length

                if ($originalLength -ne $readLength) {

                    $script:HashMismatch = $true

                    Add-Result "Read size verification" "FAIL" `
                        "Read-back size mismatch. Expected $originalLength bytes, got $readLength bytes."
                }
                else {

                    Add-Result "Read size verification" "PASS" `
                        "Read-back size matches the original test data."
                }

                # ------------------------------------------------
                # HASH
                # ------------------------------------------------

                Write-Host "Comparing SHA-256 hashes..." `
                    -ForegroundColor Gray

                $originalHash = (
                    Get-FileHash `
                        -LiteralPath $localTest `
                        -Algorithm SHA256 `
                        -ErrorAction Stop
                ).Hash

                $readHash = (
                    Get-FileHash `
                        -LiteralPath $localCopy `
                        -Algorithm SHA256 `
                        -ErrorAction Stop
                ).Hash

                if ($originalHash -eq $readHash) {

                    Add-Result "Read verification" "PASS" `
                        "SHA-256 hashes match. No corruption detected."
                }
                else {

                    $script:HashMismatch = $true

                    Add-Result "Read verification" "FAIL" `
                        "SHA-256 hashes DO NOT MATCH. Data corruption detected."
                }

            }
            catch {

                $script:ReadFailed = $true

                Add-Result "Sequential read" "FAIL" `
                    "Read failed: $($_.Exception.Message)"
            }
        }
        elseif (
            $script:WritePassed -and
            -not (Test-Path -LiteralPath $testFile)
        ) {

            $script:ReadFailed = $true

            Add-Result "Read verification" "FAIL" `
                "Write appeared to succeed, but the test file cannot be found."
        }

        # ----------------------------------------------------
        # CLEANUP
        # ----------------------------------------------------

        $cleanupProblems = $false

        try {

            if ($markerFile -and
                (Test-Path -LiteralPath $markerFile)) {

                Remove-Item `
                    -LiteralPath $markerFile `
                    -Force `
                    -ErrorAction Stop
            }

            if ($testFile -and
                (Test-Path -LiteralPath $testFile)) {

                Remove-Item `
                    -LiteralPath $testFile `
                    -Force `
                    -ErrorAction Stop
            }

            if ($testDir -and
                (Test-Path -LiteralPath $testDir)) {

                Remove-Item `
                    -LiteralPath $testDir `
                    -Force `
                    -Recurse `
                    -ErrorAction Stop
            }

            if ($localCopy -and
                (Test-Path -LiteralPath $localCopy)) {

                Remove-Item `
                    -LiteralPath $localCopy `
                    -Force `
                    -ErrorAction Stop
            }

            if ($localTest -and
                (Test-Path -LiteralPath $localTest)) {

                Remove-Item `
                    -LiteralPath $localTest `
                    -Force `
                    -ErrorAction Stop
            }

        }
        catch {

            $cleanupProblems = $true

            Add-Result "Test cleanup" "WARN" `
                "Some temporary diagnostic files could not be removed: $($_.Exception.Message)"
        }

        if (-not $cleanupProblems) {

            Add-Result "Test cleanup" "PASS" `
                "Temporary diagnostic files removed."
        }
    }
}
else {

    Section "WRITE TEST"

    Add-Result "Write/read verification" "INFO" `
        "Skipped. Run with -WriteTest for actual media testing."
}

# ============================================================
# FINAL DIAGNOSIS
# ============================================================

Section "FINAL DIAGNOSIS"

$verdict = "UNKNOWN"
$confidence = "LOW"
$reason = ""

# ============================================================
# WRITE TEST INFRASTRUCTURE FAILURE
# ============================================================

if ($script:TestInfrastructureFailed) {

    $verdict = "UNKNOWN"
    $confidence = "LOW"

    $reason =
        "The diagnostic write test itself could not be completed. " +
        "The failure cannot be used as evidence of flash-media failure."

}

# ============================================================
# VERIFIED WRITE PROTECTION
# ============================================================

elseif (
    $script:WriteFailed -and
    $script:WriteFailureClass -eq "WRITE_PROTECTED" -and
    (
        $script:DiskPartReadOnly -or
        $script:SoftwareReadOnly
    )
) {

    $verdict = "REPLACE"
    $confidence = "HIGH"

    $reason =
        "The USB device reports a current READ-ONLY state and " +
        "explicitly rejected a real write operation as write-protected. " +
        "No normal Windows policy or partition setting explains the condition. " +
        "A controller-level failure or permanent hardware write-protection " +
        "state is likely."

}

# ============================================================
# VERIFIED MEDIA / I/O FAILURE
# ============================================================

elseif (
    $script:WriteFailed -and
    (
        $script:WriteFailureClass -eq "MEDIA_ERROR" -or
        $script:WriteFailureClass -eq "DEVICE_ERROR"
    )
) {

    $verdict = "FAILING"
    $confidence = "HIGH"

    $reason =
        "The drive failed an actual storage write operation with a " +
        "device, I/O, or media error. This is strong evidence of " +
        "unreliable hardware."

}

# ============================================================
# WRITE FAILED WITHOUT READ-ONLY STATE
# ============================================================

elseif (
    $script:WriteFailed -and
    -not $script:SoftwareReadOnly -and
    -not $script:DiskPartReadOnly
) {

    $verdict = "FAILING"
    $confidence = "HIGH"

    $reason =
        "The drive is not reported as read-only by Windows, but an " +
        "actual write operation failed. This indicates a likely " +
        "filesystem, device, or hardware problem."

}

# ============================================================
# HASH MISMATCH
# ============================================================

elseif ($script:HashMismatch) {

    $verdict = "FAILING"
    $confidence = "HIGH"

    $reason =
        "The drive accepted the test data but returned different " +
        "data during read-back. This indicates unreliable storage."

}

# ============================================================
# READ FAILURE
# ============================================================

elseif ($script:ReadFailed) {

    $verdict = "FAILING"
    $confidence = "HIGH"

    $reason =
        "The drive could not reliably read back data that was " +
        "successfully written."

}

# ============================================================
# WRITE TEST PASSED
# ============================================================

elseif ($script:WritePassed -and
        -not $script:HashMismatch -and
        -not $script:ReadFailed) {

    if (
        $script:SoftwareReadOnly -or
        $script:DiskPartReadOnly
    ) {

        $verdict = "RECOVERABLE"
        $confidence = "HIGH"

        $reason =
            "The drive previously reported a READ-ONLY state, but " +
            "it successfully accepted and verified test data. " +
            "The problem is therefore not behaving as a permanent " +
            "hardware write lock."

    }
    elseif ($script:FilesystemProblem) {

        $verdict = "RECOVERABLE"
        $confidence = "HIGH"

        $reason =
            "The physical media successfully passed the write/read " +
            "verification. The remaining problem appears to be " +
            "filesystem-related."

    }
    elseif ($script:HardwareWarning -or $script:PnpErrors) {

        $verdict = "FAILING"
        $confidence = "MEDIUM"

        $reason =
            "The drive passed the controlled write/read test, but " +
            "Windows reported additional hardware or device warnings."

    }
    else {

        $verdict = "RECOVERABLE"
        $confidence = "HIGH"

        $reason =
            "The drive successfully accepted, stored, read, and " +
            "verified test data."
    }
}

# ============================================================
# READ-ONLY WITHOUT WRITE TEST
# ============================================================

elseif (
    (
        $script:SoftwareReadOnly -or
        $script:DiskPartReadOnly
    ) -and
    -not $script:WriteTestAttempted
) {

    $verdict = "UNKNOWN"
    $confidence = "MEDIUM"

    $reason =
        "The physical disk reports a READ-ONLY state, but no actual " +
        "write operation was performed. Hardware failure cannot yet " +
        "be distinguished from a software or controller-level issue."

}

# ============================================================
# WRITE TEST CANCELLED
# ============================================================

elseif ($script:WriteTestCancelled) {

    $verdict = "UNKNOWN"
    $confidence = "LOW"

    $reason =
        "The write test was cancelled before the drive's write " +
        "behavior could be tested."

}

# ============================================================
# HARDWARE WARNINGS
# ============================================================

elseif (
    $script:HardwareWarning -or
    $script:PnpErrors -or
    $script:StorageErrors
) {

    $verdict = "FAILING"
    $confidence = "MEDIUM"

    $reason =
        "Windows reported storage, USB, or hardware-related errors, " +
        "but the available evidence is insufficient to establish " +
        "a definitive media failure."

}

# ============================================================
# UNKNOWN
# ============================================================

else {

    $verdict = "UNKNOWN"
    $confidence = "LOW"

    $reason =
        "The available tests were insufficient to determine the cause."
}

# ============================================================
# VERDICT
# ============================================================

Write-Host ""

switch ($verdict) {

    "RECOVERABLE" {

        Write-Host "VERDICT: RECOVERABLE" `
            -ForegroundColor Green
    }

    "FAILING" {

        Write-Host "VERDICT: FAILING" `
            -ForegroundColor Yellow
    }

    "REPLACE" {

        Write-Host "VERDICT: REPLACE" `
            -ForegroundColor Red
    }

    "UNKNOWN" {

        Write-Host "VERDICT: UNKNOWN" `
            -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Confidence: $confidence"

Write-Host ""
Write-Host "Reason:"
Write-Host $reason

# ============================================================
# SPECIAL VERIFIED READ-ONLY DIAGNOSIS
# ============================================================

if (
    $script:DiskPartReadOnly -and
    $script:WriteTestAttempted -and
    $script:WriteFailureClass -eq "WRITE_PROTECTED"
) {

    Write-Host ""
    Write-Host "IMPORTANT:" -ForegroundColor Red

    Write-Host ""
    Write-Host "The physical USB device reports READ-ONLY."

    Write-Host ""
    Write-Host "The controlled write operation was explicitly rejected" `
        -ForegroundColor Yellow

    Write-Host "as write-protected."

    Write-Host ""
    Write-Host "Windows registry policy and partition-level state do not" `
        -ForegroundColor Yellow

    Write-Host "explain the condition."

    Write-Host ""
    Write-Host "A flash controller or NAND failure is therefore likely."

    Write-Host ""
    Write-Host "Software formatting or repeatedly clearing the read-only" `
        -ForegroundColor Yellow

    Write-Host "flag is unlikely to repair a controller-level failure."
}

# ============================================================
# RECOMMENDATION
# ============================================================

Write-Host ""
Write-Host "RECOMMENDATION:" -ForegroundColor Cyan

switch ($verdict) {

    "RECOVERABLE" {

        Write-Host "  Back up the drive."
        Write-Host "  Repair filesystem problems if present."
        Write-Host "  Retest after repair."
    }

    "FAILING" {

        Write-Host "  Copy important data immediately."
        Write-Host "  Do not trust this drive with important data."
        Write-Host "  Test another USB port."
        Write-Host "  Test another computer."
        Write-Host "  Replace the drive if the failure follows the device."
    }

    "REPLACE" {

        Write-Host "  Recover important files immediately."
        Write-Host "  Do not repeatedly format the drive."
        Write-Host "  Do not use it for important storage."
        Write-Host "  Test on another computer if data recovery is still needed."
        Write-Host "  Replace the drive if the same condition remains."
    }

    "UNKNOWN" {

        Write-Host "  Do not assume the drive has failed yet."
        Write-Host "  Run again with -WriteTest."
        Write-Host "  Test another USB port."
        Write-Host "  Test another computer."
    }
}

Write-Host ""
Write-Host "Diagnostic complete." -ForegroundColor Cyan