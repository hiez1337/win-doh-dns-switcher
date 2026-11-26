Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'TestHarness.ps1')

$projectRoot = Split-Path -Parent $PSScriptRoot
$cliPs1Path = Join-Path $projectRoot 'dns-switch.ps1'
$cliCmdPath = Join-Path $projectRoot 'dns-switch.cmd'
$richUiPath = Join-Path $projectRoot 'ui\rich_ui.py'
$libCommonPath = Join-Path $projectRoot 'lib\DnsCommon.psm1'
$backupDirPath = Join-Path $projectRoot 'backups'

$state = New-TestSuiteState -SuiteName 'integration-cli'
Write-Host ("Running {0} on host PowerShell {1}..." -f $state.SuiteName, $PSVersionTable.PSVersion.ToString())

function Find-Ps5Path {
    $cmd = Get-Command -Name 'powershell.exe' -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace($cmd.Source)) {
        return $cmd.Source
    }
    $fallback = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $fallback -PathType Leaf) {
        return $fallback
    }
    return $null
}

function Find-Pwsh7Path {
    $cmd = Get-Command -Name 'pwsh.exe' -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace($cmd.Source)) {
        return $cmd.Source
    }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'),
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
    )
    foreach ($c in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($c) -and (Test-Path -LiteralPath $c -PathType Leaf)) {
            return $c
        }
    }
    return $null
}

function Find-PythonWithRich {
    foreach ($spec in @(
        @{ Name = 'python.exe'; Prefix = '' },
        @{ Name = 'python'; Prefix = '' },
        @{ Name = 'py.exe'; Prefix = '-3' },
        @{ Name = 'py'; Prefix = '-3' }
    )) {
        $cmd = Get-Command -Name $spec.Name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace($cmd.Source)) {
            $probeArgs = if ([string]::IsNullOrEmpty($spec.Prefix)) {
                '-X utf8 -c "import rich"'
            } else {
                "$($spec.Prefix) -X utf8 -c `"import rich`""
            }
            $probe = Invoke-ExternalProcess -FilePath $cmd.Source -Arguments $probeArgs -WorkingDirectory $projectRoot -TimeoutMs 15000
            if ($probe.ExitCode -eq 0) {
                return [pscustomobject]@{
                    Exe    = $cmd.Source
                    Prefix = $spec.Prefix
                }
            }
        }
    }
    return $null
}

function Invoke-CliSubcommand {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeExe,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string]$CliArgs = '',
        [string]$StdInText = $null,
        [int]$TimeoutMs = 60000
    )
    $fullArgs = ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $ScriptPath, $CliArgs).Trim()
    if ($PSBoundParameters.ContainsKey('StdInText') -and $null -ne $StdInText) {
        return Invoke-ExternalProcess -FilePath $RuntimeExe -Arguments $fullArgs -WorkingDirectory (Split-Path -Parent $ScriptPath) -TimeoutMs $TimeoutMs -StdInText $StdInText
    }
    return Invoke-ExternalProcess -FilePath $RuntimeExe -Arguments $fullArgs -WorkingDirectory (Split-Path -Parent $ScriptPath) -TimeoutMs $TimeoutMs
}

$ps5Exe = Find-Ps5Path
$pwshExe = Find-Pwsh7Path
$pyRich = Find-PythonWithRich

Import-Module $libCommonPath -Force -ErrorAction Stop
$script:InitialVpn = Get-VpnTunnelState
$script:InitialBackupNames = @(Get-ChildItem -LiteralPath $backupDirPath -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -ExpandProperty Name)
$script:InitialTempFiles = @(Get-ChildItem -LiteralPath $env:TEMP -Filter 'dns_switch*' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)

Invoke-TestCase -State $state -Name 'CLI entrypoints exist, parse cleanly, ui/rich_ui.py compiles, and both PS 5.1 & PS 7.7 runtimes are present' {
    Assert-True (Test-Path -LiteralPath $cliPs1Path -PathType Leaf) "Missing CLI script: $cliPs1Path"
    Assert-True (Test-Path -LiteralPath $cliCmdPath -PathType Leaf) "Missing CMD launcher: $cliCmdPath"
    Assert-True (Test-Path -LiteralPath $richUiPath -PathType Leaf) "Missing Rich UI script: $richUiPath"

    $syn = Test-PowerShellSyntax -Path $cliPs1Path
    Assert-True $syn.Valid "dns-switch.ps1 syntax errors: $($syn.Errors -join '; ')"

    # Verify dns-switch.ps1 is either pure ASCII or UTF-8 with BOM (safe on PS 5.1)
    $bytes = [System.IO.File]::ReadAllBytes($cliPs1Path)
    $hasUtf8Bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if (-not $hasUtf8Bom) {
        $asc = Test-FilePureAscii -Path $cliPs1Path
        Assert-True $asc.IsPureAscii "dns-switch.ps1 has non-ASCII byte $($asc.FirstBadByteValue) without UTF-8 BOM (unsafe for PS 5.1)"
    }

    Assert-NotNull $ps5Exe 'powershell.exe (5.1) not found'
    Assert-NotNull $pwshExe 'pwsh.exe (7.7) not found'
    Assert-NotNull $pyRich 'Python with rich package not found'

    $pyCompileArgs = if ([string]::IsNullOrEmpty($pyRich.Prefix)) {
        ('-X utf8 -m py_compile "{0}"' -f $richUiPath)
    } else {
        ('{0} -X utf8 -m py_compile "{1}"' -f $pyRich.Prefix, $richUiPath)
    }
    $pyComp = Invoke-ExternalProcess -FilePath $pyRich.Exe -Arguments $pyCompileArgs -WorkingDirectory $projectRoot -TimeoutMs 15000
    Assert-Equal 0 $pyComp.ExitCode "ui/rich_ui.py py_compile failed: $($pyComp.Combined)"
}

if ((Test-Path -LiteralPath $cliPs1Path -PathType Leaf) -and (Test-Path -LiteralPath $cliCmdPath -PathType Leaf) -and $null -ne $ps5Exe -and $null -ne $pwshExe) {
    $runtimes = @(
        @{ Label = 'PS 5.1'; Exe = $ps5Exe },
        @{ Label = 'PS 7.7'; Exe = $pwshExe }
    )

    foreach ($rt in $runtimes) {
        $rtLabel = $rt.Label
        $rtExe = $rt.Exe

        Invoke-TestCase -State $state -Name "[$rtLabel] dns-switch.ps1 help returns exit 0 with subcommands" {
            $res = Invoke-CliSubcommand -RuntimeExe $rtExe -ScriptPath $cliPs1Path -CliArgs 'help'
            Assert-Equal 0 $res.ExitCode "help failed ($rtLabel): $($res.Combined)"
            foreach ($kw in @('status', 'list', 'check', 'probe', 'switch', 'reset', 'nrpt', 'backups')) {
                Assert-Match "(?i)\b$kw\b" $res.Combined "help missing subcommand '$kw' ($rtLabel)"
            }
        }

        Invoke-TestCase -State $state -Name "[$rtLabel] dns-switch.ps1 status -Json returns valid JSON with VpnState info" {
            $res = Invoke-CliSubcommand -RuntimeExe $rtExe -ScriptPath $cliPs1Path -CliArgs 'status -Json'
            Assert-Equal 0 $res.ExitCode "status -Json failed ($rtLabel): $($res.Combined)"
            $json = $res.StdOut | ConvertFrom-Json -ErrorAction Stop
            Assert-NotNull $json "status -Json parsed to null ($rtLabel)"
            Assert-NotNull $json.PSObject.Properties['VpnState'] "status -Json missing VpnState ($rtLabel)"
            Assert-True ($json.VpnState.IsActive -is [bool]) "status -Json VpnState.IsActive must be bool ($rtLabel)"
            Assert-True ($json.VpnState.AdapterPresent -is [bool]) "status -Json VpnState.AdapterPresent must be bool ($rtLabel)"
        }

        Invoke-TestCase -State $state -Name "[$rtLabel] dns-switch.ps1 status -NoRich uses plain PowerShell fallback" {
            $res = Invoke-CliSubcommand -RuntimeExe $rtExe -ScriptPath $cliPs1Path -CliArgs 'status -NoRich'
            Assert-Equal 0 $res.ExitCode "status -NoRich failed ($rtLabel): $($res.Combined)"
            Assert-Match '=== Windows 11 DNS & DoH Switcher Status ===' $res.Combined
            Assert-Match 'VPN / Tunnel:' $res.Combined
            Assert-Match 'NRPT Audit:' $res.Combined
        }

        Invoke-TestCase -State $state -Name "[$rtLabel] dns-switch.ps1 list -Json returns all 12 profiles" {
            $res = Invoke-CliSubcommand -RuntimeExe $rtExe -ScriptPath $cliPs1Path -CliArgs 'list -Json'
            Assert-Equal 0 $res.ExitCode "list -Json failed ($rtLabel): $($res.Combined)"
            $parsed = $res.StdOut | ConvertFrom-Json -ErrorAction Stop
            Assert-NotNull $parsed "list -Json parsed to null ($rtLabel)"
            $items = if ($null -ne $parsed.PSObject.Properties['profiles']) {
                @($parsed.profiles)
            } elseif ($null -ne $parsed.PSObject.Properties['Profiles']) {
                @($parsed.Profiles)
            } else {
                @($parsed)
            }
            Assert-Equal 12 $items.Count "Expected 12 profiles from list -Json ($rtLabel)"
            Assert-Match 'cloudflare' $res.StdOut
            Assert-Match 'geohide' $res.StdOut
            Assert-Match 'yandex' $res.StdOut
        }

        Invoke-TestCase -State $state -Name "[$rtLabel] dns-switch.ps1 check -Json returns valid JSON with RecommendedIds and 12 Results" {
            $res = Invoke-CliSubcommand -RuntimeExe $rtExe -ScriptPath $cliPs1Path -CliArgs 'check -Json'
            Assert-Equal 0 $res.ExitCode "check -Json failed ($rtLabel): $($res.Combined)"
            $parsed = $res.StdOut | ConvertFrom-Json -ErrorAction Stop
            Assert-NotNull $parsed "check -Json parsed to null ($rtLabel)"
            Assert-True ([bool]$parsed.Success) "check -Json Success should be true ($rtLabel)"
            Assert-False ([string]::IsNullOrWhiteSpace([string]$parsed.CheckedAt)) "check -Json missing CheckedAt ($rtLabel)"
            Assert-GreaterThan ([double]$parsed.DurationMs) 0 "check -Json DurationMs <= 0 ($rtLabel)"
            Assert-NotNull $parsed.RecommendedIds "check -Json missing RecommendedIds ($rtLabel)"
            Assert-Equal 12 (@($parsed.Results)).Count "check -Json expected 12 Results ($rtLabel)"
        }

        Invoke-TestCase -State $state -Name "[$rtLabel] dns-switch.ps1 probe -Target cloudflare -Quick -Json succeeds" {
            $res = Invoke-CliSubcommand -RuntimeExe $rtExe -ScriptPath $cliPs1Path -CliArgs 'probe -Target cloudflare -Quick -Json'
            Assert-Equal 0 $res.ExitCode "probe failed ($rtLabel): $($res.Combined)"
            $parsed = $res.StdOut | ConvertFrom-Json -ErrorAction Stop
            Assert-NotNull $parsed
            Assert-Match 'cloudflare' $res.StdOut
            Assert-Match '(?i)HEALTHY' $res.StdOut
        }

        Invoke-TestCase -State $state -Name "[$rtLabel] dns-switch.ps1 probe -Target geohide -Quick -Json reports Status and TlsAllPassed" {
            $res = Invoke-CliSubcommand -RuntimeExe $rtExe -ScriptPath $cliPs1Path -CliArgs 'probe -Target geohide -Quick -Json' -TimeoutMs 90000
            Assert-Equal 0 $res.ExitCode "probe geohide failed ($rtLabel): $($res.Combined)"
            $parsed = $res.StdOut | ConvertFrom-Json -ErrorAction Stop
            Assert-NotNull $parsed
            Assert-True ([bool]$parsed.Success)
            $items = @($parsed.Results)
            Assert-Equal 1 $items.Count "Expected 1 result for probe geohide ($rtLabel)"
            $item = $items[0]
            Assert-Equal 'geohide' ([string]$item.ProfileId)
            Assert-Contains @('HEALTHY', 'DEGRADED', 'UNHEALTHY') ([string]$item.Status) "Unexpected status '$($item.Status)'"
            if ([string]$item.Status -eq 'HEALTHY') {
                Assert-True ([bool]$item.TlsAllPassed) "Expected TlsAllPassed=$true when geohide Status=HEALTHY ($rtLabel)"
            }
        }

        Invoke-TestCase -State $state -Name "[$rtLabel] dns-switch.ps1 switch cloudflare -DryRun succeeds without mutation" {
            $res = Invoke-CliSubcommand -RuntimeExe $rtExe -ScriptPath $cliPs1Path -CliArgs 'switch cloudflare -DryRun'
            Assert-Equal 0 $res.ExitCode "switch cloudflare -DryRun failed ($rtLabel): $($res.Combined)"
            Assert-Match '(?i)cloudflare' $res.Combined
            Assert-Match '(?i)dry[- ]?run' $res.Combined
        }

        Invoke-TestCase -State $state -Name "[$rtLabel] dns-switch.ps1 switch nonexistent exits non-zero" {
            $res = Invoke-CliSubcommand -RuntimeExe $rtExe -ScriptPath $cliPs1Path -CliArgs 'switch nonexistent'
            Assert-True ($res.ExitCode -ne 0) "Expected non-zero exit code for nonexistent profile ($rtLabel), got $($res.ExitCode)"
            Assert-Match '(?i)(unknown|not found|nonexistent|error)' $res.Combined
        }

        Invoke-TestCase -State $state -Name "[$rtLabel] dns-switch.ps1 -ElevationLogPath saves text status and JSON error cleanly" {
            $tag = [guid]::NewGuid().ToString('N')
            $textLogPath = Join-Path $env:TEMP ("dns_switch_test_elev_text_{0}.log" -f $tag)
            $jsonLogPath = Join-Path $env:TEMP ("dns_switch_test_elev_json_{0}.log" -f $tag)
            try {
                $statusRes = Invoke-CliSubcommand -RuntimeExe $rtExe -ScriptPath $cliPs1Path -CliArgs ('status -ElevationLogPath "{0}"' -f $textLogPath)
                Assert-Equal 0 $statusRes.ExitCode "status -ElevationLogPath failed ($rtLabel): $($statusRes.Combined)"
                Assert-True (Test-Path -LiteralPath $textLogPath -PathType Leaf) "Expected text elevation log file to exist ($rtLabel): $textLogPath"
                $statusLogText = [System.IO.File]::ReadAllText($textLogPath, [System.Text.Encoding]::UTF8)
                Assert-Match '=== Windows 11 DNS & DoH Switcher Status ===' $statusLogText "Text elevation log missing status header ($rtLabel)"
                Assert-Match 'VPN / Tunnel:' $statusLogText "Text elevation log missing VPN / Tunnel line ($rtLabel)"
                Assert-Match 'NRPT Audit:' $statusLogText "Text elevation log missing NRPT Audit line ($rtLabel)"

                $errRes = Invoke-CliSubcommand -RuntimeExe $rtExe -ScriptPath $cliPs1Path -CliArgs ('switch nonexistent -NoElevate -Json -ElevationLogPath "{0}"' -f $jsonLogPath)
                Assert-True ($errRes.ExitCode -ne 0) "Expected non-zero exit code for switch nonexistent -NoElevate -Json -ElevationLogPath ($rtLabel), got $($errRes.ExitCode)"
                Assert-True (Test-Path -LiteralPath $jsonLogPath -PathType Leaf) "Expected JSON elevation log file to exist ($rtLabel): $jsonLogPath"
                $errLogText = [System.IO.File]::ReadAllText($jsonLogPath, [System.Text.Encoding]::UTF8)
                Assert-False ([string]::IsNullOrWhiteSpace($errLogText)) "JSON elevation log file was empty ($rtLabel)"
                $errJson = $errLogText | ConvertFrom-Json -ErrorAction Stop
                Assert-NotNull $errJson "JSON elevation log parsed to null ($rtLabel)"
                Assert-False ([bool]$errJson.Success) "Expected Success=false in JSON elevation log ($rtLabel)"
                Assert-True ([int]$errJson.ExitCode -ne 0) "Expected non-zero ExitCode in JSON elevation log ($rtLabel)"
                Assert-Match '(?i)(unknown|not found|nonexistent|error)' ([string]$errJson.Error) "Unexpected Error field in JSON elevation log ($rtLabel)"
            } finally {
                foreach ($p in @($textLogPath, $jsonLogPath)) {
                    if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path -LiteralPath $p -PathType Leaf)) {
                        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }

        Invoke-TestCase -State $state -Name "[$rtLabel] dns-switch.ps1 reset -DryRun succeeds without mutation" {
            $res = Invoke-CliSubcommand -RuntimeExe $rtExe -ScriptPath $cliPs1Path -CliArgs 'reset -DryRun'
            Assert-Equal 0 $res.ExitCode "reset -DryRun failed ($rtLabel): $($res.Combined)"
            Assert-Match '(?i)dry[- ]?run' $res.Combined
            Assert-Match '(?i)(ResetToDhcp|DHCP)' $res.Combined
        }

        Invoke-TestCase -State $state -Name "[$rtLabel] dns-switch.ps1 nrpt status succeeds" {
            $res = Invoke-CliSubcommand -RuntimeExe $rtExe -ScriptPath $cliPs1Path -CliArgs 'nrpt status'
            Assert-Equal 0 $res.ExitCode "nrpt status failed ($rtLabel): $($res.Combined)"
            Assert-Match '(?i)nrpt' $res.Combined
        }

        Invoke-TestCase -State $state -Name "[$rtLabel] dns-switch.ps1 backups list and backups list -Json work without touching backups/" {
            $res = Invoke-CliSubcommand -RuntimeExe $rtExe -ScriptPath $cliPs1Path -CliArgs 'backups list'
            Assert-Equal 0 $res.ExitCode "backups list failed ($rtLabel): $($res.Combined)"

            $resJson = Invoke-CliSubcommand -RuntimeExe $rtExe -ScriptPath $cliPs1Path -CliArgs 'backups list -Json'
            Assert-Equal 0 $resJson.ExitCode "backups list -Json failed ($rtLabel): $($resJson.Combined)"
            $parsed = $resJson.StdOut | ConvertFrom-Json -ErrorAction Stop
            Assert-True ([bool]$parsed.Success)
            Assert-Equal $script:InitialBackupNames.Count ([int]$parsed.Count) "backups list -Json count mismatch ($rtLabel)"
        }

        Invoke-TestCase -State $state -Name "[$rtLabel] Interactive menu piped 'q' renders Rich dashboard and exits 0" {
            $res = Invoke-CliSubcommand -RuntimeExe $rtExe -ScriptPath $cliPs1Path -CliArgs '-DryRun' -StdInText "q`n" -TimeoutMs 90000
            Assert-Equal 0 $res.ExitCode "Interactive menu 'q' failed ($rtLabel): $($res.Combined)"
            Assert-Match 'Antigravity' $res.Combined
            Assert-Match 'VPN' $res.Combined
            Assert-Match 'cloudflare' $res.Combined
            Assert-Match 'geohide' $res.Combined
            if ($null -ne $pyRich) {
                Assert-Match '\u041c\u0430\u0441\u0442\u0435\u0440 DNS' $res.Combined "Expected Rich Russian header in menu ($rtLabel)"
            }
        }

        Invoke-TestCase -State $state -Name "[$rtLabel] Interactive menu piped 'r\nb\nq' skips Press Enter after 'b' and exits 0" {
            $res = Invoke-CliSubcommand -RuntimeExe $rtExe -ScriptPath $cliPs1Path -CliArgs '-DryRun' -StdInText "r`nb`nq`n" -TimeoutMs 90000
            Assert-Equal 0 $res.ExitCode "Interactive menu 'r\\nb\\nq' failed ($rtLabel): $($res.Combined)"
            Assert-Match 'Antigravity' $res.Combined
            if ($null -ne $pyRich) {
                Assert-Match '\u041c\u0430\u0441\u0442\u0435\u0440 DNS' $res.Combined "Expected Rich Russian header in menu ($rtLabel)"
            }
            Assert-False ($res.Combined -match '(?i)Press Enter') "Unexpected English 'Press Enter' prompt after 'b' ($rtLabel)"
            Assert-False ($res.Combined -match '\u041d\u0430\u0436\u043c\u0438\u0442\u0435 Enter') "Unexpected Russian 'Press Enter' prompt after 'b' ($rtLabel)"
        }
    }

    Invoke-TestCase -State $state -Name 'dns-switch.cmd status -Json executes cleanly via cmd.exe and emits valid JSON' {
        $cmdArgs = ('/c ""{0}" status -Json"' -f $cliCmdPath)
        $res = Invoke-ExternalProcess -FilePath 'cmd.exe' -Arguments $cmdArgs -WorkingDirectory $projectRoot -TimeoutMs 60000
        Assert-Equal 0 $res.ExitCode "dns-switch.cmd status -Json failed: $($res.Combined)"
        $json = $res.StdOut | ConvertFrom-Json -ErrorAction Stop
        Assert-NotNull $json
        Assert-NotNull $json.PSObject.Properties['VpnState']
        Assert-True ($json.VpnState.IsActive -is [bool])
    }

    Invoke-TestCase -State $state -Name 'Post-CLI check: VPN state, backups/, and TEMP are clean and unchanged' {
        $vpnAfter = Get-VpnTunnelState
        Assert-Equal ([bool]$script:InitialVpn.IsActive) ([bool]$vpnAfter.IsActive) 'VPN IsActive changed during CLI tests'
        Assert-Equal ([bool]$script:InitialVpn.AdapterPresent) ([bool]$vpnAfter.AdapterPresent) 'VPN AdapterPresent changed during CLI tests'
        Assert-Equal ([string]$script:InitialVpn.AdapterStatus) ([string]$vpnAfter.AdapterStatus) 'VPN AdapterStatus changed during CLI tests'
        Assert-Equal ([string]$script:InitialVpn.AdapterName) ([string]$vpnAfter.AdapterName) 'VPN AdapterName changed during CLI tests'

        $backupsAfter = @(Get-ChildItem -LiteralPath $backupDirPath -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -ExpandProperty Name)
        Assert-Equal ($script:InitialBackupNames -join '|') ($backupsAfter -join '|') 'backups/ directory was modified during CLI tests'

        $tempAfter = @(Get-ChildItem -LiteralPath $env:TEMP -Filter 'dns_switch*' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        $newTemps = @($tempAfter | Where-Object { $script:InitialTempFiles -notcontains $_ })
        Assert-Equal 0 $newTemps.Count "Leftover temp files in `$env:TEMP: $($newTemps -join ', ')"
    }
}

$exitCode = Complete-TestSuite -State $state
exit $exitCode
