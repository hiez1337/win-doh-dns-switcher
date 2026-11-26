<#
.SYNOPSIS
    Windows 11 DNS & Native DoH Switcher for Antigravity / Google AI + any VPN/TUN.

.DESCRIPTION
    Dual-compatible CLI and interactive switcher (Windows PowerShell 5.1 & PowerShell 7+)
    backed by config\profiles.json and lib\*.psm1.
    Never disconnects, stops, or restarts any VPN client, service, or TUN/RAS tunnel.

.EXAMPLE
    .\dns-switch.ps1 status
    .\dns-switch.ps1 list -Category vpn-clean
    .\dns-switch.ps1 probe -Target cloudflare -Quick
    .\dns-switch.ps1 switch cloudflare -DryRun
    .\dns-switch.ps1 switch geohide -CleanNrpt
    .\dns-switch.ps1 reset -DryRun
    .\dns-switch.ps1 nrpt status
    .\dns-switch.ps1 backups list
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)]
    [Alias('Command')]
    [string]$Action,

    [Parameter(Position = 1)]
    [string]$SubArg,

    [Parameter(Position = 2)]
    [string]$ThirdArg,

    [Alias('Id', 'Profile')]
    [string]$ProfileId,

    [string]$Target,

    [ValidateSet('all', 'vpn-clean', 'rf-smart', 'rf-clean')]
    [string]$Category,

    [switch]$All,
    [switch]$Quick,

    [ValidateSet('auto', 'vpn', 'ethernet', 'both', 'custom')]
    [string]$TargetMode = 'auto',

    [string[]]$AdapterNames = @(),

    [ValidateSet('auto', 'true', 'false')]
    [string]$AllowUdpFallback = 'auto',

    [switch]$CleanNrpt,
    [switch]$SkipPreflight,

    [string]$BackupPath,
    [string]$Label = 'manual',
    [switch]$ReplaceExisting,
    [switch]$SkipNrpt,
    [switch]$SkipDohTemplates,

    [switch]$DryRun,
    [switch]$NoElevate,
    [switch]$Json,
    [switch]$NoRich,
    [switch]$Availability,
    [string]$ElevationLogPath,

    [Alias('h')]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProjectRoot = $PSScriptRoot
$script:ConfigPath = Join-Path $script:ProjectRoot 'config\profiles.json'
$script:BackupDir = Join-Path $script:ProjectRoot 'backups'
$script:RichUiScriptPath = Join-Path (Join-Path $script:ProjectRoot 'ui') 'rich_ui.py'
$script:RichRuntimeCached = $null
$script:ConsoleVtInitialized = $false
$script:ExitCode = 0
$script:IsWhatIf = [bool]$WhatIfPreference
$WhatIfPreference = $false
$script:HasCategoryParam = $PSBoundParameters.ContainsKey('Category')
$script:ElevationLogLines = New-Object System.Collections.Generic.List[string]
$script:ElevationLogPending = ''
$script:ElevationJsonText = $null
$script:QuickProbeDomains = @(
    'cloudcode-pa.googleapis.com',
    'daily-cloudcode-pa.googleapis.com',
    'generativelanguage.googleapis.com',
    'antigravity.google',
    'accounts.google.com'
)

function ConvertFrom-EscapedText {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }
    return [System.Text.RegularExpressions.Regex]::Unescape($Text)
}

function Get-RichUiRuntime {
    if ($null -ne $script:RichRuntimeCached) {
        return $script:RichRuntimeCached
    }

    if (-not (Test-Path -LiteralPath $script:RichUiScriptPath -PathType Leaf)) {
        $script:RichRuntimeCached = [pscustomobject]@{
            Available  = $false
            Exe        = $null
            PrefixArgs = @()
        }
        return $script:RichRuntimeCached
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    $seenPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($spec in @(
        @{ Name = 'python.exe'; Prefix = @() },
        @{ Name = 'python';     Prefix = @() },
        @{ Name = 'py.exe';     Prefix = @('-3') },
        @{ Name = 'py';         Prefix = @('-3') }
    )) {
        $cmd = Get-Command -Name $spec.Name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace($cmd.Source) -and $seenPaths.Add($cmd.Source)) {
            $candidates.Add([pscustomobject]@{
                Path       = $cmd.Source
                PrefixArgs = @($spec.Prefix)
            })
        }
    }

    foreach ($cand in $candidates) {
        $prevErrPref = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $probeArgs = @($cand.PrefixArgs) + @('-X', 'utf8', '-c', 'import rich')
            $null = & $cand.Path @probeArgs 2>$null
            if ($LASTEXITCODE -eq 0) {
                $script:RichRuntimeCached = [pscustomobject]@{
                    Available  = $true
                    Exe        = $cand.Path
                    PrefixArgs = @($cand.PrefixArgs)
                }
                return $script:RichRuntimeCached
            }
        } catch {
            # Try next Python candidate.
        } finally {
            $ErrorActionPreference = $prevErrPref
        }
    }

    $script:RichRuntimeCached = [pscustomobject]@{
        Available  = $false
        Exe        = $null
        PrefixArgs = @()
    }
    return $script:RichRuntimeCached
}

function Test-ShouldUseRichUi {
    if ($Json.IsPresent -or $NoRich.IsPresent -or -not [string]::IsNullOrWhiteSpace($ElevationLogPath)) {
        return $false
    }
    $rt = Get-RichUiRuntime
    return [bool]$rt.Available
}

function Enable-ConsoleVirtualTerminal {
    if ($script:ConsoleVtInitialized) {
        return
    }
    $script:ConsoleVtInitialized = $true
    try {
        if ($null -eq ('DnsSwitcher.ConsoleVtHelper' -as [type])) {
            $vtCode = @'
using System;
using System.Runtime.InteropServices;

namespace DnsSwitcher {
    public static class ConsoleVtHelper {
        private const int STD_OUTPUT_HANDLE = -11;
        private const uint ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetStdHandle(int nStdHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

        public static bool Enable() {
            IntPtr handle = GetStdHandle(STD_OUTPUT_HANDLE);
            if (handle == IntPtr.Zero || handle == new IntPtr(-1)) {
                return false;
            }
            uint mode;
            if (!GetConsoleMode(handle, out mode)) {
                return false;
            }
            if ((mode & ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0) {
                return true;
            }
            return SetConsoleMode(handle, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
        }
    }
}
'@
            Add-Type -TypeDefinition $vtCode -ErrorAction Stop | Out-Null
        }
        $null = [DnsSwitcher.ConsoleVtHelper]::Enable()
    } catch {
        # Ignore when running without an interactive Win32 console handle.
    }
}

function Get-ConsoleRenderWidth {
    $width = 0
    try {
        if ($null -ne $Host -and $null -ne $Host.UI -and $null -ne $Host.UI.RawUI) {
            $rawWidth = [int]$Host.UI.RawUI.WindowSize.Width
            if ($rawWidth -gt 0) {
                $width = $rawWidth
            }
        }
    } catch {
        $width = 0
    }

    if ($width -le 0) {
        try {
            $conWidth = [int][Console]::WindowWidth
            if ($conWidth -gt 0) {
                $width = $conWidth
            }
        } catch {
            $width = 0
        }
    }

    if ($width -le 0 -and -not [string]::IsNullOrWhiteSpace($env:COLUMNS)) {
        $parsedWidth = 0
        if ([int]::TryParse([string]$env:COLUMNS, [ref]$parsedWidth) -and $parsedWidth -gt 0) {
            $width = $parsedWidth
        }
    }

    return $width
}

function Invoke-RichUiView {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('menu', 'status', 'probe', 'switch', 'reset', 'nrpt', 'backups', 'help')]
        [string]$View,
        [Parameter(Mandatory = $true)]$Payload
    )

    if (-not (Test-ShouldUseRichUi)) {
        return $false
    }

    $rt = Get-RichUiRuntime
    if (-not $rt.Available) {
        return $false
    }

    $tempDir = if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
    $tmpJsonPath = Join-Path $tempDir ("dns_switch_ui_{0}.json" -f ([Guid]::NewGuid().ToString('N')))
    $prevErrPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        try {
            [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        } catch {
            # Ignore in non-console hosts.
        }

        $jsonText = $Payload | ConvertTo-Json -Depth 16 -Compress
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tmpJsonPath, $jsonText, $utf8NoBom)

        $pyArgs = New-Object System.Collections.Generic.List[string]
        foreach ($pa in @($rt.PrefixArgs)) {
            $pyArgs.Add([string]$pa)
        }
        $pyArgs.Add('-X')
        $pyArgs.Add('utf8')
        $pyArgs.Add($script:RichUiScriptPath)
        $pyArgs.Add('--view')
        $pyArgs.Add($View)
        $pyArgs.Add('--input')
        $pyArgs.Add($tmpJsonPath)

        $renderWidth = Get-ConsoleRenderWidth
        if ($renderWidth -ge 72) {
            $clampedWidth = [Math]::Min([Math]::Max($renderWidth, 72), 140)
            $pyArgs.Add('--width')
            $pyArgs.Add([string]$clampedWidth)
        }

        if (-not $NoRich.IsPresent -and [string]::IsNullOrWhiteSpace($env:NO_COLOR)) {
            Enable-ConsoleVirtualTerminal
            $pyArgs.Add('--force-color')
        }

        & $rt.Exe @pyArgs | Out-Host
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $prevErrPref
        if (Test-Path -LiteralPath $tmpJsonPath -PathType Leaf) {
            Remove-Item -LiteralPath $tmpJsonPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-ObjectHasProperty {
    param(
        $InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $InputObject) {
        return $false
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject.Contains($Name)
    }
    return ($null -ne $InputObject.PSObject.Properties[$Name])
}

function Get-SafePropertyValue {
    param(
        $InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )
    if ($null -eq $InputObject) {
        return $Default
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }
        return $Default
    }
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $prop) {
        return $prop.Value
    }
    return $Default
}

function Write-CliHost {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [object]$Object = '',
        [System.ConsoleColor]$ForegroundColor,
        [switch]$NoNewline
    )
    $whParams = @{ Object = $Object }
    if ($PSBoundParameters.ContainsKey('ForegroundColor')) {
        $whParams['ForegroundColor'] = $ForegroundColor
    }
    if ($NoNewline) {
        $whParams['NoNewline'] = $true
    }
    Microsoft.PowerShell.Utility\Write-Host @whParams

    if (-not [string]::IsNullOrWhiteSpace($ElevationLogPath)) {
        $text = if ($null -eq $Object) { '' } else { [string]$Object }
        if ($NoNewline) {
            $script:ElevationLogPending += $text
        } else {
            $fullLine = $script:ElevationLogPending + $text
            $script:ElevationLogPending = ''
            $script:ElevationLogLines.Add($fullLine)
        }
    }
}

function Save-ElevationLog {
    if ([string]::IsNullOrWhiteSpace($ElevationLogPath)) {
        return
    }
    try {
        $parentDir = Split-Path -Parent $ElevationLogPath
        if (-not [string]::IsNullOrWhiteSpace($parentDir) -and -not (Test-Path -LiteralPath $parentDir -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $parentDir -Force)
        }
        $contentToWrite = ''
        if ($null -ne $script:ElevationJsonText) {
            $contentToWrite = $script:ElevationJsonText
        } else {
            $lines = New-Object System.Collections.Generic.List[string]
            foreach ($ln in $script:ElevationLogLines) {
                $lines.Add($ln)
            }
            if (-not [string]::IsNullOrEmpty($script:ElevationLogPending)) {
                $lines.Add($script:ElevationLogPending)
            }
            $contentToWrite = ($lines.ToArray()) -join [Environment]::NewLine
        }
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($ElevationLogPath, $contentToWrite, $utf8NoBom)
    } catch {
        # Best-effort logging only; never mask the primary CLI exit code.
    }
}

function ConvertTo-NormalizedStringArray {
    param([string[]]$Values)
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($val in @($Values)) {
        if ([string]::IsNullOrWhiteSpace([string]$val)) {
            continue
        }
        foreach ($part in ([string]$val -split ',')) {
            $trimmed = $part.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed) -and -not $list.Contains($trimmed)) {
                $list.Add($trimmed)
            }
        }
    }
    return $list.ToArray()
}

function Write-JsonOutput {
    param([Parameter(Mandatory = $true)]$Data)
    $jsonText = $Data | ConvertTo-Json -Depth 12
    Write-Output $jsonText
    if (-not [string]::IsNullOrWhiteSpace($ElevationLogPath)) {
        $script:ElevationJsonText = $jsonText
    }
}

function Set-CliError {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$ExitCode = 1
    )
    if ($Json) {
        Write-JsonOutput -Data ([pscustomobject]@{
            Success  = $false
            ExitCode = $ExitCode
            Error    = $Message
        })
    } else {
        Write-CliHost "[ERROR] $Message" -ForegroundColor Red
    }
    $script:ExitCode = $ExitCode
}

function Get-EffectiveDryRun {
    return ($DryRun.IsPresent -or $script:IsWhatIf)
}

function Get-ActiveProfileGuess {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)]$Config
    )

    $adapters = @($Snapshot.Adapters)
    $vpnState = $Snapshot.VpnState
    $primary = $null
    if ($vpnState.IsActive -and -not [string]::IsNullOrWhiteSpace([string]$vpnState.AdapterName)) {
        $primary = $adapters | Where-Object {
            ([string]$_.Name).Equals([string]$vpnState.AdapterName, [System.StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1
    }
    if ($null -eq $primary) {
        $primary = $adapters | Where-Object { -not $_.Virtual -and $_.Status -eq 'Up' } | Select-Object -First 1
    }
    if ($null -eq $primary) {
        $primary = $adapters | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    }
    if ($null -eq $primary) {
        return [pscustomobject]@{
            AdapterName   = $null
            ProfileId     = $null
            ProfileName   = $null
            Category      = $null
            DohConfigured = $false
            Summary       = 'No active network adapter detected'
        }
    }

    $dnsServers = @($primary.IPv4DnsServers)
    $isVpnPrimary = ($vpnState.IsActive -and -not [string]::IsNullOrWhiteSpace([string]$vpnState.AdapterName) -and ([string]$primary.Name).Equals([string]$vpnState.AdapterName, [System.StringComparison]::OrdinalIgnoreCase))

    $dohMap = @{}
    foreach ($ds in @($Snapshot.DohServers)) {
        if ($ds.AddressFamily -eq 'IPv4') {
            $dohMap[[string]$ds.ServerAddress] = [string]$ds.DohTemplate
        }
    }

    if (-not $primary.IsDhcpDns -and @($dnsServers).Count -gt 0) {
        foreach ($p in @($Config.profiles)) {
            $pIps = @($p.ipv4 | ForEach-Object { [string]$_ })
            $firstMatch = ($dnsServers.Count -gt 0 -and $pIps -contains [string]$dnsServers[0])
            $exactMatch = (($dnsServers -join ',') -eq ($pIps -join ','))
            if ($exactMatch -or $firstMatch) {
                $dohOk = $true
                foreach ($dip in @($p.doh_ips)) {
                    $dipStr = [string]$dip
                    if (-not $dohMap.ContainsKey($dipStr) -or $dohMap[$dipStr] -ne [string]$p.doh_template) {
                        $dohOk = $false
                    }
                }
                $dohNote = if ($dohOk) { 'IPv4 DoH active' } else { 'IPv4 DoH NOT registered' }
                return [pscustomobject]@{
                    AdapterName   = $primary.Name
                    ProfileId     = [string]$p.id
                    ProfileName   = [string]$p.name
                    Category      = [string]$p.category
                    DohConfigured = $dohOk
                    Summary       = "$($p.id) ($($p.name)) on $($primary.Name) [$dohNote]"
                }
            }
        }
    }

    if ($isVpnPrimary) {
        $vpnInternalRegex = '^(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|198\.1[89]\.)'
        $hasVpnInternalDns = (@($dnsServers | Where-Object { [string]$_ -match $vpnInternalRegex }).Count -gt 0)
        if ($primary.IsDhcpDns -or @($dnsServers).Count -eq 0 -or $hasVpnInternalDns) {
            $dnsText = if (@($dnsServers).Count -gt 0) { $dnsServers -join ', ' } else { 'automatic' }
            $hijackNote = if ($vpnState.HijackDnsExpected) { '; plain 53 may be intercepted by TUN' } else { '' }
            return [pscustomobject]@{
                AdapterName   = $primary.Name
                ProfileId     = 'vpn-default'
                ProfileName   = 'VPN Default DNS'
                Category      = 'vpn-default'
                DohConfigured = $false
                Summary       = "VPN default DNS ($dnsText on $($primary.Name)$hijackNote)"
            }
        }
    }

    if ($primary.IsDhcpDns -or @($dnsServers).Count -eq 0) {
        $dnsText = if (@($dnsServers).Count -gt 0) { $dnsServers -join ', ' } else { 'none' }
        return [pscustomobject]@{
            AdapterName   = $primary.Name
            ProfileId     = 'dhcp'
            ProfileName   = 'DHCP Automatic'
            Category      = 'dhcp'
            DohConfigured = $false
            Summary       = "DHCP DNS on $($primary.Name) ($dnsText)"
        }
    }

    return [pscustomobject]@{
        AdapterName   = $primary.Name
        ProfileId     = 'custom'
        ProfileName   = 'Custom Static DNS'
        Category      = 'custom'
        DohConfigured = $false
        Summary       = "Custom DNS on $($primary.Name): $($dnsServers -join ', ')"
    }
}

function Get-StatusReportData {
    $config = Get-DnsProfilesConfig -ConfigPath $script:ConfigPath
    $snapshot = Get-NetworkDnsSnapshot
    $nrptAudit = Get-NrptAudit -ConfigPath $script:ConfigPath
    $guess = Get-ActiveProfileGuess -Snapshot $snapshot -Config $config

    $ipv4Doh = @($snapshot.DohServers | Where-Object { $_.AddressFamily -eq 'IPv4' })
    $ipv6Doh = @($snapshot.DohServers | Where-Object { $_.AddressFamily -eq 'IPv6' })

    return [pscustomobject]@{
        Success             = $true
        Timestamp           = $snapshot.Timestamp
        ComputerName        = $snapshot.ComputerName
        PowerShellVersion   = $PSVersionTable.PSVersion.ToString()
        IsAdministrator     = $snapshot.IsAdministrator
        ActiveProfileGuess  = $guess
        VpnState            = $snapshot.VpnState
        Adapters            = $snapshot.Adapters
        DohSummary          = [pscustomobject]@{
            Source      = $snapshot.DohSource
            IPv4Count   = @($ipv4Doh).Count
            IPv6Count   = @($ipv6Doh).Count
            IPv4Servers = $ipv4Doh
            IPv6Servers = $ipv6Doh
            ClientState = $snapshot.DnsClientState
        }
        NrptSummary         = [pscustomobject]@{
            TotalRules          = $nrptAudit.TotalRules
            FlaggedCount        = $nrptAudit.FlaggedCount
            CleanCount          = $nrptAudit.CleanCount
            DeadLocalCount      = $nrptAudit.DeadLocalCount
            XboxDnsCount        = $nrptAudit.XboxDnsCount
            GoogleOverrideCount = $nrptAudit.GoogleOverrideCount
        }
    }
}

function Show-StatusReport {
    param(
        [Parameter(Mandatory = $true)]$Report,
        [switch]$Compact
    )

    $adminText = if ($Report.IsAdministrator) { 'Administrator (Elevated)' } else { 'Standard user (auto-UAC on changes)' }
    $adminColor = if ($Report.IsAdministrator) { 'Green' } else { 'Yellow' }

    Write-CliHost ''
    Write-CliHost '=== Windows 11 DNS & DoH Switcher Status ===' -ForegroundColor Cyan
    Write-CliHost ("Host: {0} | PS: {1} | Privileges: " -f $Report.ComputerName, $Report.PowerShellVersion) -NoNewline
    Write-CliHost $adminText -ForegroundColor $adminColor

    $vpn = $Report.VpnState
    $vpnStateLabel = if ($vpn.IsActive) { 'ACTIVE' } else { 'INACTIVE' }
    $vpnColor = if ($vpn.IsActive) { 'Green' } else { 'DarkYellow' }
    Write-CliHost 'VPN / Tunnel: ' -NoNewline
    Write-CliHost $vpnStateLabel -ForegroundColor $vpnColor -NoNewline

    $rasLabels = @($vpn.RasConnections | Where-Object { $null -ne $_ } | ForEach-Object {
        if ($_ -is [string]) { $_ } else {
            $rn = [string](Get-SafePropertyValue -InputObject $_ -Name 'Name' -Default '')
            $rt = [string](Get-SafePropertyValue -InputObject $_ -Name 'TunnelType' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($rt)) { "$rn ($rt)" } else { $rn }
        }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })

    if ($vpn.IsActive) {
        $adapterDisplay = if (-not [string]::IsNullOrWhiteSpace([string]$vpn.AdapterName)) { [string]$vpn.AdapterName } else { 'RAS VPN' }
        $descPart = if (-not [string]::IsNullOrWhiteSpace([string]$vpn.InterfaceDescription)) { ", desc=$($vpn.InterfaceDescription)" } else { '' }
        $rasPart = if ($rasLabels.Count -gt 0) { ", ras=[$($rasLabels -join ', ')]" } else { '' }
        Write-CliHost (" (adapter={0}{1}, status={2}, ifIndex={3}, metric={4}, routes={5}{6})" -f `
            $adapterDisplay, $descPart, $vpn.AdapterStatus, $vpn.InterfaceIndex, $vpn.InterfaceMetric, $vpn.IPv4RouteCount, $rasPart)
        $detectedLabels = @($vpn.DetectedAdapters | Where-Object { $null -ne $_ } | ForEach-Object {
            $dn = [string](Get-SafePropertyValue -InputObject $_ -Name 'Name' -Default (Get-SafePropertyValue -InputObject $_ -Name 'AdapterName' -Default ''))
            $dd = [string](Get-SafePropertyValue -InputObject $_ -Name 'InterfaceDescription' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($dd)) { "$dn ($dd)" } else { $dn }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($detectedLabels.Count -gt 1) {
            Write-CliHost ("  Detected VPN adapters: {0}" -f ($detectedLabels -join '; ')) -ForegroundColor DarkGray
        }
    } else {
        $inactiveExtra = if ($vpn.AdapterPresent -and -not [string]::IsNullOrWhiteSpace([string]$vpn.AdapterName)) {
            " (inactive adapter=$($vpn.AdapterName), desc=$($vpn.InterfaceDescription), status=$($vpn.AdapterStatus))"
        } else {
            ''
        }
        Write-CliHost (" - No active VPN (Direct connection){0}" -f $inactiveExtra)
    }

    if ($vpn.HijackDnsExpected) {
        Write-CliHost '  Note: TUN adapter may intercept UDP/TCP:53; Windows native DoH (TCP:443) is recommended.' -ForegroundColor DarkGray
    }

    Write-CliHost ("Detected DNS Mode: {0}" -f $Report.ActiveProfileGuess.Summary) -ForegroundColor White

    if (-not $Compact) {
        Write-CliHost ''
        Write-CliHost 'Adapters (IPv4):' -ForegroundColor Cyan
        foreach ($ad in @($Report.Adapters)) {
            $dnsStr = if (@($ad.IPv4DnsServers).Count -gt 0) { $ad.IPv4DnsServers -join ', ' } else { '(none)' }
            $ipStr = if (@($ad.IPv4Addresses).Count -gt 0) { $ad.IPv4Addresses -join ', ' } else { '(none)' }
            $modeStr = if ($ad.IsDhcpDns) { 'DHCP' } else { 'Static' }
            $perIfCount = @($ad.PerInterfaceDohSettings).Count
            $stColor = if ($ad.Status -eq 'Up') { 'Green' } else { 'DarkGray' }
            Write-CliHost ("  - {0,-14} " -f $ad.Name) -NoNewline
            Write-CliHost ("[{0}]" -f $ad.Status) -ForegroundColor $stColor -NoNewline
            Write-CliHost (" if={0} metric={1} ip={2} dns=[{3}] ({4}, ifDoh={5})" -f `
                $ad.InterfaceIndex, $ad.InterfaceMetric, $ipStr, $dnsStr, $modeStr, $perIfCount)
        }

        Write-CliHost ''
        Write-CliHost ("Windows DoH Templates (source={0}): IPv4={1}, IPv6={2}" -f `
            $Report.DohSummary.Source, $Report.DohSummary.IPv4Count, $Report.DohSummary.IPv6Count) -ForegroundColor Cyan
        if ($Report.DohSummary.IPv4Count -eq 0) {
            Write-CliHost '  (No IPv4 DoH templates configured yet)' -ForegroundColor Yellow
        } else {
            foreach ($ds in @($Report.DohSummary.IPv4Servers)) {
                Write-CliHost ("  - {0,-15} -> {1} (AutoUpgrade={2}, UdpFallback={3})" -f `
                    $ds.ServerAddress, $ds.DohTemplate, $ds.AutoUpgrade, $ds.AllowFallbackToUdp)
            }
        }
    } else {
        Write-CliHost ("Windows DoH: IPv4={0}, IPv6={1}" -f $Report.DohSummary.IPv4Count, $Report.DohSummary.IPv6Count)
    }

    $nrpt = $Report.NrptSummary
    $nrptColor = if ($nrpt.FlaggedCount -gt 0) { 'Yellow' } else { 'Green' }
    Write-CliHost 'NRPT Audit: ' -NoNewline
    Write-CliHost ("Total={0}, Flagged={1}, Clean={2}" -f $nrpt.TotalRules, $nrpt.FlaggedCount, $nrpt.CleanCount) -ForegroundColor $nrptColor -NoNewline
    Write-CliHost (" (dead 127.0.0.53={0}, XboxDNS={1}, Google/AG={2})" -f $nrpt.DeadLocalCount, $nrpt.XboxDnsCount, $nrpt.GoogleOverrideCount)

    if ($nrpt.FlaggedCount -gt 0 -and -not $Compact) {
        Write-CliHost "  [WARN] Stale NRPT rules detected. Run 'dns-switch.ps1 nrpt clean' or add -CleanNrpt when switching." -ForegroundColor Yellow
    }

    if (-not $Compact) {
        $recText = if ($vpn.IsActive) {
            'Recommended for VPN ON: cloudflare, google, controld-p0 (vpn-clean)'
        } else {
            'Recommended for VPN OFF: geohide or dns-ai (rf-smart, SNI-proxy caveat), or yandex (rf-clean)'
        }
        Write-CliHost "Tip: $recText" -ForegroundColor DarkGray
    }
}

function Invoke-StatusCommand {
    $report = Get-StatusReportData
    if ($Json) {
        Write-JsonOutput -Data $report
        $script:ExitCode = 0
        return
    }
    if (-not (Invoke-RichUiView -View 'status' -Payload @{
        StatusReport = $report
        DryRun       = (Get-EffectiveDryRun)
    })) {
        Show-StatusReport -Report $report
    }
    $script:ExitCode = 0
}

function Invoke-ListCommand {
    $cat = 'all'
    if ($script:HasCategoryParam -and -not [string]::IsNullOrWhiteSpace($Category)) {
        $cat = $Category
    } elseif (-not [string]::IsNullOrWhiteSpace($SubArg)) {
        $cand = $SubArg.Trim().ToLowerInvariant()
        if (@('all', 'vpn-clean', 'rf-smart', 'rf-clean') -notcontains $cand) {
            Set-CliError -Message "Invalid category '$SubArg'. Allowed: all, vpn-clean, rf-smart, rf-clean." -ExitCode 2
            return
        }
        $cat = $cand
    }

    $config = Get-DnsProfilesConfig -ConfigPath $script:ConfigPath
    $profiles = @($config.profiles)
    if ($cat -ne 'all') {
        $profiles = @($profiles | Where-Object { ([string]$_.category).Equals($cat, [System.StringComparison]::OrdinalIgnoreCase) })
    }

    if ($Json) {
        Write-JsonOutput -Data ([pscustomobject]@{
            Success             = $true
            SchemaVersion       = $config.schema_version
            GeneratedAt         = $config.generated_at
            Category            = $cat
            Count               = @($profiles).Count
            Profiles            = $profiles
            DeprecatedOrBlocked = @($config.deprecated_or_blocked)
        })
        $script:ExitCode = 0
        return
    }

    Write-CliHost ''
    Write-CliHost ("=== DNS Profiles (category={0}, count={1}) ===" -f $cat, @($profiles).Count) -ForegroundColor Cyan

    $categoryOrder = @('vpn-clean', 'rf-smart', 'rf-clean')
    $categoryTitles = @{
        'vpn-clean' = '[VPN-CLEAN] Pure Public DoH (Recommended when VPN is ON)'
        'rf-smart'  = '[RF-SMART] Smart-DNS for RF direct mode (VPN OFF - Third-party SNI/CNAME proxy caveat)'
        'rf-clean'  = '[RF-CLEAN] Domestic Clean DoH for RF direct mode (VPN OFF - No SNI proxy)'
    }

    foreach ($grp in $categoryOrder) {
        $grpItems = @($profiles | Where-Object { [string]$_.category -eq $grp })
        if ($grpItems.Count -eq 0) {
            continue
        }
        Write-CliHost ''
        $titleColor = if ($grp -eq 'rf-smart') { 'Yellow' } else { 'Green' }
        Write-CliHost $categoryTitles[$grp] -ForegroundColor $titleColor

        foreach ($p in $grpItems) {
            $flags = New-Object System.Collections.Generic.List[string]
            if ([bool]$p.requires_http2) { $flags.Add('HTTP/2-only') }
            $flags.Add("UdpFallback=$($p.default_allow_udp_fallback)")
            $flags.Add("For=$($p.recommended_for -join ',')")
            $proxyList = @($p.smart_proxy_domains)
            if ($proxyList.Count -gt 0) {
                $flags.Add("SmartProxy=$($proxyList.Count) domains")
            }

            Write-CliHost ("  [{0}] {1}" -f $p.id, $p.name) -ForegroundColor White -NoNewline
            Write-CliHost (" ({0})" -f ($flags.ToArray() -join ' | ')) -ForegroundColor DarkGray
            Write-CliHost ("      IPv4: {0}" -f (@($p.ipv4) -join ', '))
            Write-CliHost ("      DoH : {0}  (DoT: {1})" -f $p.doh_template, $p.dot_host)
            if ($proxyList.Count -gt 0) {
                Write-CliHost ("      Proxied: {0}" -f ($proxyList -join ', ')) -ForegroundColor Yellow
            }
            Write-CliHost ("      Trust: {0}" -f $p.trust_note) -ForegroundColor $(if ($grp -eq 'rf-smart') { 'Yellow' } else { 'Gray' })
        }
    }

    Write-CliHost ''
    Write-CliHost ("Excluded / Deprecated IPs ({0}): Xbox DNS (111.88.96.54-57 returns 0.0.0.0 for AI), dead 127.0.0.53, retired Comss/AstraCAT/Mullvad." -f @($config.deprecated_or_blocked).Count) -ForegroundColor DarkGray
    $script:ExitCode = 0
}

function Invoke-CheckCommand {
    if (-not $Json) {
        if (Test-ShouldUseRichUi) {
            Write-Host (ConvertFrom-EscapedText '\u041f\u0440\u043e\u0432\u0435\u0440\u044f\u0435\u043c \u0434\u043e\u0441\u0442\u0443\u043f\u043d\u043e\u0441\u0442\u044c 12 \u043f\u0440\u043e\u0444\u0438\u043b\u0435\u0439 DNS (~3-5 \u0441\u0435\u043a)...') -ForegroundColor Cyan
        } else {
            Write-CliHost 'Checking live availability of all 12 DNS profiles (~3-5s)...' -ForegroundColor Cyan
        }
    }

    $avail = Get-LiveDnsAvailability -ConfigPath $script:ConfigPath -TimeoutSec 3

    if ($Json) {
        Write-JsonOutput -Data ([pscustomobject]@{
            Success        = $true
            CheckedAt      = $avail.CheckedAt
            VpnActive      = $avail.VpnActive
            DurationMs     = $avail.DurationMs
            RecommendedIds = $avail.RecommendedIds
            Results        = $avail.Results
        })
        $script:ExitCode = 0
        return
    }

    $report = Get-StatusReportData
    $config = Get-DnsProfilesConfig -ConfigPath $script:ConfigPath
    if (-not (Invoke-RichUiView -View 'menu' -Payload @{
        StatusReport = $report
        Profiles     = @($config.profiles)
        Availability = $avail
        DryRun       = $false
        Extra        = $null
    })) {
        Write-CliHost ''
        Write-CliHost ("=== Live DNS Availability (VpnActive={0}, {1}ms) ===" -f $avail.VpnActive, $avail.DurationMs) -ForegroundColor Cyan
        Write-CliHost ("Recommended now: {0}" -f (@($avail.RecommendedIds) -join ', ')) -ForegroundColor Green
        foreach ($ar in @($avail.Results)) {
            $latTxt = if ($null -ne $ar.LatencyMs) { "{0:N0}ms" -f $ar.LatencyMs } else { 'n/a' }
            $recTag = if ($ar.IsRecommended) { " [REC #$($ar.RecommendRank)]" } else { '' }
            Write-CliHost ("  - {0,-18} {1,-8} {2}/{3} {4,-7} ({5}){6}" -f `
                $ar.ProfileId, $ar.Status, $ar.PassedDomains, $ar.TotalDomains, $latTxt, $ar.TrustMode, $recTag)
        }
    }
    $script:ExitCode = 0
}

function Invoke-ProbeCommand {
    if ($Availability) {
        Invoke-CheckCommand
        return
    }

    $config = Get-DnsProfilesConfig -ConfigPath $script:ConfigPath
    $vpnState = Get-VpnTunnelState

    $effectiveTarget = $Target
    if ([string]::IsNullOrWhiteSpace($effectiveTarget) -and -not [string]::IsNullOrWhiteSpace($SubArg)) {
        $effectiveTarget = $SubArg.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($effectiveTarget) -and $All) {
        Set-CliError -Message 'Cannot combine -Target with -All.' -ExitCode 2
        return
    }

    $selectedProfiles = @()
    $scopeDesc = ''

    if (-not [string]::IsNullOrWhiteSpace($effectiveTarget)) {
        $pObj = Get-DnsProfileById -Id $effectiveTarget -ConfigPath $script:ConfigPath
        $selectedProfiles = @($pObj)
        $scopeDesc = "target=$($pObj.id)"
    } elseif ($All -or ($script:HasCategoryParam -and $Category -eq 'all')) {
        $selectedProfiles = @($config.profiles)
        $scopeDesc = 'all'
    } elseif ($script:HasCategoryParam -and -not [string]::IsNullOrWhiteSpace($Category)) {
        $selectedProfiles = @($config.profiles | Where-Object { ([string]$_.category).Equals($Category, [System.StringComparison]::OrdinalIgnoreCase) })
        $scopeDesc = "category=$Category"
    } else {
        $wantedTag = if ($vpnState.IsActive) { 'vpn-on' } else { 'vpn-off' }
        $selectedProfiles = @($config.profiles | Where-Object { @($_.recommended_for) -contains $wantedTag })
        $scopeDesc = "recommended_for=$wantedTag"
    }

    if (@($selectedProfiles).Count -eq 0) {
        Set-CliError -Message "No profiles matched probe selection ($scopeDesc)." -ExitCode 2
        return
    }

    $probeDomains = if ($Quick) { $script:QuickProbeDomains } else { $null }
    $samples = if ($Quick) { 1 } else { 3 }

    if (-not $Json) {
        $modeLabel = if ($Quick) { 'Quick (5 core domains, 1 sample + strict TLS)' } else { 'Full (16 domains, 3 samples + strict TLS)' }
        Write-CliHost ''
        Write-CliHost ("Running read-only DoH + strict-TLS probe [{0}] for {1} profile(s) ({2})..." -f $modeLabel, @($selectedProfiles).Count, $scopeDesc) -ForegroundColor Cyan
    }

    $ranked = @(Invoke-ProfileBenchmark -Profiles $selectedProfiles -Domains $probeDomains -Samples $samples -CheckTls -TimeoutSec 5 -ConfigPath $script:ConfigPath)

    if ($Json) {
        Write-JsonOutput -Data ([pscustomobject]@{
            Success      = $true
            Scope        = $scopeDesc
            Quick        = [bool]$Quick
            VpnActive    = $vpnState.IsActive
            ProfileCount = $ranked.Count
            Results      = $ranked
        })
        $script:ExitCode = 0
        return
    }

    if (Invoke-RichUiView -View 'probe' -Payload @{
        StatusReport = @{ VpnState = $vpnState }
        Extra        = @{
            Scope        = $scopeDesc
            Quick        = [bool]$Quick
            VpnActive    = $vpnState.IsActive
            ProfileCount = $ranked.Count
            Results      = $ranked
        }
    }) {
        $script:ExitCode = 0
        return
    }

    Write-CliHost ''
    Write-CliHost 'Rank | Profile            | Cat       | Status    | Passed | Proxy | Med ms (min/max)   | TLS  | Tested IP' -ForegroundColor Cyan
    Write-CliHost '-----+--------------------+-----------+-----------+--------+-------+--------------------+------+----------------'
    foreach ($r in $ranked) {
        $stColor = switch ($r.Status) {
            'HEALTHY' { 'Green' }
            'DEGRADED' { 'Yellow' }
            default { 'Red' }
        }
        $latStr = if ($null -ne $r.LatencyMedianMs) {
            "{0,5:N1} ({1:N0}/{2:N0})" -f $r.LatencyMedianMs, $r.LatencyMinMs, $r.LatencyMaxMs
        } else {
            'n/a'
        }
        $tlsStr = if ($r.TlsAllPassed -eq $true) { 'PASS' } elseif ($r.TlsAllPassed -eq $false) { 'FAIL' } else { 'N/A' }
        Write-CliHost ("{0,4} | {1,-18} | {2,-9} | " -f $r.Rank, $r.ProfileId, $r.Category) -NoNewline
        Write-CliHost ("{0,-9}" -f $r.Status) -ForegroundColor $stColor -NoNewline
        Write-CliHost (" | {0,-6} | {1,5} | {2,-18} | {3,-4} | {4}" -f `
            $r.Passed, $r.ProxiedCount, $latStr, $tlsStr, $r.TestedIp)
    }

    if ($ranked.Count -eq 1) {
        $detail = $ranked[0].Details
        Write-CliHost ''
        Write-CliHost ("Domain Breakdown for [{0}] ({1}):" -f $detail.ProfileId, $detail.DohTemplate) -ForegroundColor Cyan
        foreach ($dr in @($detail.DomainResults)) {
            $clsColor = switch ($dr.Classification) {
                'CLEAN_GOOGLE' { 'Green' }
                'SMART_PROXY' { 'Yellow' }
                default { 'Red' }
            }
            $aStr = if (@($dr.ARecords).Count -gt 0) { @($dr.ARecords) -join ', ' } else { '(none)' }
            $cnStr = if (@($dr.CNames).Count -gt 0) { " CNAME=$($dr.CNames -join ',')" } else { '' }
            $errStr = if (-not [string]::IsNullOrWhiteSpace([string]$dr.Error)) { " ERR=$($dr.Error)" } else { '' }
            Write-CliHost ("  - {0,-35} " -f $dr.Domain) -NoNewline
            Write-CliHost ("{0,-12}" -f $dr.Classification) -ForegroundColor $clsColor -NoNewline
            Write-CliHost (" H{0} {1,6:N1}ms A=[{2}]{3}{4}" -f $dr.HttpVersion, $dr.RttMs, $aStr, $cnStr, $errStr)
        }

        if (@($detail.TlsResults).Count -gt 0) {
            Write-CliHost ''
            Write-CliHost 'Strict TLS Verification (TCP:443 + Chain Validation):' -ForegroundColor Cyan
            foreach ($tr in @($detail.TlsResults)) {
                $tColor = if ($tr.Success) { 'Green' } else { 'Red' }
                $tFlag = if ($tr.Success) { 'PASS' } else { 'FAIL' }
                Write-CliHost '  - ' -NoNewline
                Write-CliHost "[$tFlag]" -ForegroundColor $tColor -NoNewline
                if ($tr.Success) {
                    Write-CliHost (" {0} @ {1} ({2}, tcp={3}ms, tls={4}ms, subj={5})" -f `
                        $tr.Hostname, $tr.IpAddress, $tr.SslProtocol, $tr.TcpRttMs, $tr.TlsRttMs, $tr.CertSubject)
                } else {
                    Write-CliHost (" {0} @ {1} -> {2}" -f $tr.Hostname, $tr.IpAddress, $tr.Error)
                }
            }
        }
    } else {
        $issues = @($ranked | Where-Object { $_.Status -ne 'HEALTHY' })
        if ($issues.Count -gt 0) {
            Write-CliHost ''
            Write-CliHost 'Degraded / Unhealthy Details:' -ForegroundColor Yellow
            foreach ($iss in $issues) {
                $badDomains = @($iss.Details.DomainResults | Where-Object { $_.Classification -notin @('CLEAN_GOOGLE', 'SMART_PROXY') })
                $badDesc = ($badDomains | ForEach-Object { "$($_.Domain)=$($_.Classification)" }) -join '; '
                Write-CliHost ("  - {0}: {1}" -f $iss.ProfileId, $badDesc)
            }
        }
    }

    $script:ExitCode = 0
}

function Invoke-ElevationOrFail {
    param(
        [Parameter(Mandatory = $true)][string[]]$RelaunchArgs,
        [Parameter(Mandatory = $true)][string]$OperationLabel
    )

    if ($NoElevate) {
        Set-CliError -Message "Operation '$OperationLabel' requires Administrator privileges. Re-run elevated, omit -NoElevate, or pass -DryRun." -ExitCode 1
        return
    }

    if (-not $Json) {
        Write-CliHost "[UAC] Elevating '$OperationLabel' via Administrator prompt..." -ForegroundColor Yellow
    }

    $tempDir = if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
    $tempLogPath = Join-Path $tempDir ("dns_switch_elev_{0}.log" -f ([Guid]::NewGuid().ToString('N')))
    $effectiveArgs = New-Object System.Collections.Generic.List[string]
    foreach ($arg in @($RelaunchArgs)) {
        $effectiveArgs.Add([string]$arg)
    }
    $effectiveArgs.Add('-ElevationLogPath')
    $effectiveArgs.Add($tempLogPath)

    $elev = $null
    $code = 1
    $childLogRaw = ''

    try {
        $elev = Invoke-SelfElevation -ScriptPath $PSCommandPath -Arguments $effectiveArgs.ToArray()
        $code = if ($null -ne $elev.ExitCode) { [int]$elev.ExitCode } else { 0 }
    } finally {
        if (Test-Path -LiteralPath $tempLogPath -PathType Leaf) {
            try {
                $childLogRaw = [System.IO.File]::ReadAllText($tempLogPath, [System.Text.Encoding]::UTF8)
            } catch {
                $childLogRaw = ''
            }
            try {
                Remove-Item -LiteralPath $tempLogPath -Force -ErrorAction SilentlyContinue
            } catch {
                # Ignore temp cleanup errors.
            }
        }

        if ($null -ne $elev) {
            $trimmedLog = if ($null -ne $childLogRaw) { $childLogRaw.Trim() } else { '' }
            if ($Json) {
                $childParsed = $null
                if (-not [string]::IsNullOrWhiteSpace($trimmedLog)) {
                    try {
                        $childParsed = $trimmedLog | ConvertFrom-Json -ErrorAction Stop
                    } catch {
                        $childParsed = $null
                    }
                }
                $payload = [ordered]@{
                    Success          = ($code -eq 0)
                    ElevatedRelaunch = $true
                    Operation        = $OperationLabel
                    ProcessId        = $elev.ProcessId
                    ExitCode         = $code
                }
                if ($null -ne $childParsed) {
                    $payload['ChildResult'] = $childParsed
                    $childErr = Get-SafePropertyValue -InputObject $childParsed -Name 'Error' -Default $null
                    if (-not [string]::IsNullOrWhiteSpace([string]$childErr)) {
                        $payload['Error'] = [string]$childErr
                    }
                } elseif (-not [string]::IsNullOrWhiteSpace($trimmedLog)) {
                    $payload['ChildOutput'] = $trimmedLog
                }
                Write-JsonOutput -Data ([pscustomobject]$payload)
            } else {
                if (-not [string]::IsNullOrWhiteSpace($trimmedLog)) {
                    Write-CliHost ''
                    Write-CliHost "--- Elevated Output ($OperationLabel) ---" -ForegroundColor DarkCyan
                    foreach ($logLine in ($trimmedLog -split "`r?`n")) {
                        if ($logLine -match '^\s*\[(ERROR|ERR)\]') {
                            Write-CliHost "  $logLine" -ForegroundColor Red
                        } elseif ($logLine -match '^\s*\[WARN') {
                            Write-CliHost "  $logLine" -ForegroundColor Yellow
                        } elseif ($logLine -match '^\s*\[OK\]') {
                            Write-CliHost "  $logLine" -ForegroundColor Green
                        } else {
                            Write-CliHost "  $logLine"
                        }
                    }
                    Write-CliHost '----------------------------------------' -ForegroundColor DarkCyan
                }
                if ($code -eq 0) {
                    Write-CliHost "[OK] Elevated operation '$OperationLabel' completed (exit code 0)." -ForegroundColor Green
                } else {
                    Write-CliHost "[ERROR] Elevated operation '$OperationLabel' exited with code $code." -ForegroundColor Red
                }
            }
            $script:ExitCode = $code
        }
    }
}

function Show-SwitchResult {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)]$ProfileObj
    )

    $isDryRun = [bool](Get-SafePropertyValue -InputObject $Result -Name 'DryRun' -Default $false)
    $isApplied = [bool](Get-SafePropertyValue -InputObject $Result -Name 'Applied' -Default (-not $isDryRun))
    $resSuccess = [bool](Get-SafePropertyValue -InputObject $Result -Name 'Success' -Default $false)
    $resProfileId = [string](Get-SafePropertyValue -InputObject $Result -Name 'ProfileId' -Default (Get-SafePropertyValue -InputObject $ProfileObj -Name 'id' -Default ''))
    $resProfileName = [string](Get-SafePropertyValue -InputObject $Result -Name 'ProfileName' -Default (Get-SafePropertyValue -InputObject $ProfileObj -Name 'name' -Default ''))
    $resCategory = [string](Get-SafePropertyValue -InputObject $Result -Name 'Category' -Default (Get-SafePropertyValue -InputObject $ProfileObj -Name 'category' -Default ''))
    $resMessage = [string](Get-SafePropertyValue -InputObject $Result -Name 'Message' -Default '')

    Write-CliHost ''
    if ($isDryRun) {
        Write-CliHost ("[DRY-RUN] Preview switch -> {0} ({1}, category={2})" -f $resProfileId, $resProfileName, $resCategory) -ForegroundColor Cyan
    } elseif (-not $isApplied) {
        $msgSuffix = if (-not [string]::IsNullOrWhiteSpace($resMessage)) { " - $resMessage" } else { '' }
        Write-CliHost ("[SKIPPED] Switch not applied -> {0} ({1}, category={2}){3}" -f $resProfileId, $resProfileName, $resCategory, $msgSuffix) -ForegroundColor Yellow
    } else {
        $badge = if ($resSuccess) { '[OK]' } else { '[WARN]' }
        $bColor = if ($resSuccess) { 'Green' } else { 'Yellow' }
        Write-CliHost ("{0} Switched DNS -> {1} ({2}, category={3})" -f $badge, $resProfileId, $resProfileName, $resCategory) -ForegroundColor $bColor
    }

    $profCategory = [string](Get-SafePropertyValue -InputObject $ProfileObj -Name 'category' -Default $resCategory)
    if ($profCategory -eq 'rf-smart') {
        $trustNote = [string](Get-SafePropertyValue -InputObject $ProfileObj -Name 'trust_note' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($trustNote)) {
            Write-CliHost ("  [TRUST CAVEAT] {0}" -f $trustNote) -ForegroundColor Yellow
        }
    }

    $resTargetMode = Get-SafePropertyValue -InputObject $Result -Name 'TargetMode' -Default 'n/a'
    $profIpv4 = @(Get-SafePropertyValue -InputObject $ProfileObj -Name 'ipv4' -Default @())
    $resFallback = Get-SafePropertyValue -InputObject $Result -Name 'AllowFallbackToUdp' -Default 'n/a'
    $resAutoUpgrade = Get-SafePropertyValue -InputObject $Result -Name 'AutoUpgrade' -Default 'n/a'
    Write-CliHost ("  TargetMode={0} | TargetIPv4=[{1}] | UdpFallback={2} | AutoUpgrade={3}" -f `
        $resTargetMode, ($profIpv4 -join ', '), $resFallback, $resAutoUpgrade)

    if (Test-ObjectHasProperty -InputObject $Result -Name 'PreflightSkipped') {
        $pfSkipped = [bool](Get-SafePropertyValue -InputObject $Result -Name 'PreflightSkipped' -Default $true)
        if (-not $pfSkipped) {
            $pfPassed = [bool](Get-SafePropertyValue -InputObject $Result -Name 'PreflightPassed' -Default $false)
            $pfColor = if ($pfPassed) { 'Green' } else { 'Red' }
            Write-CliHost '  DoH Preflight: ' -NoNewline
            Write-CliHost $(if ($pfPassed) { 'PASSED' } else { 'FAILED' }) -ForegroundColor $pfColor
            foreach ($pf in @(Get-SafePropertyValue -InputObject $Result -Name 'PreflightResults' -Default @())) {
                if ($null -eq $pf) { continue }
                $pfOk = [bool](Get-SafePropertyValue -InputObject $pf -Name 'Success' -Default $false)
                $okTxt = if ($pfOk) { 'OK' } else { 'FAIL' }
                $pfDomain = Get-SafePropertyValue -InputObject $pf -Name 'Domain' -Default ''
                $pfStatus = Get-SafePropertyValue -InputObject $pf -Name 'HttpStatus' -Default 'n/a'
                $pfVer = Get-SafePropertyValue -InputObject $pf -Name 'HttpVersion' -Default '?'
                $pfRtt = Get-SafePropertyValue -InputObject $pf -Name 'RttMs' -Default 'n/a'
                $pfARecords = @(Get-SafePropertyValue -InputObject $pf -Name 'ARecords' -Default @())
                $pfErr = Get-SafePropertyValue -InputObject $pf -Name 'Error' -Default ''
                Write-CliHost ("    - {0}: {1} HTTP {2} (v{3}) {4}ms A=[{5}] {6}" -f `
                    $pfDomain, $okTxt, $pfStatus, $pfVer, $pfRtt, ($pfARecords -join ', '), $pfErr)
            }
        } else {
            Write-CliHost '  DoH Preflight: SKIPPED (-SkipPreflight)' -ForegroundColor Yellow
        }
    }

    if ($isDryRun) {
        Write-CliHost '  Planned Adapter Changes:' -ForegroundColor Cyan
        $targetDnsList = @(Get-SafePropertyValue -InputObject $Result -Name 'TargetIPv4Dns' -Default $profIpv4)
        foreach ($ta in @(Get-SafePropertyValue -InputObject $Result -Name 'TargetAdapters' -Default @())) {
            if ($null -eq $ta) { continue }
            $taName = Get-SafePropertyValue -InputObject $ta -Name 'Name' -Default ''
            $taIf = Get-SafePropertyValue -InputObject $ta -Name 'InterfaceIndex' -Default 'n/a'
            $taStatus = Get-SafePropertyValue -InputObject $ta -Name 'Status' -Default ''
            $taCurr = @(Get-SafePropertyValue -InputObject $ta -Name 'CurrentIPv4Dns' -Default @())
            Write-CliHost ("    - {0} (if={1}, {2}): [{3}] -> [{4}]" -f `
                $taName, $taIf, $taStatus, ($taCurr -join ', '), ($targetDnsList -join ', '))
        }
        Write-CliHost '  Planned Windows DoH Registrations:' -ForegroundColor Cyan
        foreach ($pd in @(Get-SafePropertyValue -InputObject $Result -Name 'PlannedDoh' -Default @())) {
            if ($null -eq $pd) { continue }
            $pdAction = Get-SafePropertyValue -InputObject $pd -Name 'Action' -Default ''
            $pdSrv = Get-SafePropertyValue -InputObject $pd -Name 'ServerAddress' -Default ''
            $pdTpl = Get-SafePropertyValue -InputObject $pd -Name 'DohTemplate' -Default ''
            $pdAuto = Get-SafePropertyValue -InputObject $pd -Name 'AutoUpgrade' -Default 'n/a'
            $pdUdp = Get-SafePropertyValue -InputObject $pd -Name 'AllowFallbackToUdp' -Default 'n/a'
            Write-CliHost ("    - {0} {1} -> {2} (AutoUpgrade={3}, UdpFallback={4})" -f `
                $pdAction, $pdSrv, $pdTpl, $pdAuto, $pdUdp)
        }
        $plannedNrpt = Get-SafePropertyValue -InputObject $Result -Name 'PlannedNrptCleanup' -Default $null
        if ($null -ne $plannedNrpt) {
            $plannedCount = Get-SafePropertyValue -InputObject $plannedNrpt -Name 'TargetCount' -Default 0
            Write-CliHost ("  Planned NRPT Cleanup: would back up and remove {0} flagged rule(s)." -f $plannedCount) -ForegroundColor Cyan
        } elseif (Test-ObjectHasProperty -InputObject $Result -Name 'NrptFlaggedBefore') {
            $nrptBefore = Get-SafePropertyValue -InputObject $Result -Name 'NrptFlaggedBefore' -Default 0
            Write-CliHost ("  NRPT Audit: {0} flagged rule(s) present (pass -CleanNrpt to remove)." -f $nrptBefore)
        }
    } elseif ($isApplied) {
        $backupPath = Get-SafePropertyValue -InputObject $Result -Name 'BackupPath' -Default $null
        if (-not [string]::IsNullOrWhiteSpace([string]$backupPath)) {
            Write-CliHost ("  Backup Saved: {0}" -f $backupPath) -ForegroundColor Gray
        }
        foreach ($au in @(Get-SafePropertyValue -InputObject $Result -Name 'AdapterUpdates' -Default @())) {
            if ($null -eq $au) { continue }
            $auName = Get-SafePropertyValue -InputObject $au -Name 'Name' -Default ''
            $auIf = Get-SafePropertyValue -InputObject $au -Name 'InterfaceIndex' -Default 'n/a'
            $auPrev = @(Get-SafePropertyValue -InputObject $au -Name 'PreviousDns' -Default @())
            $auApplied = @(Get-SafePropertyValue -InputObject $au -Name 'AppliedDns' -Default @())
            Write-CliHost ("  Adapter {0} (if={1}): [{2}] -> [{3}]" -f `
                $auName, $auIf, ($auPrev -join ', '), ($auApplied -join ', '))
        }
        foreach ($dr in @(Get-SafePropertyValue -InputObject $Result -Name 'DohRegistrations' -Default @())) {
            if ($null -eq $dr) { continue }
            $drAction = Get-SafePropertyValue -InputObject $dr -Name 'Action' -Default ''
            $drSrv = Get-SafePropertyValue -InputObject $dr -Name 'ServerAddress' -Default ''
            $drMethod = Get-SafePropertyValue -InputObject $dr -Name 'Method' -Default ''
            $drTpl = Get-SafePropertyValue -InputObject $dr -Name 'DohTemplate' -Default ''
            Write-CliHost ("  DoH {0} {1} ({2}): {3}" -f $drAction, $drSrv, $drMethod, $drTpl)
        }
        $nrptRes = Get-SafePropertyValue -InputObject $Result -Name 'NrptResult' -Default $null
        if ($null -ne $nrptRes) {
            $nrptTarget = [int](Get-SafePropertyValue -InputObject $nrptRes -Name 'TargetCount' -Default 0)
            $nrptExecuted = [bool](Get-SafePropertyValue -InputObject $nrptRes -Name 'Executed' -Default ($nrptTarget -gt 0))
            $nrptRemoved = [int](Get-SafePropertyValue -InputObject $nrptRes -Name 'RemovedCount' -Default 0)
            $nrptRemaining = Get-SafePropertyValue -InputObject $nrptRes -Name 'RemainingFlagged' -Default $null
            if (-not $nrptExecuted -and $nrptTarget -eq 0) {
                Write-CliHost '  NRPT Cleanup: no stale or conflicting rules found (0 flagged).' -ForegroundColor Gray
            } else {
                $remText = if ($null -ne $nrptRemaining) { [string]$nrptRemaining } else { 'n/a' }
                Write-CliHost ("  NRPT Cleanup: removed {0}/{1} flagged rule(s), remaining flagged={2}" -f `
                    $nrptRemoved, $nrptTarget, $remText)
            }
        }
        $cf = Get-SafePropertyValue -InputObject $Result -Name 'CacheFlush' -Default $null
        if ($null -ne $cf) {
            $cfMethod = Get-SafePropertyValue -InputObject $cf -Name 'Method' -Default 'unknown'
            $cfMsg = Get-SafePropertyValue -InputObject $cf -Name 'Message' -Default ''
            Write-CliHost ("  DNS Cache Flush ({0}): {1}" -f $cfMethod, $cfMsg)
        }
        $pv = Get-SafePropertyValue -InputObject $Result -Name 'PostVerification' -Default $null
        if ($null -ne $pv) {
            $pvAdapters = Get-SafePropertyValue -InputObject $pv -Name 'AdaptersVerified' -Default 'n/a'
            $pvDoh = Get-SafePropertyValue -InputObject $pv -Name 'DohTemplatesVerified' -Default 'n/a'
            $pvVpn = Get-SafePropertyValue -InputObject $pv -Name 'VpnPreserved' -Default 'n/a'
            $pvSysOk = Get-SafePropertyValue -InputObject $pv -Name 'SystemResolveOk' -Default 'n/a'
            $pvSysRtt = Get-SafePropertyValue -InputObject $pv -Name 'SystemResolveRttMs' -Default 'n/a'
            $pvSysIps = @(Get-SafePropertyValue -InputObject $pv -Name 'SystemResolveIPv4' -Default @())
            Write-CliHost ("  Post-Verification: Adapters={0}, DoH={1}, VpnPreserved={2}, SystemResolve={3} ({4}ms, [{5}])" -f `
                $pvAdapters, $pvDoh, $pvVpn, $pvSysOk, $pvSysRtt, ($pvSysIps -join ', '))
        }
    }

    foreach ($w in @(Get-SafePropertyValue -InputObject $Result -Name 'Warnings' -Default @())) {
        Write-CliHost ("  [WARN] {0}" -f $w) -ForegroundColor Yellow
    }
}

function Invoke-SwitchCommand {
    $resolvedId = if (-not [string]::IsNullOrWhiteSpace($ProfileId)) { $ProfileId.Trim() } else { [string]$SubArg }
    if ([string]::IsNullOrWhiteSpace($resolvedId)) {
        Set-CliError -Message "switch requires a <profileId>. Run 'dns-switch.ps1 list' to see available profiles." -ExitCode 2
        return
    }

    $profileObj = Get-DnsProfileById -Id $resolvedId -ConfigPath $script:ConfigPath
    $normAdapters = @(ConvertTo-NormalizedStringArray -Values $AdapterNames)
    if ($TargetMode -eq 'custom' -and $normAdapters.Count -eq 0) {
        Set-CliError -Message "TargetMode 'custom' requires -AdapterNames <names>." -ExitCode 2
        return
    }

    $effectiveDryRun = Get-EffectiveDryRun
    if (-not $effectiveDryRun -and -not (Test-IsAdministrator)) {
        $relaunch = New-Object System.Collections.Generic.List[string]
        $relaunch.Add('switch')
        $relaunch.Add([string]$profileObj.id)
        $relaunch.Add('-TargetMode')
        $relaunch.Add($TargetMode)
        if ($normAdapters.Count -gt 0) {
            $relaunch.Add('-AdapterNames')
            $relaunch.Add(($normAdapters -join ','))
        }
        $relaunch.Add('-AllowUdpFallback')
        $relaunch.Add($AllowUdpFallback)
        if ($CleanNrpt) { $relaunch.Add('-CleanNrpt') }
        if ($SkipPreflight) { $relaunch.Add('-SkipPreflight') }
        if ($Json) { $relaunch.Add('-Json') }
        $relaunch.Add('-NoElevate')
        Invoke-ElevationOrFail -RelaunchArgs $relaunch.ToArray() -OperationLabel "switch $($profileObj.id)"
        return
    }

    $switchParams = @{
        Profile       = $profileObj
        TargetMode    = $TargetMode
        AdapterNames  = $normAdapters
        CleanNrpt     = $CleanNrpt.IsPresent
        SkipPreflight = $SkipPreflight.IsPresent
        BackupDir     = $script:BackupDir
        ConfigPath    = $script:ConfigPath
        DryRun        = $effectiveDryRun
        WhatIf        = $false
    }
    if ($AllowUdpFallback -eq 'true') {
        $switchParams['AllowFallbackToUdp'] = $true
    } elseif ($AllowUdpFallback -eq 'false') {
        $switchParams['AllowFallbackToUdp'] = $false
    }

    $result = Switch-DnsProfile @switchParams

    if ($Json) {
        Write-JsonOutput -Data $result
    } else {
        $configForUi = Get-DnsProfilesConfig -ConfigPath $script:ConfigPath
        if (-not (Invoke-RichUiView -View 'switch' -Payload @{
            Profiles = @($configForUi.profiles)
            DryRun   = [bool](Get-SafePropertyValue -InputObject $result -Name 'DryRun' -Default $false)
            Extra    = $result
        })) {
            Show-SwitchResult -Result $result -ProfileObj $profileObj
        }
    }

    $script:ExitCode = if ($result.Success) { 0 } else { 1 }
}

function Show-ResetResult {
    param([Parameter(Mandatory = $true)]$Result)

    $isDryRun = [bool](Get-SafePropertyValue -InputObject $Result -Name 'DryRun' -Default $false)
    $isApplied = [bool](Get-SafePropertyValue -InputObject $Result -Name 'Applied' -Default (-not $isDryRun))
    $targetModeVal = Get-SafePropertyValue -InputObject $Result -Name 'TargetMode' -Default 'n/a'

    Write-CliHost ''
    if ($isDryRun) {
        Write-CliHost ("[DRY-RUN] Preview DNS reset (TargetMode={0})" -f $targetModeVal) -ForegroundColor Cyan
        foreach ($pl in @(Get-SafePropertyValue -InputObject $Result -Name 'PlannedActions' -Default @())) {
            $plTargetDns = @(Get-SafePropertyValue -InputObject $pl -Name 'TargetDns' -Default @())
            $plType = [string](Get-SafePropertyValue -InputObject $pl -Name 'AdapterType' -Default '')
            $typeSuffix = if (-not [string]::IsNullOrWhiteSpace($plType)) { ", $plType" } else { '' }
            $targetTxt = if ($plTargetDns.Count -gt 0) { $plTargetDns -join ', ' } else { 'DHCP / automatic' }
            Write-CliHost ("  - {0} (if={1}{2}): [{3}] -> {4} ({5})" -f `
                $pl.Name, $pl.InterfaceIndex, $typeSuffix, (@($pl.PreviousDns) -join ', '), $targetTxt, $pl.Action)
        }
        foreach ($w in @(Get-SafePropertyValue -InputObject $Result -Name 'Warnings' -Default @())) {
            Write-CliHost ("  [WARN] {0}" -f $w) -ForegroundColor Yellow
        }
    } elseif (-not $isApplied) {
        $msg = [string](Get-SafePropertyValue -InputObject $Result -Name 'Message' -Default 'Reset skipped.')
        Write-CliHost ("[SKIPPED] {0}" -f $msg) -ForegroundColor Yellow
    } else {
        $vpnPreserved = Get-SafePropertyValue -InputObject $Result -Name 'VpnPreserved' -Default 'n/a'
        Write-CliHost ("[OK] Adapter DNS reset completed (TargetMode={0}, VpnPreserved={1})" -f `
            $targetModeVal, $vpnPreserved) -ForegroundColor Green
        $backupPath = Get-SafePropertyValue -InputObject $Result -Name 'BackupPath' -Default $null
        if (-not [string]::IsNullOrWhiteSpace([string]$backupPath)) {
            Write-CliHost ("  Backup Saved: {0}" -f $backupPath) -ForegroundColor Gray
        }
        foreach ($act in @(Get-SafePropertyValue -InputObject $Result -Name 'Actions' -Default @())) {
            $actTargetDns = @(Get-SafePropertyValue -InputObject $act -Name 'TargetDns' -Default @())
            $actType = [string](Get-SafePropertyValue -InputObject $act -Name 'AdapterType' -Default '')
            $typeSuffix = if (-not [string]::IsNullOrWhiteSpace($actType)) { ", $actType" } else { '' }
            $targetTxt = if ($actTargetDns.Count -gt 0) { $actTargetDns -join ', ' } else { 'DHCP / automatic' }
            Write-CliHost ("  - {0} (if={1}{2}): [{3}] -> {4} ({5})" -f `
                $act.Name, $act.InterfaceIndex, $typeSuffix, (@($act.PreviousDns) -join ', '), $targetTxt, $act.Action)
        }
        $cf = Get-SafePropertyValue -InputObject $Result -Name 'CacheFlush' -Default $null
        if ($null -ne $cf) {
            Write-CliHost ("  DNS Cache Flush ({0}): {1}" -f $cf.Method, $cf.Message)
        }
        foreach ($w in @(Get-SafePropertyValue -InputObject $Result -Name 'Warnings' -Default @())) {
            Write-CliHost ("  [WARN] {0}" -f $w) -ForegroundColor Yellow
        }
    }
}

function Invoke-ResetCommand {
    $normAdapters = @(ConvertTo-NormalizedStringArray -Values $AdapterNames)
    if ($TargetMode -eq 'custom' -and $normAdapters.Count -eq 0) {
        Set-CliError -Message "TargetMode 'custom' requires -AdapterNames <names>." -ExitCode 2
        return
    }

    $effectiveDryRun = Get-EffectiveDryRun
    if (-not $effectiveDryRun -and -not (Test-IsAdministrator)) {
        $relaunch = New-Object System.Collections.Generic.List[string]
        $relaunch.Add('reset')
        $relaunch.Add('-TargetMode')
        $relaunch.Add($TargetMode)
        if ($normAdapters.Count -gt 0) {
            $relaunch.Add('-AdapterNames')
            $relaunch.Add(($normAdapters -join ','))
        }
        if ($Json) { $relaunch.Add('-Json') }
        $relaunch.Add('-NoElevate')
        Invoke-ElevationOrFail -RelaunchArgs $relaunch.ToArray() -OperationLabel 'reset'
        return
    }

    $result = Reset-DnsToDefault -TargetMode $TargetMode -AdapterNames $normAdapters -BackupDir $script:BackupDir -DryRun:$effectiveDryRun -WhatIf:$false

    if ($Json) {
        Write-JsonOutput -Data $result
    } else {
        if (-not (Invoke-RichUiView -View 'reset' -Payload @{
            DryRun = $effectiveDryRun
            Extra  = $result
        })) {
            Show-ResetResult -Result $result
        }
    }

    $script:ExitCode = if ($result.Success) { 0 } else { 1 }
}

function Invoke-NrptCommand {
    $sub = if ([string]::IsNullOrWhiteSpace($SubArg)) { 'status' } else { $SubArg.Trim().ToLowerInvariant() }
    if (@('status', 'clean', 'restore') -notcontains $sub) {
        Set-CliError -Message "Unknown nrpt subcommand '$SubArg'. Allowed: status, clean, restore." -ExitCode 2
        return
    }

    if ($sub -eq 'status') {
        $audit = Get-NrptAudit -ConfigPath $script:ConfigPath
        if ($Json) {
            Write-JsonOutput -Data ([pscustomobject]@{
                Success = $true
                Action  = 'nrpt status'
                Audit   = $audit
            })
            $script:ExitCode = 0
            return
        }

        if (Invoke-RichUiView -View 'nrpt' -Payload @{
            Extra = @{
                Action = 'nrpt status'
                Audit  = $audit
            }
        }) {
            $script:ExitCode = 0
            return
        }

        Write-CliHost ''
        Write-CliHost ("=== NRPT Audit (Total={0}, Flagged={1}, Clean={2}) ===" -f $audit.TotalRules, $audit.FlaggedCount, $audit.CleanCount) -ForegroundColor Cyan
        Write-CliHost ("Breakdown: dead 127.0.0.53={0}, Xbox DNS={1}, Google/Antigravity overrides={2}" -f `
            $audit.DeadLocalCount, $audit.XboxDnsCount, $audit.GoogleOverrideCount)

        if ($audit.TotalRules -eq 0) {
            Write-CliHost '  No NRPT rules present.' -ForegroundColor Green
            $script:ExitCode = 0
            return
        }

        foreach ($rule in @($audit.Rules)) {
            $tag = if ($rule.IsFlagged) { 'FLAGGED' } else { 'CLEAN' }
            $tColor = if ($rule.IsFlagged) { 'Yellow' } else { 'Green' }
            Write-CliHost '  - ' -NoNewline
            Write-CliHost "[$tag]" -ForegroundColor $tColor -NoNewline
            Write-CliHost (" {0} | NS=[{1}] -> Servers=[{2}] ({3})" -f `
                $rule.Name, (@($rule.Namespace) -join ', '), (@($rule.NameServers) -join ', '), $rule.DisplayName)
            foreach ($rsn in @($rule.Reasons)) {
                Write-CliHost ("      Reason: {0}" -f $rsn) -ForegroundColor DarkYellow
            }
        }
        $script:ExitCode = 0
        return
    }

    $effectiveDryRun = Get-EffectiveDryRun

    if ($sub -eq 'clean') {
        if (-not $effectiveDryRun -and -not (Test-IsAdministrator)) {
            $relaunch = New-Object System.Collections.Generic.List[string]
            $relaunch.Add('nrpt')
            $relaunch.Add('clean')
            if ($Json) { $relaunch.Add('-Json') }
            $relaunch.Add('-NoElevate')
            Invoke-ElevationOrFail -RelaunchArgs $relaunch.ToArray() -OperationLabel 'nrpt clean'
            return
        }

        $res = Clear-StaleNrptRules -BackupDir $script:BackupDir -ConfigPath $script:ConfigPath -DryRun:$effectiveDryRun -WhatIf:$false
        if ($Json) {
            Write-JsonOutput -Data $res
        } elseif (-not (Invoke-RichUiView -View 'nrpt' -Payload @{
            DryRun = $effectiveDryRun
            Extra  = $res
        })) {
            Write-CliHost ''
            $resDry = [bool](Get-SafePropertyValue -InputObject $res -Name 'DryRun' -Default $false)
            $resTargetCount = [int](Get-SafePropertyValue -InputObject $res -Name 'TargetCount' -Default 0)
            if ($resDry) {
                $resTotal = Get-SafePropertyValue -InputObject $res -Name 'TotalRules' -Default (Get-SafePropertyValue -InputObject $res -Name 'TotalBefore' -Default 0)
                Write-CliHost ("[DRY-RUN] NRPT clean preview: {0} of {1} rule(s) flagged for removal." -f $resTargetCount, $resTotal) -ForegroundColor Cyan
                foreach ($pr in @(Get-SafePropertyValue -InputObject $res -Name 'PlannedRules' -Default @())) {
                    Write-CliHost ("  - {0}: [{1}] -> [{2}] ({3})" -f $pr.Name, $pr.Namespace, $pr.NameServers, $pr.Reasons)
                }
            } elseif ($resTargetCount -eq 0) {
                Write-CliHost '[OK] No stale or conflicting NRPT rules found.' -ForegroundColor Green
            } else {
                $resRemoved = Get-SafePropertyValue -InputObject $res -Name 'RemovedCount' -Default 0
                $resRemaining = Get-SafePropertyValue -InputObject $res -Name 'RemainingFlagged' -Default 'n/a'
                $resBackup = Get-SafePropertyValue -InputObject $res -Name 'BackupPath' -Default ''
                Write-CliHost ("[OK] Removed {0}/{1} stale NRPT rule(s). Remaining flagged={2}" -f `
                    $resRemoved, $resTargetCount, $resRemaining) -ForegroundColor Green
                Write-CliHost ("  Backup Saved: {0}" -f $resBackup) -ForegroundColor Gray
                foreach ($err in @(Get-SafePropertyValue -InputObject $res -Name 'Errors' -Default @())) {
                    Write-CliHost ("  [ERR] {0}" -f $err) -ForegroundColor Red
                }
            }
        }
        $script:ExitCode = if (@(Get-SafePropertyValue -InputObject $res -Name 'Errors' -Default @()).Count -eq 0) { 0 } else { 1 }
        return
    }

    # sub -eq 'restore'
    $effectivePath = if (-not [string]::IsNullOrWhiteSpace($BackupPath)) { $BackupPath } else { $ThirdArg }
    if ([string]::IsNullOrWhiteSpace($effectivePath)) {
        Set-CliError -Message "nrpt restore requires -BackupPath <path>. Run 'dns-switch.ps1 backups list' to see available backups." -ExitCode 2
        return
    }
    if (-not (Test-Path -LiteralPath $effectivePath -PathType Leaf)) {
        Set-CliError -Message "Backup file not found: '$effectivePath'." -ExitCode 2
        return
    }
    $resolvedPath = (Resolve-Path -LiteralPath $effectivePath -ErrorAction Stop).Path

    if (-not $effectiveDryRun -and -not (Test-IsAdministrator)) {
        $relaunch = New-Object System.Collections.Generic.List[string]
        $relaunch.Add('nrpt')
        $relaunch.Add('restore')
        $relaunch.Add('-BackupPath')
        $relaunch.Add($resolvedPath)
        if ($ReplaceExisting) { $relaunch.Add('-ReplaceExisting') }
        if ($Json) { $relaunch.Add('-Json') }
        $relaunch.Add('-NoElevate')
        Invoke-ElevationOrFail -RelaunchArgs $relaunch.ToArray() -OperationLabel 'nrpt restore'
        return
    }

    $res = Restore-NrptFromBackup -BackupPath $resolvedPath -ReplaceExisting:$ReplaceExisting -DryRun:$effectiveDryRun -WhatIf:$false
    if ($Json) {
        Write-JsonOutput -Data $res
    } elseif (-not (Invoke-RichUiView -View 'nrpt' -Payload @{
        DryRun = $effectiveDryRun
        Extra  = $res
    })) {
        Write-CliHost ''
        if ($res.DryRun) {
            Write-CliHost ("[DRY-RUN] NRPT restore preview from '{0}': backupRules={1}, wouldAdd={2}, wouldRemove={3}, wouldSkip={4}" -f `
                $res.BackupPath, $res.BackupRuleCount, $res.WouldAddCount, $res.WouldRemoveCount, $res.WouldSkipCount) -ForegroundColor Cyan
        } else {
            Write-CliHost ("[OK] NRPT restore finished: added={0}, removed={1}, skipped={2}" -f `
                $res.AddedCount, $res.RemovedCount, $res.SkippedCount) -ForegroundColor Green
            foreach ($err in @($res.Errors)) {
                Write-CliHost ("  [ERR] {0}" -f $err) -ForegroundColor Red
            }
        }
    }
    $script:ExitCode = if ($res.DryRun -or $res.Executed) { 0 } else { 1 }
}

function Invoke-BackupsCommand {
    $sub = if ([string]::IsNullOrWhiteSpace($SubArg)) { 'list' } else { $SubArg.Trim().ToLowerInvariant() }
    if (@('list', 'save', 'restore') -notcontains $sub) {
        Set-CliError -Message "Unknown backups subcommand '$SubArg'. Allowed: list, save, restore." -ExitCode 2
        return
    }

    if ($sub -eq 'list') {
        $items = @(Get-DnsBackups -BackupDir $script:BackupDir)
        if ($Json) {
            Write-JsonOutput -Data ([pscustomobject]@{
                Success   = $true
                BackupDir = $script:BackupDir
                Count     = $items.Count
                Backups   = $items
            })
            $script:ExitCode = 0
            return
        }

        if (Invoke-RichUiView -View 'backups' -Payload @{
            Extra = @{
                BackupDir = $script:BackupDir
                Count     = $items.Count
                Backups   = $items
            }
        }) {
            $script:ExitCode = 0
            return
        }

        Write-CliHost ''
        Write-CliHost ("=== DNS State Backups ({0}, count={1}) ===" -f $script:BackupDir, $items.Count) -ForegroundColor Cyan
        if ($items.Count -eq 0) {
            Write-CliHost '  No backup files found.' -ForegroundColor Gray
            $script:ExitCode = 0
            return
        }

        foreach ($b in $items) {
            $validTag = if ($b.IsValid) { 'VALID' } else { 'INVALID' }
            $vColor = if ($b.IsValid) { 'Green' } else { 'Red' }
            Write-CliHost '  - ' -NoNewline
            Write-CliHost "[$validTag]" -ForegroundColor $vColor -NoNewline
            Write-CliHost (" {0} | label={1} | adapters={2} doh={3} nrpt={4} | {5}" -f `
                $b.FileName, $b.Label, $b.AdapterCount, $b.DohServerCount, $b.NrptRuleCount, $b.CreatedAt)
            Write-CliHost ("      Path: {0}" -f $b.FullName) -ForegroundColor DarkGray
        }
        $script:ExitCode = 0
        return
    }

    $effectiveDryRun = Get-EffectiveDryRun

    if ($sub -eq 'save') {
        if ($effectiveDryRun) {
            $snap = Get-NetworkDnsSnapshot -IncludeAllAdapters
            $nrpt = Get-NrptAudit -ConfigPath $script:ConfigPath
            $preview = [pscustomobject]@{
                Success        = $true
                DryRun         = $true
                Executed       = $false
                BackupDir      = $script:BackupDir
                Label          = $Label
                AdapterCount   = @($snap.Adapters).Count
                DohServerCount = @($snap.DohServers).Count
                NrptRuleCount  = $nrpt.TotalRules
            }
            if ($Json) {
                Write-JsonOutput -Data $preview
            } elseif (-not (Invoke-RichUiView -View 'backups' -Payload @{
                DryRun = $true
                Extra  = $preview
            })) {
                Write-CliHost ''
                Write-CliHost ("[DRY-RUN] Would save DNS backup in '{0}' (label={1}, adapters={2}, doh={3}, nrpt={4})" -f `
                    $preview.BackupDir, $preview.Label, $preview.AdapterCount, $preview.DohServerCount, $preview.NrptRuleCount) -ForegroundColor Cyan
            }
            $script:ExitCode = 0
            return
        }

        $saved = Save-DnsStateBackup -BackupDir $script:BackupDir -Label $Label
        if ($Json) {
            Write-JsonOutput -Data ([pscustomobject]@{
                Success = $true
                Backup  = $saved
            })
        } elseif (-not (Invoke-RichUiView -View 'backups' -Payload @{
            DryRun = $false
            Extra  = @{
                Backup = $saved
            }
        })) {
            Write-CliHost ''
            Write-CliHost ("[OK] Saved DNS state backup: {0}" -f $saved.BackupPath) -ForegroundColor Green
            Write-CliHost ("  Label={0} | Adapters={1} | DoH={2} | NRPT={3}" -f `
                $saved.Label, $saved.AdapterCount, $saved.DohServerCount, $saved.NrptRuleCount)
        }
        $script:ExitCode = 0
        return
    }

    # sub -eq 'restore'
    $effectivePath = if (-not [string]::IsNullOrWhiteSpace($BackupPath)) { $BackupPath } else { $ThirdArg }
    if ([string]::IsNullOrWhiteSpace($effectivePath)) {
        Set-CliError -Message "backups restore requires -BackupPath <path>. Run 'dns-switch.ps1 backups list' first." -ExitCode 2
        return
    }
    if (-not (Test-Path -LiteralPath $effectivePath -PathType Leaf)) {
        Set-CliError -Message "Backup file not found: '$effectivePath'." -ExitCode 2
        return
    }
    $resolvedPath = (Resolve-Path -LiteralPath $effectivePath -ErrorAction Stop).Path

    if (-not $effectiveDryRun -and -not (Test-IsAdministrator)) {
        $relaunch = New-Object System.Collections.Generic.List[string]
        $relaunch.Add('backups')
        $relaunch.Add('restore')
        $relaunch.Add('-BackupPath')
        $relaunch.Add($resolvedPath)
        if ($SkipNrpt) { $relaunch.Add('-SkipNrpt') }
        if ($SkipDohTemplates) { $relaunch.Add('-SkipDohTemplates') }
        if ($Json) { $relaunch.Add('-Json') }
        $relaunch.Add('-NoElevate')
        Invoke-ElevationOrFail -RelaunchArgs $relaunch.ToArray() -OperationLabel 'backups restore'
        return
    }

    $res = Restore-DnsStateBackup -BackupPath $resolvedPath -SkipNrpt:$SkipNrpt -SkipDohTemplates:$SkipDohTemplates -DryRun:$effectiveDryRun -WhatIf:$false
    if ($Json) {
        Write-JsonOutput -Data $res
    } elseif (-not (Invoke-RichUiView -View 'backups' -Payload @{
        DryRun = $effectiveDryRun
        Extra  = $res
    })) {
        Write-CliHost ''
        if ($res.DryRun) {
            Write-CliHost ("[DRY-RUN] Backup restore preview from '{0}':" -f $res.BackupPath) -ForegroundColor Cyan
            foreach ($aa in @($res.AdapterActions)) {
                Write-CliHost ("  - Adapter {0}: {1} [{2}]" -f $aa.AdapterName, $aa.Action, (@($aa.TargetDns) -join ', '))
            }
            foreach ($da in @($res.DohActions)) {
                Write-CliHost ("  - DoH {0} {1} -> {2}" -f $da.Action, $da.ServerAddress, $da.DohTemplate)
            }
            if ($null -ne $res.NrptPreview) {
                Write-CliHost ("  - NRPT: wouldRemove={0}, wouldAdd={1}" -f $res.NrptPreview.WouldRemoveCount, $res.NrptPreview.WouldAddCount)
            }
        } else {
            $okTag = if ($res.Executed) { '[OK]' } else { '[WARN]' }
            $okCol = if ($res.Executed) { 'Green' } else { 'Yellow' }
            Write-CliHost ("{0} Restored DNS state from '{1}'" -f $okTag, $res.BackupPath) -ForegroundColor $okCol
            Write-CliHost ("  Adapters updated={0} | DoH templates updated={1}" -f @($res.AdapterResults).Count, @($res.DohResults).Count)
            foreach ($err in @($res.Errors)) {
                Write-CliHost ("  [ERR] {0}" -f $err) -ForegroundColor Red
            }
        }
    }

    $script:ExitCode = if ($res.DryRun -or $res.Executed) { 0 } else { 1 }
}

function Show-HelpGuide {
    $helpText = @'

Windows 11 DNS & Native DoH Switcher (Antigravity / Google AI + Any VPN / Direct)
---------------------------------------------------------------------------------
Usage:
  dns-switch.ps1                                 Launch interactive menu
  dns-switch.ps1 status [-Json] [-NoRich]        Show VPN/TUN state, adapters, IPv4 DoH, NRPT summary
  dns-switch.ps1 list [-Category <cat>] [-Json]  List profiles (all|vpn-clean|rf-smart|rf-clean)
  dns-switch.ps1 check [-Json] [-NoRich]         Fast parallel availability check across all 12 profiles
  dns-switch.ps1 probe [-Target <id>] [-Category <cat>] [-All] [-Quick] [-Json] [-NoRich]
                                                 Read-only DoH + strict-TLS probe across test domains
  dns-switch.ps1 switch <profileId> [-TargetMode <auto|vpn|ethernet|both|custom>]
                        [-AdapterNames <names>] [-AllowUdpFallback <auto|true|false>]
                        [-CleanNrpt] [-SkipPreflight] [-DryRun] [-NoElevate] [-Json] [-NoRich]
                                                 Switch DNS + register native Windows IPv4 DoH
  dns-switch.ps1 reset [-TargetMode <auto|vpn|ethernet|both|custom>]
                       [-AdapterNames <names>] [-DryRun] [-NoElevate] [-Json] [-NoRich]
                                                 Reset physical & active VPN/TUN adapter DNS to DHCP / automatic
  dns-switch.ps1 nrpt [<status|clean|restore>] [-BackupPath <path>] [-ReplaceExisting]
                      [-DryRun] [-NoElevate] [-Json] [-NoRich]
                                                 Audit, back up & remove stale NRPT rules, or restore
  dns-switch.ps1 backups [<list|save|restore>] [-BackupPath <path>] [-Label <text>]
                         [-SkipNrpt] [-SkipDohTemplates] [-DryRun] [-NoElevate] [-Json] [-NoRich]
                                                 List, create, or restore full DNS/DoH/NRPT backups
  dns-switch.ps1 help                            Show this guide

Safety Guarantees:
  - Never disconnects, stops, or restarts any VPN client, service, or TUN/RAS tunnel.
  - Always performs a live DoH preflight and saves a JSON backup before applying changes.
  - Use -DryRun (or -WhatIf) to preview any mutating operation without UAC or system writes.

Examples:
  .\dns-switch.ps1 status
  .\dns-switch.ps1 check
  .\dns-switch.ps1 probe -Target cloudflare -Quick
  .\dns-switch.ps1 switch cloudflare -DryRun
  .\dns-switch.ps1 switch cloudflare -CleanNrpt
  .\dns-switch.ps1 switch geohide -TargetMode ethernet
  .\dns-switch.ps1 nrpt status
  .\dns-switch.ps1 reset -DryRun
'@
    if ($Json) {
        Write-JsonOutput -Data ([pscustomobject]@{
            Success = $true
            Usage   = $helpText.Trim()
        })
    } elseif (Invoke-RichUiView -View 'help' -Payload @{}) {
        Write-Host '  CLI: dns-switch.ps1 <status|list|check|probe|switch|reset|nrpt|backups|help> [-NoRich] [-Json]' -ForegroundColor DarkGray
    } else {
        Write-CliHost $helpText
    }
    $script:ExitCode = 0
}

function Read-MenuInput {
    param([Parameter(Mandatory = $true)][string]$Prompt)
    try {
        $val = Read-Host -Prompt $Prompt
        if ($null -eq $val) {
            return $null
        }
        return $val.Trim()
    } catch {
        return $null
    }
}

function Wait-MenuReturn {
    param([bool]$UseRuPrompt = $false)
    $msg = if ($UseRuPrompt) {
        ConvertFrom-EscapedText '\u041d\u0430\u0436\u043c\u0438\u0442\u0435 Enter \u0434\u043b\u044f \u0432\u043e\u0437\u0432\u0440\u0430\u0442\u0430 \u0432 \u043c\u0435\u043d\u044e'
    } else {
        'Press Enter to return to menu'
    }
    [void](Read-MenuInput -Prompt $msg)
}

function Invoke-InteractiveMenu {
    $dryMode = $DryRun.IsPresent
    $useRich = Test-ShouldUseRichUi
    if ($useRich) {
        try {
            [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        } catch {
            # Ignore in non-console hosts.
        }
    }

    $cachedAvailability = $null
    $needLiveCheck = $true

    while ($true) {
        $report = Get-StatusReportData
        $config = Get-DnsProfilesConfig -ConfigPath $script:ConfigPath
        $profiles = @($config.profiles)

        if ($needLiveCheck) {
            $checkingMsg = if ($useRich) {
                ConvertFrom-EscapedText '\u041f\u0440\u043e\u0432\u0435\u0440\u044f\u0435\u043c \u0434\u043e\u0441\u0442\u0443\u043f\u043d\u043e\u0441\u0442\u044c 12 \u043f\u0440\u043e\u0444\u0438\u043b\u0435\u0439 DNS (~3-5 \u0441\u0435\u043a)...'
            } else {
                'Checking live availability of all 12 DNS profiles (~3-5s)...'
            }
            Write-Host $checkingMsg -ForegroundColor Cyan
            try {
                $cachedAvailability = Get-LiveDnsAvailability -ConfigPath $script:ConfigPath -TimeoutSec 3
            } catch {
                $cachedAvailability = $null
                Write-Host ("[WARN] Live availability check failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            }
            Write-Host ''
            $needLiveCheck = $false
        }

        $indexMap = @{}
        for ($pi = 0; $pi -lt $profiles.Count; $pi++) {
            $indexMap[[string]($pi + 1)] = $profiles[$pi]
        }

        $menuRendered = Invoke-RichUiView -View 'menu' -Payload @{
            StatusReport = $report
            Profiles     = $profiles
            Availability = $cachedAvailability
            DryRun       = $dryMode
            Extra        = $null
        }

        if (-not $menuRendered) {
            Show-StatusReport -Report $report -Compact
            if ($dryMode) {
                Write-Host '  [DRY-RUN MODE: ON - mutating choices will preview only]' -ForegroundColor Cyan
            }
            if ($null -ne $cachedAvailability) {
                Write-Host ("  Live Check ({0}ms) Recommended: {1}" -f $cachedAvailability.DurationMs, (@($cachedAvailability.RecommendedIds) -join ', ')) -ForegroundColor Green
            }

            Write-Host ''
            Write-Host '--- Profiles ---' -ForegroundColor Cyan
            $availById = @{}
            if ($null -ne $cachedAvailability) {
                foreach ($ar in @($cachedAvailability.Results)) {
                    $availById[[string]$ar.ProfileId] = $ar
                }
            }

            for ($pi = 0; $pi -lt $profiles.Count; $pi++) {
                $p = $profiles[$pi]
                $num = $pi + 1
                $tags = @()
                if ([bool]$p.requires_http2) { $tags += 'H2' }
                $proxyCnt = @($p.smart_proxy_domains).Count
                if ($proxyCnt -gt 0) { $tags += ("{0}/16 proxied" -f $proxyCnt) }
                if ($availById.ContainsKey([string]$p.id)) {
                    $av = $availById[[string]$p.id]
                    $latTag = if ($null -ne $av.LatencyMs) { "{0:N0}ms" -f $av.LatencyMs } else { 'n/a' }
                    $tags += ("{0} {1}" -f $av.Status, $latTag)
                }
                $tagStr = if ($tags.Count -gt 0) { " [" + ($tags -join ', ') + "]" } else { '' }
                Write-Host ("  {0,2}. {1,-19} {2} ({3}){4}" -f `
                    $num, $p.id, $p.name, (@($p.ipv4) -join ', '), $tagStr)
            }

            Write-Host ''
            Write-Host '--- Actions ---' -ForegroundColor Cyan
            Write-Host '  [C] Check live DNS availability     [P] Probe (live DoH + strict TLS)'
            Write-Host '  [N] NRPT audit / clean / restore    [R] Reset DNS / Restore backup'
            Write-Host '  [B] Backups list / save             [S] Refresh status'
            Write-Host ("  [D] Toggle Dry-Run ({0})             [Q] Quit" -f $(if ($dryMode) { 'ON ' } else { 'OFF' }))
            Write-Host ''
        }

        $mainPrompt = if ($useRich) {
            ConvertFrom-EscapedText '\u0412\u044b\u0431\u0435\u0440\u0438\u0442\u0435 \u043d\u043e\u043c\u0435\u0440 \u043f\u0440\u043e\u0444\u0438\u043b\u044f (1-12) \u0438\u043b\u0438 \u0434\u0435\u0439\u0441\u0442\u0432\u0438\u0435'
        } else {
            'Select profile number or action'
        }
        $choice = Read-MenuInput -Prompt $mainPrompt
        if ($null -eq $choice) {
            $script:ExitCode = 0
            return
        }
        if ([string]::IsNullOrWhiteSpace($choice)) {
            continue
        }

        $upper = $choice.ToUpperInvariant()
        if ($upper -eq 'Q') {
            $script:ExitCode = 0
            return
        }
        if ($upper -eq 'S') {
            continue
        }
        if ($upper -eq 'D') {
            $dryMode = -not $dryMode
            continue
        }
        if ($upper -eq 'C') {
            $needLiveCheck = $true
            continue
        }

        $subChoicePrompt = if ($useRich) {
            ConvertFrom-EscapedText '\u0412\u044b\u0431\u043e\u0440'
        } else {
            'Choice'
        }

        if ($indexMap.ContainsKey($choice)) {
            $picked = $indexMap[$choice]
            Write-Host ''
            Write-Host ("Selected: [{0}] {1} ({2})" -f $picked.id, $picked.name, $picked.category) -ForegroundColor White
            Write-Host ("  IPv4: {0} | DoH: {1}" -f (@($picked.ipv4) -join ', '), $picked.doh_template)
            Write-Host ("  Notes: {0}" -f $picked.notes) -ForegroundColor Gray
            if ($picked.category -eq 'rf-smart') {
                Write-Host ("  [TRUST WARNING] {0}" -f $picked.trust_note) -ForegroundColor Yellow
                Write-Host ("  Proxied domains: {0}" -f (@($picked.smart_proxy_domains) -join ', ')) -ForegroundColor Yellow
            }

            $tmAns = Read-MenuInput -Prompt 'TargetMode [auto/vpn/ethernet/both] (Enter=auto)'
            if ($null -eq $tmAns) { $script:ExitCode = 0; return }
            $chosenMode = if ([string]::IsNullOrWhiteSpace($tmAns)) { 'auto' } else { $tmAns.ToLowerInvariant() }
            if (@('auto', 'vpn', 'ethernet', 'both') -notcontains $chosenMode) {
                Write-Host "[WARN] Invalid TargetMode '$tmAns'; cancelled." -ForegroundColor Yellow
                continue
            }

            $cleanNrptFlag = $false
            if ($report.NrptSummary.FlaggedCount -gt 0) {
                $nrptAns = Read-MenuInput -Prompt ("Clean {0} stale NRPT rule(s) too? [y/N]" -f $report.NrptSummary.FlaggedCount)
                if ($null -eq $nrptAns) { $script:ExitCode = 0; return }
                $cleanNrptFlag = ($nrptAns -match '^(?i)(y|yes)$')
            }

            $confirmAns = Read-MenuInput -Prompt $(if ($dryMode) { 'Run Dry-Run preview? [Y/n]' } else { "Apply switch to '$($picked.id)'? [y/N/d(dry-run)]" })
            if ($null -eq $confirmAns) { $script:ExitCode = 0; return }

            $runDry = $dryMode
            if ($dryMode) {
                if ($confirmAns -match '^(?i)(n|no)$') { continue }
            } else {
                if ($confirmAns -match '^(?i)(d|dry)$') {
                    $runDry = $true
                } elseif ($confirmAns -notmatch '^(?i)(y|yes)$') {
                    Write-Host 'Cancelled.' -ForegroundColor DarkGray
                    continue
                }
            }

            try {
                if (-not $runDry -and -not (Test-IsAdministrator)) {
                    $relaunch = New-Object System.Collections.Generic.List[string]
                    $relaunch.Add('switch')
                    $relaunch.Add([string]$picked.id)
                    $relaunch.Add('-TargetMode')
                    $relaunch.Add($chosenMode)
                    if ($cleanNrptFlag) { $relaunch.Add('-CleanNrpt') }
                    $relaunch.Add('-NoElevate')
                    Invoke-ElevationOrFail -RelaunchArgs $relaunch.ToArray() -OperationLabel "switch $($picked.id)"
                } else {
                    $swRes = Switch-DnsProfile -Profile $picked -TargetMode $chosenMode -CleanNrpt:$cleanNrptFlag -BackupDir $script:BackupDir -ConfigPath $script:ConfigPath -DryRun:$runDry -WhatIf:$false
                    if (-not (Invoke-RichUiView -View 'switch' -Payload @{
                        Profiles = $profiles
                        DryRun   = $runDry
                        Extra    = $swRes
                    })) {
                        Show-SwitchResult -Result $swRes -ProfileObj $picked
                    }
                }
            } catch {
                Write-Host ("[ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
            }
            Wait-MenuReturn -UseRuPrompt $useRich
            continue
        }

        if ($upper -eq 'P') {
            Write-Host ''
            Write-Host 'Probe options: [1] Quick recommended (current VPN state)  [2] Single profile ID  [3] Full all 12 profiles  [B] Back'
            $pAns = Read-MenuInput -Prompt $subChoicePrompt
            if ($null -eq $pAns) { $script:ExitCode = 0; return }
            if ([string]::IsNullOrWhiteSpace($pAns) -or $pAns -match '^(?i)(b|back)$') {
                continue
            }
            $didShowOutput = $false
            try {
                if ($pAns -eq '1') {
                    $wanted = if ($report.VpnState.IsActive) { 'vpn-on' } else { 'vpn-off' }
                    $pList = @($profiles | Where-Object { @($_.recommended_for) -contains $wanted })
                    Write-Host ("Probing {0} profile(s) ({1}, quick)..." -f $pList.Count, $wanted) -ForegroundColor Cyan
                    $ranked = @(Invoke-ProfileBenchmark -Profiles $pList -Domains $script:QuickProbeDomains -Samples 1 -CheckTls -TimeoutSec 5 -ConfigPath $script:ConfigPath)
                    if (-not (Invoke-RichUiView -View 'probe' -Payload @{
                        StatusReport = @{ VpnState = $report.VpnState }
                        Extra        = @{
                            Scope        = "recommended_for=$wanted"
                            Quick        = $true
                            VpnActive    = $report.VpnState.IsActive
                            ProfileCount = $ranked.Count
                            Results      = $ranked
                        }
                    })) {
                        foreach ($r in $ranked) {
                            Write-Host ("  #{0} {1,-18} {2,-9} {3,-6} med={4}ms tls={5}" -f $r.Rank, $r.ProfileId, $r.Status, $r.Passed, $r.LatencyMedianMs, $r.TlsAllPassed)
                        }
                    }
                    $didShowOutput = $true
                } elseif ($pAns -eq '2') {
                    $pidInput = Read-MenuInput -Prompt 'Enter profile ID (e.g. cloudflare, geohide, yandex)'
                    if ($null -eq $pidInput) { $script:ExitCode = 0; return }
                    if ([string]::IsNullOrWhiteSpace($pidInput) -or $pidInput -match '^(?i)(b|back)$') {
                        continue
                    }
                    $pObj = Get-DnsProfileById -Id $pidInput -ConfigPath $script:ConfigPath
                    $ranked = @(Invoke-ProfileBenchmark -Profiles @($pObj) -Domains $script:QuickProbeDomains -Samples 1 -CheckTls -TimeoutSec 5 -ConfigPath $script:ConfigPath)
                    if (-not (Invoke-RichUiView -View 'probe' -Payload @{
                        StatusReport = @{ VpnState = $report.VpnState }
                        Extra        = @{
                            Scope        = "target=$($pObj.id)"
                            Quick        = $true
                            VpnActive    = $report.VpnState.IsActive
                            ProfileCount = $ranked.Count
                            Results      = $ranked
                        }
                    })) {
                        $d = $ranked[0].Details
                        Write-Host ("[{0}] Status={1} Passed={2}/{3} Med={4}ms TLS={5}" -f $d.ProfileId, $d.Status, $d.PassedCount, $d.TotalDomains, $d.LatencyMedianMs, $d.TlsAllPassed)
                        foreach ($dr in @($d.DomainResults)) {
                            Write-Host ("  - {0,-35} {1,-12} A=[{2}]" -f $dr.Domain, $dr.Classification, (@($dr.ARecords) -join ', '))
                        }
                    }
                    $didShowOutput = $true
                } elseif ($pAns -eq '3') {
                    Write-Host 'Probing all 12 profiles (16 domains, 3 samples + strict TLS)...' -ForegroundColor Cyan
                    $ranked = @(Invoke-ProfileBenchmark -Profiles $profiles -Samples 3 -CheckTls -TimeoutSec 5 -ConfigPath $script:ConfigPath)
                    if (-not (Invoke-RichUiView -View 'probe' -Payload @{
                        StatusReport = @{ VpnState = $report.VpnState }
                        Extra        = @{
                            Scope        = 'all'
                            Quick        = $false
                            VpnActive    = $report.VpnState.IsActive
                            ProfileCount = $ranked.Count
                            Results      = $ranked
                        }
                    })) {
                        foreach ($r in $ranked) {
                            Write-Host ("  #{0} {1,-18} {2,-9} {3,-6} med={4}ms tls={5}" -f $r.Rank, $r.ProfileId, $r.Status, $r.Passed, $r.LatencyMedianMs, $r.TlsAllPassed)
                        }
                    }
                    $didShowOutput = $true
                } else {
                    Write-Host ("[WARN] Unrecognized probe choice '{0}'." -f $pAns) -ForegroundColor Yellow
                    $didShowOutput = $true
                }
            } catch {
                Write-Host ("[ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
                $didShowOutput = $true
            }
            if ($didShowOutput) {
                Wait-MenuReturn -UseRuPrompt $useRich
            }
            continue
        }

        if ($upper -eq 'N') {
            Write-Host ''
            Write-Host 'NRPT options: [1] Show audit details  [2] Clean stale rules  [3] Restore NRPT from backup  [B] Back'
            $nAns = Read-MenuInput -Prompt $subChoicePrompt
            if ($null -eq $nAns) { $script:ExitCode = 0; return }
            if ([string]::IsNullOrWhiteSpace($nAns) -or $nAns -match '^(?i)(b|back)$') {
                continue
            }
            $didShowOutput = $false
            try {
                if ($nAns -eq '1') {
                    $a = Get-NrptAudit -ConfigPath $script:ConfigPath
                    if (-not (Invoke-RichUiView -View 'nrpt' -Payload @{
                        Extra = @{
                            Action = 'nrpt status'
                            Audit  = $a
                        }
                    })) {
                        Write-Host ("Total={0} Flagged={1} Clean={2}" -f $a.TotalRules, $a.FlaggedCount, $a.CleanCount) -ForegroundColor Cyan
                        foreach ($rl in @($a.Rules)) {
                            Write-Host ("  - [{0}] {1}: NS=[{2}] -> [{3}]" -f $(if ($rl.IsFlagged) { 'FLAGGED' } else { 'CLEAN' }), $rl.Name, (@($rl.Namespace) -join ', '), (@($rl.NameServers) -join ', '))
                        }
                    }
                    $didShowOutput = $true
                } elseif ($nAns -eq '2') {
                    $cAns = Read-MenuInput -Prompt $(if ($dryMode) { 'Preview NRPT clean (Dry-Run)? [Y/n]' } else { 'Back up & remove all flagged NRPT rules? [y/N]' })
                    if ($null -eq $cAns) { $script:ExitCode = 0; return }
                    if (($dryMode -and $cAns -notmatch '^(?i)(n|no)$') -or (-not $dryMode -and $cAns -match '^(?i)(y|yes)$')) {
                        if (-not $dryMode -and -not (Test-IsAdministrator)) {
                            Invoke-ElevationOrFail -RelaunchArgs @('nrpt', 'clean', '-NoElevate') -OperationLabel 'nrpt clean'
                        } else {
                            $nr = Clear-StaleNrptRules -BackupDir $script:BackupDir -ConfigPath $script:ConfigPath -DryRun:$dryMode -WhatIf:$false
                            if (-not (Invoke-RichUiView -View 'nrpt' -Payload @{
                                DryRun = $dryMode
                                Extra  = $nr
                            })) {
                                Write-Host ("NRPT clean: DryRun={0}, TargetCount={1}, BackupPath={2}" -f $nr.DryRun, $nr.TargetCount, $nr.BackupPath)
                            }
                        }
                        $didShowOutput = $true
                    }
                } elseif ($nAns -eq '3') {
                    $bList = @(Get-DnsBackups -BackupDir $script:BackupDir)
                    if ($bList.Count -eq 0) {
                        Write-Host 'No backups available.' -ForegroundColor Yellow
                        $didShowOutput = $true
                    } else {
                        for ($bi = 0; $bi -lt $bList.Count; $bi++) {
                            Write-Host ("  {0}. {1} ({2}, nrpt={3})" -f ($bi + 1), $bList[$bi].FileName, $bList[$bi].CreatedAt, $bList[$bi].NrptRuleCount)
                        }
                        $sel = Read-MenuInput -Prompt 'Select backup number to restore NRPT (or Enter to cancel)'
                        if ($null -eq $sel) { $script:ExitCode = 0; return }
                        if ([string]::IsNullOrWhiteSpace($sel) -or $sel -match '^(?i)(b|back)$') {
                            continue
                        }
                        $selIdx = 0
                        if ([int]::TryParse($sel, [ref]$selIdx) -and $selIdx -ge 1 -and $selIdx -le $bList.Count) {
                            $bPath = $bList[$selIdx - 1].FullName
                            if (-not $dryMode -and -not (Test-IsAdministrator)) {
                                Invoke-ElevationOrFail -RelaunchArgs @('nrpt', 'restore', '-BackupPath', $bPath, '-NoElevate') -OperationLabel 'nrpt restore'
                            } else {
                                $rr = Restore-NrptFromBackup -BackupPath $bPath -DryRun:$dryMode -WhatIf:$false
                                if (-not (Invoke-RichUiView -View 'nrpt' -Payload @{
                                    DryRun = $dryMode
                                    Extra  = $rr
                                })) {
                                    Write-Host ("NRPT restore: DryRun={0}, BackupPath={1}" -f $rr.DryRun, $rr.BackupPath)
                                }
                            }
                            $didShowOutput = $true
                        } else {
                            Write-Host ("[WARN] Invalid backup selection '{0}'." -f $sel) -ForegroundColor Yellow
                            $didShowOutput = $true
                        }
                    }
                } else {
                    Write-Host ("[WARN] Unrecognized NRPT choice '{0}'." -f $nAns) -ForegroundColor Yellow
                    $didShowOutput = $true
                }
            } catch {
                Write-Host ("[ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
                $didShowOutput = $true
            }
            if ($didShowOutput) {
                Wait-MenuReturn -UseRuPrompt $useRich
            }
            continue
        }

        if ($upper -eq 'R') {
            Write-Host ''
            Write-Host 'Reset / Restore: [1] Reset DNS to default (DHCP / VPN automatic)  [2] Restore full state from backup  [B] Back'
            $rAns = Read-MenuInput -Prompt $subChoicePrompt
            if ($null -eq $rAns) { $script:ExitCode = 0; return }
            if ([string]::IsNullOrWhiteSpace($rAns) -or $rAns -match '^(?i)(b|back)$') {
                continue
            }
            $didShowOutput = $false
            try {
                if ($rAns -eq '1') {
                    $cAns = Read-MenuInput -Prompt $(if ($dryMode) { 'Preview reset (Dry-Run)? [Y/n]' } else { 'Reset adapter DNS to defaults? [y/N]' })
                    if ($null -eq $cAns) { $script:ExitCode = 0; return }
                    if (($dryMode -and $cAns -notmatch '^(?i)(n|no)$') -or (-not $dryMode -and $cAns -match '^(?i)(y|yes)$')) {
                        if (-not $dryMode -and -not (Test-IsAdministrator)) {
                            Invoke-ElevationOrFail -RelaunchArgs @('reset', '-TargetMode', 'auto', '-NoElevate') -OperationLabel 'reset'
                        } else {
                            $rr = Reset-DnsToDefault -TargetMode 'auto' -BackupDir $script:BackupDir -DryRun:$dryMode -WhatIf:$false
                            if (-not (Invoke-RichUiView -View 'reset' -Payload @{
                                DryRun = $dryMode
                                Extra  = $rr
                            })) {
                                Show-ResetResult -Result $rr
                            }
                        }
                        $didShowOutput = $true
                    }
                } elseif ($rAns -eq '2') {
                    $bList = @(Get-DnsBackups -BackupDir $script:BackupDir)
                    if ($bList.Count -eq 0) {
                        Write-Host 'No backups available.' -ForegroundColor Yellow
                        $didShowOutput = $true
                    } else {
                        for ($bi = 0; $bi -lt $bList.Count; $bi++) {
                            Write-Host ("  {0}. {1} ({2}, label={3})" -f ($bi + 1), $bList[$bi].FileName, $bList[$bi].CreatedAt, $bList[$bi].Label)
                        }
                        $sel = Read-MenuInput -Prompt 'Select backup number to restore (or Enter to cancel)'
                        if ($null -eq $sel) { $script:ExitCode = 0; return }
                        if ([string]::IsNullOrWhiteSpace($sel) -or $sel -match '^(?i)(b|back)$') {
                            continue
                        }
                        $selIdx = 0
                        if ([int]::TryParse($sel, [ref]$selIdx) -and $selIdx -ge 1 -and $selIdx -le $bList.Count) {
                            $bPath = $bList[$selIdx - 1].FullName
                            if (-not $dryMode -and -not (Test-IsAdministrator)) {
                                Invoke-ElevationOrFail -RelaunchArgs @('backups', 'restore', '-BackupPath', $bPath, '-NoElevate') -OperationLabel 'backups restore'
                            } else {
                                $br = Restore-DnsStateBackup -BackupPath $bPath -DryRun:$dryMode -WhatIf:$false
                                if (-not (Invoke-RichUiView -View 'backups' -Payload @{
                                    DryRun = $dryMode
                                    Extra  = $br
                                })) {
                                    Write-Host ("Backup restore: DryRun={0}, BackupPath={1}" -f $br.DryRun, $br.BackupPath)
                                }
                            }
                            $didShowOutput = $true
                        } else {
                            Write-Host ("[WARN] Invalid backup selection '{0}'." -f $sel) -ForegroundColor Yellow
                            $didShowOutput = $true
                        }
                    }
                } else {
                    Write-Host ("[WARN] Unrecognized reset choice '{0}'." -f $rAns) -ForegroundColor Yellow
                    $didShowOutput = $true
                }
            } catch {
                Write-Host ("[ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
                $didShowOutput = $true
            }
            if ($didShowOutput) {
                Wait-MenuReturn -UseRuPrompt $useRich
            }
            continue
        }

        if ($upper -eq 'B') {
            Write-Host ''
            Write-Host 'Backups: [1] List backups  [2] Save manual backup now  [B] Back'
            $bAns = Read-MenuInput -Prompt $subChoicePrompt
            if ($null -eq $bAns) { $script:ExitCode = 0; return }
            if ([string]::IsNullOrWhiteSpace($bAns) -or $bAns -match '^(?i)(b|back)$') {
                continue
            }
            $didShowOutput = $false
            try {
                if ($bAns -eq '1') {
                    $bList = @(Get-DnsBackups -BackupDir $script:BackupDir)
                    if (-not (Invoke-RichUiView -View 'backups' -Payload @{
                        Extra = @{
                            BackupDir = $script:BackupDir
                            Count     = $bList.Count
                            Backups   = $bList
                        }
                    })) {
                        if ($bList.Count -eq 0) {
                            Write-Host 'No backups found.' -ForegroundColor Gray
                        } else {
                            foreach ($b in $bList) {
                                Write-Host ("  - {0} | label={1} | adapters={2} doh={3} nrpt={4}" -f $b.FileName, $b.Label, $b.AdapterCount, $b.DohServerCount, $b.NrptRuleCount)
                            }
                        }
                    }
                    $didShowOutput = $true
                } elseif ($bAns -eq '2') {
                    if ($dryMode) {
                        $snapDry = Get-NetworkDnsSnapshot -IncludeAllAdapters
                        $nrptDry = Get-NrptAudit -ConfigPath $script:ConfigPath
                        $previewDry = @{
                            DryRun         = $true
                            BackupDir      = $script:BackupDir
                            Label          = 'interactive'
                            AdapterCount   = @($snapDry.Adapters).Count
                            DohServerCount = @($snapDry.DohServers).Count
                            NrptRuleCount  = $nrptDry.TotalRules
                        }
                        if (-not (Invoke-RichUiView -View 'backups' -Payload @{
                            DryRun = $true
                            Extra  = $previewDry
                        })) {
                            Write-Host '[DRY-RUN] Would save manual DNS backup in backups\.' -ForegroundColor Cyan
                        }
                    } else {
                        $saved = Save-DnsStateBackup -BackupDir $script:BackupDir -Label 'interactive'
                        if (-not (Invoke-RichUiView -View 'backups' -Payload @{
                            DryRun = $false
                            Extra  = @{
                                Backup = $saved
                            }
                        })) {
                            Write-Host ("[OK] Saved backup: {0}" -f $saved.BackupPath) -ForegroundColor Green
                        }
                    }
                    $didShowOutput = $true
                } else {
                    Write-Host ("[WARN] Unrecognized backups choice '{0}'." -f $bAns) -ForegroundColor Yellow
                    $didShowOutput = $true
                }
            } catch {
                Write-Host ("[ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
                $didShowOutput = $true
            }
            if ($didShowOutput) {
                Wait-MenuReturn -UseRuPrompt $useRich
            }
            continue
        }

        Write-Host ("[WARN] Unrecognized selection '{0}'." -f $choice) -ForegroundColor Yellow
    }
}

try {
    foreach ($moduleFile in @('DnsCommon.psm1', 'DnsBackupAndNrpt.psm1', 'DnsProbe.psm1', 'DnsSwitcher.psm1')) {
        $modulePath = Join-Path (Join-Path $script:ProjectRoot 'lib') $moduleFile
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            throw "Required module not found: '$modulePath'."
        }
        Import-Module -Name $modulePath -ErrorAction Stop
    }

    if ($Help) {
        Show-HelpGuide
    } else {
        $normalizedAction = if ([string]::IsNullOrWhiteSpace($Action)) { '' } else { $Action.Trim().ToLowerInvariant() }

        if ($normalizedAction -eq '') {
            Invoke-InteractiveMenu
        } else {
            switch ($normalizedAction) {
                'status'       { Invoke-StatusCommand }
                'list'         { Invoke-ListCommand }
                'check'        { Invoke-CheckCommand }
                'availability' { Invoke-CheckCommand }
                'probe'        { Invoke-ProbeCommand }
                'switch'       { Invoke-SwitchCommand }
                'reset'        { Invoke-ResetCommand }
                'nrpt'         { Invoke-NrptCommand }
                'backups'      { Invoke-BackupsCommand }
                'help'         { Show-HelpGuide }
                '-h'           { Show-HelpGuide }
                '--help'       { Show-HelpGuide }
                '/?'           { Show-HelpGuide }
                default        { Set-CliError -Message "Unknown command '$Action'. Run 'dns-switch.ps1 help' for usage." -ExitCode 2 }
            }
        }
    }
} catch {
    Set-CliError -Message $_.Exception.Message -ExitCode 1
} finally {
    Save-ElevationLog
}

exit $script:ExitCode
