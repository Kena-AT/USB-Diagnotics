#requires -Version 5.1

<#
USB FLASH DRIVE DIAGNOSTIC TOOL
Version 2.0

Non-destructive by default.

Usage:

    .\USB-Diagnostic.ps1

    .\USB-Diagnostic.ps1 -DriveLetter E

    .\USB-Diagnostic.ps1 -DriveLetter E -WriteTest

    .\USB-Diagnostic.ps1 -DriveLetter E -WriteTest -TestSizeMB 100

    .\USB-Diagnostic.ps1 -DriveLetter E -WriteTest -AttemptClearReadOnly

IMPORTANT:
    - The normal diagnostic mode does not modify the drive.
    - -WriteTest writes temporary test data.
    - -AttemptClearReadOnly attempts to clear Windows/DiskPart read-only
      state. Use only when you explicitly want to test that possibility.
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
        Write-Host "No removable drives detected." -ForegroundColor Red
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
        Write-Host "Invalid drive letter." -ForegroundColor Red
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
    Write-Host "VERDICT: REPLACE" -ForegroundColor Red
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
    Write-Host "VERDICT: REPLACE" -ForegroundColor Red
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

$diskpartScript = Join-Path $env:TEMP "usbdiag-diskpart.txt"
$diskpartOutput = Join-Path $env:TEMP "usbdiag-diskpart-output.txt"

@"
select disk $($script:Disk.Number)
attributes disk
select partition $($script:Partition.PartitionNumber)
attributes partition
exit
"@ | Set-Content -Path $diskpartScript -Encoding ASCII

try {

    diskpart.exe /s $diskpartScript `
        > $diskpartOutput 2>&1

    $dpText = Get-Content $diskpartOutput -Raw

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
            "DiskPart output could not be interpreted."
    }

    if ($dpText -match "Current Read-only State\s*:\s*Yes") {

        Add-Result "DiskPart current read-only state" "WARN" `
            "DiskPart reports the current device state as READ-ONLY."

        $script:DiskPartReadOnly = $true
    }

}
catch {

    Add-Result "DiskPart cross-check" "WARN" `
        "DiskPart could not be executed."
}

Remove-Item $diskpartScript,$diskpartOutput `
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
                "Windows could not clear the disk read-only state."
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

Write-Host "Running CHKDSK read-only scan..." -ForegroundColor Gray

$chkdsk = & chkdsk $DrivePath /scan 2>&1

$chkdskText = $chkdsk -join "`n"

if ($chkdskText -match
    "found no problems|Windows has scanned the file system and found no problems") {

    Add-Result "CHKDSK scan" "PASS" `
        "No obvious filesystem errors detected."
}
elseif ($chkdskText -match
    "found problems|errors found|corrupt") {

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
# PNP / USB DEVICE STATUS
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
            "disk|USBSTOR|Kernel-PnP|Ntfs|storahci|stornvme"
        }

    if ($events) {

        $script:StorageErrors = $true

        $shown = 0

        foreach ($event in $events) {

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
            "$($events.Count) relevant storage/USB events found in the last 7 days."

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
# WRITE TEST
# ============================================================

if ($WriteTest) {

    Section "WRITE / READ VERIFICATION"

    Write-Host ""
    Write-Host "This test writes $TestSizeMB MB of temporary data." `
        -ForegroundColor Yellow

    $answer = Read-Host "Type YES to continue"

    if ($answer -ne "YES") {

        Add-Result "Write test" "INFO" `
            "User cancelled the write test."

    }
    else {

        $testDir = Join-Path $DrivePath ".usbdiag"

        $testFile = Join-Path `
            $testDir `
            "verification-$([Guid]::NewGuid().ToString()).bin"

        $localCopy = Join-Path `
            $env:TEMP `
            "usbdiag-$([Guid]::NewGuid().ToString()).bin"

        try {

            New-Item `
                -ItemType Directory `
                -Path $testDir `
                -Force `
                -ErrorAction Stop |
                Out-Null

            # Generate test data locally first.
            $localTest = Join-Path `
                $env:TEMP `
                "usbdiag-source-$([Guid]::NewGuid().ToString()).bin"

            Write-Host "Generating test data..." -ForegroundColor Gray

            $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

            $buffer = New-Object byte[] (1MB)

            $stream = [System.IO.File]::Open(
                $localTest,
                [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write
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

            # ------------------------------------------------
            # WRITE
            # ------------------------------------------------

            Write-Host "Writing $TestSizeMB MB to USB..." `
                -ForegroundColor Gray

            Copy-Item `
                -Path $localTest `
                -Destination $testFile `
                -Force `
                -ErrorAction Stop

            Add-Result "Sequential write" "PASS" `
                "Successfully wrote $TestSizeMB MB."

            $script:WritePassed = $true

        }
        catch {

            $script:WriteFailed = $true

            Add-Result "Sequential write" "FAIL" `
                "Write failed: $($_.Exception.Message)"
        }

        # ----------------------------------------------------
        # READ
        # ----------------------------------------------------

        if (Test-Path $testFile) {

            try {

                Write-Host "Reading data back..." `
                    -ForegroundColor Gray

                Copy-Item `
                    -Path $testFile `
                    -Destination $localCopy `
                    -Force `
                    -ErrorAction Stop

                Add-Result "Sequential read" "PASS" `
                    "Successfully read the test data back."

                # ------------------------------------------------
                # HASH
                # ------------------------------------------------

                Write-Host "Comparing SHA-256 hashes..." `
                    -ForegroundColor Gray

                $originalHash = (
                    Get-FileHash `
                        -Path $localTest `
                        -Algorithm SHA256
                ).Hash

                $readHash = (
                    Get-FileHash `
                        -Path $localCopy `
                        -Algorithm SHA256
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
        elseif (-not $script:WriteFailed) {

            $script:ReadFailed = $true

            Add-Result "Read verification" "FAIL" `
                "Write appeared to succeed but the test file cannot be found."
        }

        # ----------------------------------------------------
        # CLEANUP
        # ----------------------------------------------------

        try {

            Remove-Item `
                $testFile `
                -Force `
                -ErrorAction SilentlyContinue

            Remove-Item `
                $testDir `
                -Force `
                -ErrorAction SilentlyContinue

            Remove-Item `
                $localCopy `
                -Force `
                -ErrorAction SilentlyContinue

            Remove-Item `
                $localTest `
                -Force `
                -ErrorAction SilentlyContinue

            Add-Result "Test cleanup" "PASS" `
                "Temporary diagnostic files removed."

        }
        catch {

            Add-Result "Test cleanup" "WARN" `
                "Some temporary files could not be removed."
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

# ------------------------------------------------------------
# HARDWARE-LEVEL FAILURE
# ------------------------------------------------------------

if ($script:WriteFailed -and
    ($script:DiskPartReadOnly -or
     $script:SoftwareReadOnly -or
     $script:HardwareWarning -or
     $script:StorageErrors)) {

    $verdict = "REPLACE"
    $confidence = "HIGH"

    $reason =
        "The drive cannot accept writes and software-level or " +
        "storage-level evidence indicates a deeper failure. " +
        "A failing flash controller or NAND memory is likely."
}

# ------------------------------------------------------------
# WRITE FAILURE WITHOUT SOFTWARE READ-ONLY
# ------------------------------------------------------------

elseif ($script:WriteFailed -and
        -not $script:SoftwareReadOnly) {

    $verdict = "REPLACE"
    $confidence = "HIGH"

    $reason =
        "The drive is not marked read-only by Windows, but it " +
        "cannot accept a controlled write. This strongly suggests " +
        "hardware/controller failure."
}

# ------------------------------------------------------------
# DATA CORRUPTION
# ------------------------------------------------------------

elseif ($script:HashMismatch) {

    $verdict = "FAILING"
    $confidence = "HIGH"

    $reason =
        "The drive accepted data but returned different data when " +
        "read back. This indicates unreliable storage."
}

# ------------------------------------------------------------
# READ FAILURE
# ------------------------------------------------------------

elseif ($script:ReadFailed) {

    $verdict = "FAILING"
    $confidence = "HIGH"

    $reason =
        "The drive could not reliably read back data that was written."
}

# ------------------------------------------------------------
# SOFTWARE READ-ONLY
# ------------------------------------------------------------

elseif ($script:SoftwareReadOnly -and
        $script:WritePassed) {

    $verdict = "RECOVERABLE"
    $confidence = "HIGH"

    $reason =
        "The drive was previously marked read-only by Windows, " +
        "but it successfully accepted and verified new data."
}

# ------------------------------------------------------------
# FILESYSTEM CORRUPTION
# ------------------------------------------------------------

elseif ($script:FilesystemProblem -and
        $script:WritePassed) {

    $verdict = "RECOVERABLE"
    $confidence = "HIGH"

    $reason =
        "The physical media passed the write/read test. " +
        "The remaining problem appears to be filesystem-related."
}

# ------------------------------------------------------------
# EVERYTHING PASSED
# ------------------------------------------------------------

elseif ($script:WritePassed -and
        -not $script:HardwareWarning -and
        -not $script:PnpErrors) {

    $verdict = "RECOVERABLE"
    $confidence = "HIGH"

    $reason =
        "The drive successfully accepted, stored, read, and " +
        "verified test data."
}

# ------------------------------------------------------------
# READ-ONLY BUT NO WRITE TEST
# ------------------------------------------------------------

elseif ($script:SoftwareReadOnly -and
        -not $WriteTest) {

    $verdict = "RECOVERABLE"
    $confidence = "MEDIUM"

    $reason =
        "A Windows-level read-only state was detected. " +
        "Hardware failure cannot be confirmed without a write test."
}

# ------------------------------------------------------------
# HARDWARE WARNINGS
# ------------------------------------------------------------

elseif ($script:HardwareWarning -or
        $script:PnpErrors -or
        $script:StorageErrors) {

    $verdict = "FAILING"
    $confidence = "MEDIUM"

    $reason =
        "Windows reported storage, USB, or hardware-related warnings."
}

# ------------------------------------------------------------
# UNKNOWN
# ------------------------------------------------------------

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
# SPECIAL READ-ONLY DIAGNOSIS
# ============================================================

if ($script:DiskPartReadOnly -and
    $WriteTest -and
    $script:WriteFailed) {

    Write-Host ""
    Write-Host "IMPORTANT:" -ForegroundColor Red

    Write-Host ""
    Write-Host "The drive is reporting READ-ONLY and refused the write test."

    Write-Host ""
    Write-Host "This is consistent with a flash controller entering" `
        -ForegroundColor Yellow

    Write-Host "a permanent read-only/failure state."

    Write-Host ""
    Write-Host "Software cannot reliably repair this condition."

    Write-Host ""
    Write-Host "Recommended:"
    Write-Host "  1. Recover important files immediately."
    Write-Host "  2. Test the drive on another computer."
    Write-Host "  3. If it remains read-only, replace the drive."
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
        Write-Host "  Test another USB port and another computer."
    }

    "REPLACE" {

        Write-Host "  Recover important files immediately."
        Write-Host "  Do not repeatedly format the drive."
        Write-Host "  Do not use it for important storage."
        Write-Host "  Replace the drive."
    }

    "UNKNOWN" {

        Write-Host "  Run again with -WriteTest."
        Write-Host "  Test another USB port."
        Write-Host "  Test another computer."
    }
}

Write-Host ""
Write-Host "Diagnostic complete." -ForegroundColor Cyan