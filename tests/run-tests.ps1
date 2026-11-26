[CmdletBinding()]
param(
    [ValidateSet('all', 'unit', 'integration')]
    [string]$Suite = 'all'
)

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'TestHarness.ps1')

$hostExe = (Get-Process -Id $PID -ErrorAction Stop).Path
if ([string]::IsNullOrWhiteSpace($hostExe)) {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $hostExe = 'pwsh.exe'
    } else {
        $hostExe = 'powershell.exe'
    }
}

$testFiles = switch ($Suite) {
    'unit'        { @('unit-config.ps1', 'unit-lib.ps1') }
    'integration' { @('integration-cli.ps1') }
    default       { @('unit-config.ps1', 'unit-lib.ps1', 'integration-cli.ps1') }
}

$overallSw = [System.Diagnostics.Stopwatch]::StartNew()
$totalSuites = 0
$passedSuites = 0
$failedSuites = 0
$grandTotal = 0
$grandPassed = 0
$grandFailed = 0
$failedFiles = New-Object System.Collections.Generic.List[string]

Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ("DNS Switcher Test Suite | Host: {0} ({1})" -f $PSVersionTable.PSVersion.ToString(), $hostExe) -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan

foreach ($file in $testFiles) {
    $fullPath = Join-Path $PSScriptRoot $file
    $totalSuites++
    Write-Host ''
    Write-Host ("--- Running {0} ---" -f $file) -ForegroundColor Yellow

    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        Write-Host ("  [FAIL] Test file not found: {0}" -f $fullPath) -ForegroundColor Red
        $failedSuites++
        $grandTotal++
        $grandFailed++
        $failedFiles.Add($file)
        continue
    }

    $argLine = ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $fullPath)
    $procRes = Invoke-ExternalProcess -FilePath $hostExe -Arguments $argLine -WorkingDirectory $PSScriptRoot -TimeoutMs 300000

    $summaryObj = $null
    $lines = $procRes.StdOut -split "`r?`n"
    foreach ($line in $lines) {
        if ($line -like '__TEST_SUMMARY__*') {
            $jsonPart = $line.Substring(16)
            try {
                $summaryObj = $jsonPart | ConvertFrom-Json
            } catch {
                $summaryObj = $null
            }
        } elseif (-not [string]::IsNullOrEmpty($line)) {
            Write-Host $line
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($procRes.StdErr)) {
        Write-Host $procRes.StdErr.TrimEnd() -ForegroundColor Red
    }

    if ($null -ne $summaryObj) {
        $grandTotal += [int]$summaryObj.total
        $grandPassed += [int]$summaryObj.passed
        $grandFailed += [int]$summaryObj.failed
    } else {
        Write-Host ("  [FAIL] Missing __TEST_SUMMARY__ output from {0} (ExitCode={1})" -f $file, $procRes.ExitCode) -ForegroundColor Red
        $grandTotal++
        $grandFailed++
    }

    if ($procRes.ExitCode -eq 0 -and $null -ne $summaryObj -and [int]$summaryObj.failed -eq 0) {
        $passedSuites++
    } else {
        $failedSuites++
        $failedFiles.Add($file)
    }
}

$overallSw.Stop()
$overallMs = [math]::Round($overallSw.Elapsed.TotalMilliseconds, 1)

Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
$finalColor = if ($failedSuites -eq 0 -and $grandFailed -eq 0) { 'Green' } else { 'Red' }
Write-Host ("TOTAL FILES: {0} (Passed: {1}, Failed: {2})" -f $totalSuites, $passedSuites, $failedSuites) -ForegroundColor $finalColor
Write-Host ("TOTAL TESTS: {0} (Passed: {1}, Failed: {2}) in {3}ms" -f $grandTotal, $grandPassed, $grandFailed, $overallMs) -ForegroundColor $finalColor
if ($failedFiles.Count -gt 0) {
    Write-Host ("FAILED FILES: {0}" -f ($failedFiles -join ', ')) -ForegroundColor Red
}
Write-Host '================================================================' -ForegroundColor Cyan

if ($failedSuites -eq 0 -and $grandFailed -eq 0) {
    exit 0
}
exit 1
