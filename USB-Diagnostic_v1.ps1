#requires -Version 5.1

<#
.SYNOPSIS
    Diagnoses USB flash-drive read-only problems.

.DESCRIPTION
    Checks:
      - Disk detection
      - Disk and volume read-only state
      - Windows write-protection policy
      - Filesystem
      - Volume health
      - Windows disk/storage errors
      - USB device information
      - Optional non-destructive write/read verification
      - Produces a final verdict:
            RECOVERABLE
            FAILING
            REPLACE
            UNKNOWN

    By default, the script does NOT modify the drive.

.EXAMPLE
    .\USB-Diagnostic.ps1

.EXAMPLE
    .\USB-Diagnostic.ps1 -DriveLetter E

.EXAMPLE
    .\USB-Diagnostic.ps1 -DriveLetter E -WriteTest

.NOTES
    Run PowerShell as Administrator for the most complete results.
#>

param(
    [Parameter(Mandatory = $false)]
    [ValidatePattern("^[A-Za-z]$")]
    [string]$DriveLetter,

    [switch]$WriteTest,

    [int]$TestSizeMB = 5,

    [switch]$RepairFilesystem
)

$ErrorActionPreference = "Continue"

# ------------------------------------------------------------
# GLOBAL STATE
# ------------------------------------------------------------

$Results = [System.Collections.Generic.List[object]]::new()

$script:CriticalHardwareFailure = $false
$script:FilesystemProblem = $false
$script:SoftwareReadOnly = $false
$script:WriteFailure = $false
$script:ReadVerificationFailure = $false
$script:DiskHealthy = $false
$script:DriveFound = $false
$script:WriteTestPassed = $false

# ------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------

function Write-Section {
    param([string]$Text)

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Write-Result {
    param(
        [string]$Test,
        [ValidateSet("PASS","WARN","FAIL","INFO")]
        [string]$Status,
        [string]$Message
    )

    $Results.Add([PSCustomObject]@{
        Test    = $Test
        Status  = $Status
        Message = $Message
    })

    switch ($Status) {
        "PASS" {
            Write-Host "[PASS] $Test - $Message" -ForegroundColor Green
        }

        "WARN" {
            Write-Host "[WARN] $Test - $Message" -ForegroundColor Yellow
        }

        "FAIL" {
            Write-Host "[FAIL] $Test - $Message" -ForegroundColor Red
        }

        "INFO" {
            Write-Host "[INFO] $Test - $Message" -ForegroundColor Gray
        }
    }
}

function Get-UserDriveLetter {

    if ($DriveLetter) {
        return $DriveLetter.ToUpper()
    }

    Write-Host ""
    Write-Host "Available removable drives:" -ForegroundColor Yellow

    $removable = Get-CimInstance Win32_LogicalDisk |
        Where-Object { $_.DriveType -eq 2 }

    if (-not $removable) {
        Write-Host "No removable drives detected." -ForegroundColor Red
        exit 1
    }

    foreach ($drive in $removable) {
        Write-Host "  $($drive.DeviceID)  $($drive.VolumeName)  $([math]::Round($drive.Size / 1GB,2)) GB"
    }

    Write-Host ""

    $selected = Read-Host "Enter drive letter"

    if ($selected -notmatch "^[A-Za-z]$") {
        Write-Host "Invalid drive letter." -ForegroundColor Red
        exit 1
    }

    return $selected.ToUpper()
}

function Get-DiskForDrive {
    param([string]$Letter)

    try {
        $partition = Get-Partition -DriveLetter $Letter -ErrorAction Stop
        return Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Test-Admin {

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

# ------------------------------------------------------------
# START
# ------------------------------------------------------------

Write-Host ""
Write-Host "USB FLASH DRIVE DIAGNOSTIC TOOL" -ForegroundColor Cyan
Write-Host "Version 1.0"
Write-Host ""

if (-not (Test-Admin)) {
    Write-Result `
        -Test "Administrator privileges" `
        -Status "WARN" `
        -Message "PowerShell is not running as Administrator. Some diagnostics may be unavailable."
}
else {
    Write-Result `
        -Test "Administrator privileges" `
        -Status "PASS" `
        -Message "Running with Administrator privileges."
}

$DriveLetter = Get-UserDriveLetter

$DriveLetter = $DriveLetter.ToUpper()

Write-Host ""
Write-Host "Selected drive: $DriveLetter`:" -ForegroundColor White

# ------------------------------------------------------------
# DRIVE DETECTION
# ------------------------------------------------------------

Write-Section "DRIVE DETECTION"

$volume = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue

if (-not $volume) {

    Write-Result `
        -Test "Drive detection" `
        -Status "FAIL" `
        -Message "Windows cannot access volume $DriveLetter`:."

    Write-Host ""
    Write-Host "VERDICT: REPLACE" -ForegroundColor Red
    Write-Host "The requested drive could not be accessed."
    exit 1
}

$script:DriveFound = $true

Write-Result `
    -Test "Drive detection" `
    -Status "PASS" `
    -Message "Volume $DriveLetter`: detected."

Write-Result `
    -Test "Filesystem" `
    -Status "INFO" `
    -Message "$($volume.FileSystem)"

Write-Result `
    -Test "Volume label" `
    -Status "INFO" `
    -Message "$($volume.FileSystemLabel)"

if ($volume.Size) {

    $sizeGB = [math]::Round($volume.Size / 1GB, 2)
    $freeGB = [math]::Round($volume.SizeRemaining / 1GB, 2)

    Write-Result `
        -Test "Capacity" `
        -Status "INFO" `
        -Message "$sizeGB GB total, $freeGB GB free."
}

# ------------------------------------------------------------
# PHYSICAL DISK
# ------------------------------------------------------------

Write-Section "PHYSICAL DISK"

$disk = Get-DiskForDrive -Letter $DriveLetter

if (-not $disk) {

    Write-Result `
        -Test "Physical disk" `
        -Status "FAIL" `
        -Message "Could not map the volume to a physical disk."

    $script:CriticalHardwareFailure = $true
}
else {

    Write-Result `
        -Test "Physical disk" `
        -Status "PASS" `
        -Message "Disk $($disk.Number) detected."

    Write-Result `
        -Test "Disk model" `
        -Status "INFO" `
        -Message "$($disk.FriendlyName)"

    Write-Result `
        -Test "Bus type" `
        -Status "INFO" `
        -Message "$($disk.BusType)"

    Write-Result `
        -Test "Disk size" `
        -Status "INFO" `
        -Message "$([math]::Round($disk.Size / 1GB,2)) GB"

    # --------------------------------------------------------
    # DISK READ ONLY
    # --------------------------------------------------------

    if ($disk.IsReadOnly) {

        Write-Result `
            -Test "Disk read-only flag" `
            -Status "WARN" `
            -Message "Windows reports the physical disk as READ-ONLY."

        $script:SoftwareReadOnly = $true
    }
    else {

        Write-Result `
            -Test "Disk read-only flag" `
            -Status "PASS" `
            -Message "Physical disk is not marked read-only."
    }

    # --------------------------------------------------------
    # DISK HEALTH
    # --------------------------------------------------------

    if ($disk.HealthStatus -eq "Healthy") {

        $script:DiskHealthy = $true

        Write-Result `
            -Test "Disk health" `
            -Status "PASS" `
            -Message "Windows reports the disk as Healthy."
    }
    else {

        Write-Result `
            -Test "Disk health" `
            -Status "FAIL" `
            -Message "Windows reports disk health as $($disk.HealthStatus)."

        $script:CriticalHardwareFailure = $true
    }
}

# ------------------------------------------------------------
# VOLUME READ ONLY
# ------------------------------------------------------------

Write-Section "VOLUME STATE"

try {

    $partition = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop

    if ($partition.IsReadOnly) {

        Write-Result `
            -Test "Partition read-only flag" `
            -Status "WARN" `
            -Message "Partition is marked read-only."

        $script:SoftwareReadOnly = $true
    }
    else {

        Write-Result `
            -Test "Partition read-only flag" `
            -Status "PASS" `
            -Message "Partition is not marked read-only."
    }

}
catch {

    Write-Result `
        -Test "Partition state" `
        -Status "FAIL" `
        -Message "Could not inspect partition state."
}

# ------------------------------------------------------------
# WINDOWS WRITE PROTECTION POLICY
# ------------------------------------------------------------

Write-Section "WINDOWS WRITE-PROTECTION POLICY"

try {

    $storagePolicy = Get-ItemProperty `
        -Path "HKLM:\SYSTEM\CurrentControlSet\Control\StorageDevicePolicies" `
        -ErrorAction SilentlyContinue

    if ($storagePolicy -and $storagePolicy.WriteProtect -eq 1) {

        Write-Result `
            -Test "StorageDevicePolicies" `
            -Status "WARN" `
            -Message "Windows registry policy enables write protection."

        $script:SoftwareReadOnly = $true
    }
    else {

        Write-Result `
            -Test "StorageDevicePolicies" `
            -Status "PASS" `
            -Message "No global Windows registry write-protection policy detected."
    }

}
catch {

    Write-Result `
        -Test "StorageDevicePolicies" `
        -Status "INFO" `
        -Message "Could not inspect registry policy."
}

# ------------------------------------------------------------
# FILESYSTEM
# ------------------------------------------------------------

Write-Section "FILESYSTEM"

$fs = $volume.FileSystem

if ([string]::IsNullOrWhiteSpace($fs)) {

    Write-Result `
        -Test "Filesystem" `
        -Status "FAIL" `
        -Message "No recognizable filesystem detected."

    $script:FilesystemProblem = $true
}
else {

    Write-Result `
        -Test "Filesystem detection" `
        -Status "PASS" `
        -Message "Filesystem detected: $fs."
}

# ------------------------------------------------------------
# CHKDSK READ-ONLY SCAN
# ------------------------------------------------------------

Write-Section "FILESYSTEM INTEGRITY"

Write-Host "Running a read-only filesystem scan..." -ForegroundColor Gray

$chkdskOutput = & chkdsk "$DriveLetter`:" /scan 2>&1

$chkdskText = $chkdskOutput -join "`n"

if ($LASTEXITCODE -eq 0) {

    if ($chkdskText -match "found no problems|Windows has scanned the file system") {

        Write-Result `
            -Test "Filesystem scan" `
            -Status "PASS" `
            -Message "No obvious filesystem errors detected."
    }
    else {

        Write-Result `
            -Test "Filesystem scan" `
            -Status "INFO" `
            -Message "Filesystem scan completed. Review the diagnostic output."
    }
}
else {

    Write-Result `
        -Test "Filesystem scan" `
        -Status "WARN" `
        -Message "Filesystem scan reported an issue or could not complete."

    $script:FilesystemProblem = $true
}

# ------------------------------------------------------------
# WINDOWS STORAGE EVENTS
# ------------------------------------------------------------

Write-Section "WINDOWS STORAGE ERRORS"

try {

    $events = Get-WinEvent `
        -FilterHashtable @{
            LogName = "System"
            StartTime = (Get-Date).AddDays(-7)
        } `
        -ErrorAction Stop |
        Where-Object {
            $_.ProviderName -match "disk|storahci|stornvme|USBSTOR|Kernel-PnP|Ntfs"
        } |
        Select-Object -First 20

    if ($events.Count -eq 0) {

        Write-Result `
            -Test "Storage event log" `
            -Status "PASS" `
            -Message "No relevant storage errors found in the last 7 days."
    }
    else {

        Write-Result `
            -Test "Storage event log" `
            -Status "WARN" `
            -Message "$($events.Count) relevant storage events found in the last 7 days."

        foreach ($event in $events) {

            Write-Host ""
            Write-Host "  [$($event.TimeCreated)] $($event.ProviderName)" `
                -ForegroundColor Yellow

            Write-Host "  Event ID: $($event.Id)"

            $message = $event.Message

            if ($message.Length -gt 250) {
                $message = $message.Substring(0,250) + "..."
            }

            Write-Host "  $message"
        }
    }

}
catch {

    Write-Result `
        -Test "Storage event log" `
        -Status "INFO" `
        -Message "Could not read the Windows System event log."
}

# ------------------------------------------------------------
# USB DEVICE
# ------------------------------------------------------------

Write-Section "USB DEVICE"

try {

    $usbDevices = Get-CimInstance Win32_DiskDrive |
        Where-Object {
            $_.Index -eq $disk.Number
        }

    if ($usbDevices) {

        foreach ($usb in $usbDevices) {

            Write-Result `
                -Test "USB model" `
                -Status "INFO" `
                -Message "$($usb.Model)"

            Write-Result `
                -Test "USB interface" `
                -Status "INFO" `
                -Message "$($usb.InterfaceType)"

            Write-Result `
                -Test "USB status" `
                -Status "INFO" `
                -Message "$($usb.Status)"

            if ($usb.Status -ne "OK") {

                $script:CriticalHardwareFailure = $true

                Write-Result `
                    -Test "USB hardware status" `
                    -Status "FAIL" `
                    -Message "Windows reports the device status as $($usb.Status)."
            }
        }
    }

}
catch {

    Write-Result `
        -Test "USB device information" `
        -Status "INFO" `
        -Message "Could not retrieve detailed USB information."
}

# ------------------------------------------------------------
# WRITE TEST
# ------------------------------------------------------------

if ($WriteTest) {

    Write-Section "WRITE / READ VERIFICATION"

    Write-Host ""
    Write-Host "WARNING: This test writes approximately $TestSizeMB MB to the drive." `
        -ForegroundColor Yellow

    Write-Host "It should not destroy existing files, but do not run it on a drive"
    Write-Host "that is currently being used for critical operations."

    $answer = Read-Host "Continue? Type YES"

    if ($answer -ne "YES") {

        Write-Result `
            -Test "Write test" `
            -Status "INFO" `
            -Message "User cancelled write test."
    }
    else {

        $testDirectory = Join-Path "$DriveLetter`:\" ".usbdiag"

        try {

            New-Item `
                -ItemType Directory `
                -Path $testDirectory `
                -Force `
                -ErrorAction Stop | Out-Null

            $testFile = Join-Path $testDirectory "write-test.bin"

            $bytes = $TestSizeMB * 1MB

            Write-Host ""
            Write-Host "Generating $TestSizeMB MB test data..." -ForegroundColor Gray

            $random = [System.Security.Cryptography.RandomNumberGenerator]::Create()

            $buffer = New-Object byte[] (1MB)

            $stream = [System.IO.File]::Open(
                $testFile,
                [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )

            try {

                $remaining = $bytes

                while ($remaining -gt 0) {

                    $random.GetBytes($buffer)

                    $toWrite = [Math]::Min($buffer.Length, $remaining)

                    $stream.Write($buffer, 0, $toWrite)

                    $remaining -= $toWrite
                }

                $stream.Flush()

            }
            finally {

                $stream.Close()
                $random.Dispose()
            }

            Write-Result `
                -Test "Write test" `
                -Status "PASS" `
                -Message "Successfully wrote $TestSizeMB MB."

            $script:WriteTestPassed = $true

        }
        catch {

            $script:WriteFailure = $true

            Write-Result `
                -Test "Write test" `
                -Status "FAIL" `
                -Message "Unable to write test data. Error: $($_.Exception.Message)"
        }

        # ----------------------------------------------------
        # READ BACK + HASH
        # ----------------------------------------------------

        if (Test-Path $testFile) {

            try {

                $hash1 = Get-FileHash `
                    -Path $testFile `
                    -Algorithm SHA256 `
                    -ErrorAction Stop

                $tempRead = Join-Path $env:TEMP "usbdiag-readback.bin"

                Copy-Item `
                    -Path $testFile `
                    -Destination $tempRead `
                    -Force `
                    -ErrorAction Stop

                $hash2 = Get-FileHash `
                    -Path $tempRead `
                    -Algorithm SHA256 `
                    -ErrorAction Stop

                Remove-Item $tempRead -Force -ErrorAction SilentlyContinue

                if ($hash1.Hash -eq $hash2.Hash) {

                    Write-Result `
                        -Test "Read verification" `
                        -Status "PASS" `
                        -Message "Data read back correctly and SHA-256 hashes match."

                }
                else {

                    $script:ReadVerificationFailure = $true

                    Write-Result `
                        -Test "Read verification" `
                        -Status "FAIL" `
                        -Message "Data corruption detected. SHA-256 hashes do not match."
                }

            }
            catch {

                $script:ReadVerificationFailure = $true

                Write-Result `
                    -Test "Read verification" `
                    -Status "FAIL" `
                    -Message "Could not reliably read the test file. $($_.Exception.Message)"
            }

            # ------------------------------------------------
            # CLEANUP
            # ------------------------------------------------

            try {

                Remove-Item `
                    -Path $testFile `
                    -Force `
                    -ErrorAction Stop

                Remove-Item `
                    -Path $testDirectory `
                    -Force `
                    -ErrorAction SilentlyContinue

                Write-Result `
                    -Test "Cleanup" `
                    -Status "PASS" `
                    -Message "Temporary test files removed."

            }
            catch {

                Write-Result `
                    -Test "Cleanup" `
                    -Status "WARN" `
                    -Message "Could not remove temporary diagnostic files."
            }
        }
    }
}
else {

    Write-Section "WRITE TEST"

    Write-Result `
        -Test "Write test" `
        -Status "INFO" `
        -Message "Skipped. Run with -WriteTest to perform a controlled write/read test."
}

# ------------------------------------------------------------
# OPTIONAL FILESYSTEM REPAIR
# ------------------------------------------------------------

if ($RepairFilesystem) {

    Write-Section "FILESYSTEM REPAIR"

    Write-Host ""
    Write-Host "WARNING: /F modifies the filesystem." -ForegroundColor Red

    $answer = Read-Host "Run CHKDSK repair? Type REPAIR"

    if ($answer -eq "REPAIR") {

        chkdsk "$DriveLetter`:" /f

    }
    else {

        Write-Result `
            -Test "Filesystem repair" `
            -Status "INFO" `
            -Message "Filesystem repair cancelled."
    }
}

# ------------------------------------------------------------
# FINAL DIAGNOSIS
# ------------------------------------------------------------

Write-Section "FINAL DIAGNOSIS"

$verdict = "UNKNOWN"
$reason = ""

# CASE 1:
# Physical disk itself reports serious failure.

if ($script:CriticalHardwareFailure) {

    $verdict = "REPLACE"

    $reason = "Windows reported a hardware/storage-level problem."
}

# CASE 2:
# Drive accepts writes but filesystem is damaged.

elseif ($script:WriteTestPassed -and $script:FilesystemProblem) {

    $verdict = "RECOVERABLE"

    $reason = "The drive accepts writes, but filesystem problems were detected."
}

# CASE 3:
# Software read-only but no hardware failure.

elseif ($script:SoftwareReadOnly -and -not $WriteTest) {

    $verdict = "RECOVERABLE"

    $reason = "The drive appears to be blocked by a Windows-level read-only setting. A write test is required to confirm hardware behavior."
}

# CASE 4:
# Write test explicitly failed.

elseif ($script:WriteFailure) {

    $verdict = "REPLACE"

    $reason = "The drive could not accept a controlled write. If Windows software write protection has already been ruled out, this strongly suggests controller or NAND failure."
}

# CASE 5:
# Writes work but data is corrupted.

elseif ($script:ReadVerificationFailure) {

    $verdict = "FAILING"

    $reason = "The drive accepted data but the data could not be read back reliably. This indicates possible NAND/controller or connection failure."
}

# CASE 6:
# Everything tested successfully.

elseif ($script:WriteTestPassed -and $script:DiskHealthy) {

    $verdict = "RECOVERABLE"

    $reason = "The drive is readable, writable, and passed the controlled read/write verification."
}

# CASE 7:
# No write test.

else {

    $verdict = "UNKNOWN"

    $reason = "The available non-destructive tests were insufficient to determine hardware reliability."
}

# ------------------------------------------------------------
# PRINT VERDICT
# ------------------------------------------------------------

switch ($verdict) {

    "RECOVERABLE" {

        Write-Host ""
        Write-Host "VERDICT: RECOVERABLE" -ForegroundColor Green
    }

    "FAILING" {

        Write-Host ""
        Write-Host "VERDICT: FAILING" -ForegroundColor Yellow
    }

    "REPLACE" {

        Write-Host ""
        Write-Host "VERDICT: REPLACE" -ForegroundColor Red
    }

    "UNKNOWN" {

        Write-Host ""
        Write-Host "VERDICT: UNKNOWN" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Reason:"
Write-Host $reason

Write-Host ""
Write-Host "Recommended action:"

switch ($verdict) {

    "RECOVERABLE" {

        Write-Host "  1. Back up important data."
        Write-Host "  2. If the problem is software-level read-only, clear the flag."
        Write-Host "  3. If filesystem corruption exists, repair it."
        Write-Host "  4. Run the write test again."
    }

    "FAILING" {

        Write-Host "  1. Copy important data immediately."
        Write-Host "  2. Do not store important data on this drive."
        Write-Host "  3. Test another USB port."
        Write-Host "  4. Test the drive on another computer."
        Write-Host "  5. Replace the drive if the failure follows the drive."
    }

    "REPLACE" {

        Write-Host "  1. Recover/copy important files immediately."
        Write-Host "  2. Do not trust the drive with new data."
        Write-Host "  3. Do not repeatedly format it."
        Write-Host "  4. Replace the drive."
    }

    "UNKNOWN" {

        Write-Host "  1. Run this script again with -WriteTest."
        Write-Host "  2. Test another USB port."
        Write-Host "  3. Test another computer."
        Write-Host "  4. Compare results."
    }
}

Write-Host ""
Write-Host "Diagnostic complete." -ForegroundColor Cyan
Write-Host ""