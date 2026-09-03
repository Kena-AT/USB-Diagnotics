# USB-Diagnostics

This project contains a set of PowerShell scripts designed to diagnose and troubleshoot issues with USB flash drives, particularly those exhibiting read-only symptoms or potential hardware failure.

## Scripts

### 1. USB-Diagnostic_v1.ps1
The initial version of the diagnostic tool. It performs basic checks on disk detection, read-only states, Windows write-protection policies, filesystem integrity, and USB device status. It includes an optional, non-destructive write/read verification test.

### 2. USB-Diagnostic_v2.ps1
An improved version with enhanced error handling, a DiskPart cross-check for verifying read-only status, more detailed storage reliability reporting, and improved final diagnostic classification.

### 3. USB-Diagnostic_v2.1.ps1
The current recommended version. It builds upon v2.0 by providing more granular error classification (distinguishing between write-protection and media errors), improved cleanup of temporary files, more robust storage event log analysis, and refined final diagnostic logic.

## Usage

Run these scripts from an Administrator PowerShell prompt for the most complete results.

### Basic Run
To run the diagnostic on a detected drive (the script will prompt you if not specified):

```powershell
.\USB-Diagnostic_v2.1.ps1
```

Or specifying the drive letter:

```powershell
.\USB-Diagnostic_v2.1.ps1 -DriveLetter E
```

### Performing a Write Test
To perform a non-destructive write/read verification test (writes temporary test data to the drive):

```powershell
.\USB-Diagnostic_v2.1.ps1 -DriveLetter E -WriteTest
```

You can also specify the test size (in MB):

```powershell
.\USB-Diagnostic_v2.1.ps1 -DriveLetter E -WriteTest -TestSizeMB 100
```

### Attempting to Clear Read-Only Flag
If a drive is identified as read-only, you can attempt to clear the flag:

```powershell
.\USB-Diagnostic_v2.1.ps1 -DriveLetter E -WriteTest -AttemptClearReadOnly
```
