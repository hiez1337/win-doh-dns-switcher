Set-StrictMode -Version Latest

function New-TestSuiteState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SuiteName
    )

    return [pscustomobject]@{
        SuiteName  = $SuiteName
        Total      = 0
        Passed     = 0
        Failed     = 0
        Stopwatch  = [System.Diagnostics.Stopwatch]::StartNew()
        Failures   = (New-Object System.Collections.Generic.List[object])
    }
}

function Invoke-TestCase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    $State.Total++
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $ScriptBlock
        $sw.Stop()
        $State.Passed++
        $ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        Write-Host ("  [PASS] {0} ({1}ms)" -f $Name, $ms) -ForegroundColor Green
    } catch {
        $sw.Stop()
        $State.Failed++
        $ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        $msg = $_.Exception.Message
        $State.Failures.Add([pscustomobject]@{
            Name    = $Name
            Message = $msg
        })
        Write-Host ("  [FAIL] {0} ({1}ms): {2}" -f $Name, $ms, $msg) -ForegroundColor Red
    }
}

function Assert-True {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]$Condition,
        [string]$Message = 'Expected condition to be true.'
    )
    if (-not [bool]$Condition) {
        throw $Message
    }
}

function Assert-False {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]$Condition,
        [string]$Message = 'Expected condition to be false.'
    )
    if ([bool]$Condition) {
        throw $Message
    }
}

function Assert-NotNull {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]$Value,
        [string]$Message = 'Expected value not to be null.'
    )
    if ($null -eq $Value) {
        throw $Message
    }
}

function Assert-Equal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]$Expected,
        [Parameter(Mandatory = $false)]$Actual,
        [string]$Message = ''
    )
    if ($Expected -ne $Actual) {
        $prefix = if ([string]::IsNullOrWhiteSpace($Message)) { 'Values differ' } else { $Message }
        throw "$prefix. Expected: [$Expected], Actual: [$Actual]."
    }
}

function Assert-GreaterThan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][double]$Actual,
        [Parameter(Mandatory = $true)][double]$Minimum,
        [string]$Message = ''
    )
    if (-not ($Actual -gt $Minimum)) {
        $prefix = if ([string]::IsNullOrWhiteSpace($Message)) { 'Expected value > minimum' } else { $Message }
        throw "$prefix. Actual: [$Actual], Minimum (exclusive): [$Minimum]."
    }
}

function Assert-Match {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Actual,
        [string]$Message = ''
    )
    if ($Actual -notmatch $Pattern) {
        $prefix = if ([string]::IsNullOrWhiteSpace($Message)) { 'Pattern mismatch' } else { $Message }
        throw "$prefix. Pattern: [$Pattern], Actual: [$Actual]."
    }
}

function Assert-Contains {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]$Collection,
        [Parameter(Mandatory = $false)]$Item,
        [string]$Message = ''
    )
    $arr = @($Collection)
    if ($arr -notcontains $Item) {
        $prefix = if ([string]::IsNullOrWhiteSpace($Message)) { 'Collection missing expected item' } else { $Message }
        throw "$prefix. Expected item: [$Item]. Collection: [$($arr -join ', ')]."
    }
}

function Assert-NotContains {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]$Collection,
        [Parameter(Mandatory = $false)]$Item,
        [string]$Message = ''
    )
    $arr = @($Collection)
    if ($arr -contains $Item) {
        $prefix = if ([string]::IsNullOrWhiteSpace($Message)) { 'Collection contains forbidden item' } else { $Message }
        throw "$prefix. Forbidden item: [$Item]."
    }
}

function Assert-Throws {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [string]$ExpectedPattern = '',
        [string]$Message = 'Expected scriptblock to throw an exception.'
    )
    $threw = $false
    $errMsg = ''
    try {
        & $ScriptBlock | Out-Null
    } catch {
        $threw = $true
        $errMsg = $_.Exception.Message
    }
    if (-not $threw) {
        throw $Message
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPattern) -and ($errMsg -notmatch $ExpectedPattern)) {
        throw "Exception message did not match pattern [$ExpectedPattern]. Actual message: [$errMsg]."
    }
}

function Test-FilePureAscii {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -gt 127) {
            return [pscustomobject]@{
                IsPureAscii = $false
                FirstBadByteOffset = $i
                FirstBadByteValue  = [int]$bytes[$i]
            }
        }
    }
    return [pscustomobject]@{
        IsPureAscii = $true
        FirstBadByteOffset = -1
        FirstBadByteValue  = 0
    }
}

function Test-PowerShellSyntax {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $errList = @($errors)
    return [pscustomobject]@{
        Valid  = ($errList.Count -eq 0)
        Errors = @($errList | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" })
    }
}

function Invoke-ExternalProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [string]$WorkingDirectory = '',
        [int]$TimeoutMs = 60000,
        [string]$StdInText = $null
    )

    $useStdIn = ($PSBoundParameters.ContainsKey('StdInText') -and $null -ne $StdInText)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $useStdIn
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $psi.WorkingDirectory = $WorkingDirectory
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    [void]$proc.Start()
    if ($useStdIn) {
        $proc.StandardInput.Write($StdInText)
        $proc.StandardInput.Close()
    }
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $exited = $proc.WaitForExit($TimeoutMs)
    if (-not $exited) {
        try { $proc.Kill() } catch {}
        throw "Process '$FilePath $Arguments' timed out after ${TimeoutMs}ms."
    }
    $proc.WaitForExit()
    $sw.Stop()

    $stdout = $outTask.GetAwaiter().GetResult()
    $stderr = $errTask.GetAwaiter().GetResult()
    $exitCode = [int]$proc.ExitCode
    $proc.Dispose()

    return [pscustomobject]@{
        ExitCode   = $exitCode
        StdOut     = $stdout
        StdErr     = $stderr
        Combined   = ($stdout + "`n" + $stderr).Trim()
        DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
    }
}

function Complete-TestSuite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State
    )

    $State.Stopwatch.Stop()
    $durationMs = [math]::Round($State.Stopwatch.Elapsed.TotalMilliseconds, 1)

    Write-Host ''
    $color = if ($State.Failed -eq 0) { 'Green' } else { 'Red' }
    Write-Host ("Suite [{0}]: Total={1}, Passed={2}, Failed={3}, Duration={4}ms" -f $State.SuiteName, $State.Total, $State.Passed, $State.Failed, $durationMs) -ForegroundColor $color

    if ($State.Failed -gt 0) {
        Write-Host 'Failures:' -ForegroundColor Red
        foreach ($f in $State.Failures) {
            Write-Host ("  - {0}: {1}" -f $f.Name, $f.Message) -ForegroundColor Red
        }
    }

    $summary = [ordered]@{
        suite      = $State.SuiteName
        total      = $State.Total
        passed     = $State.Passed
        failed     = $State.Failed
        durationMs = $durationMs
    }
    [Console]::Out.WriteLine('__TEST_SUMMARY__' + ($summary | ConvertTo-Json -Compress))

    if ($State.Failed -gt 0) {
        return 1
    }
    return 0
}
