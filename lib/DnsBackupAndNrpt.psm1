Set-StrictMode -Version Latest

if (-not (Get-Command -Name 'Get-NetworkDnsSnapshot' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'DnsCommon.psm1') -ErrorAction Stop
}

$script:NrptRegistryRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters\DnsPolicyConfig'
$script:DohIfParamsRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters'

function Get-NrptDefaultBuiltInDeprecatedIps {
    [CmdletBinding()]
    param()
    return @(
        '127.0.0.53',
        '111.88.96.54',
        '111.88.96.55',
        '111.88.96.56',
        '111.88.96.57',
        '92.38.153.185',
        '92.223.109.31',
        '91.230.211.67',
        '83.220.169.155',
        '212.109.195.93',
        '45.155.204.190',
        '194.242.2.2',
        '159.194.200.33'
    )
}

function Get-NrptGoogleAndAntigravityDomains {
    [CmdletBinding()]
    param(
        [string]$ConfigPath
    )
    $domains = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $builtins = @(
        'antigravity.google',
        'antigravity-pa.googleapis.com',
        'antigravity.googleapis.com',
        'cloudcode-pa.googleapis.com',
        'daily-cloudcode-pa.googleapis.com',
        'autopush-cloudcode-pa.googleapis.com',
        'antigravity-unleash.goog',
        'accounts.google.com',
        'oauth2.googleapis.com',
        'www.googleapis.com',
        'generativelanguage.googleapis.com',
        'aiplatform.googleapis.com',
        'gemini.google.com',
        'aistudio.google.com',
        'open-vsx.org',
        'edgedl.me.gvt1.com',
        'jules.google.com',
        'labs.google',
        'ai.google.dev',
        'notebook.google.com',
        'notebooklm.google.com',
        'flow.google.com',
        'aisandbox-pa.googleapis.com',
        'robinfrontend-pa.googleapis.com',
        'alkalimakersuite-pa.clients6.google.com'
    )
    foreach ($d in $builtins) {
        [void]$domains.Add($d)
    }

    try {
        $cfg = Get-DnsProfilesConfig -ConfigPath $ConfigPath -ErrorAction Stop
        foreach ($prop in $cfg.test_domains.PSObject.Properties) {
            foreach ($d in @($prop.Value)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$d)) {
                    [void]$domains.Add([string]$d)
                }
            }
        }
    } catch {
        # Keep built-in domain set if profiles.json is not yet present or unreadable.
    }

    return $domains
}

function Get-AllInterfaceDohRegistrySnapshot {
    [CmdletBinding()]
    param()

    $list = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $script:DohIfParamsRoot)) {
        return $list.ToArray()
    }

    $ifKeys = @(Get-ChildItem -LiteralPath $script:DohIfParamsRoot -ErrorAction SilentlyContinue)
    foreach ($ifKey in $ifKeys) {
        $guid = $ifKey.PSChildName
        $dohBase = Join-Path $ifKey.PSPath 'DohInterfaceSettings'
        if (-not (Test-Path -LiteralPath $dohBase)) {
            continue
        }
        foreach ($family in @('Doh', 'Doh6')) {
            $famPath = Join-Path $dohBase $family
            if (-not (Test-Path -LiteralPath $famPath)) {
                continue
            }
            $serverKeys = @(Get-ChildItem -LiteralPath $famPath -ErrorAction SilentlyContinue)
            foreach ($sk in $serverKeys) {
                $props = Get-ItemProperty -LiteralPath $sk.PSPath -ErrorAction SilentlyContinue
                $propMap = [ordered]@{}
                if ($null -ne $props) {
                    foreach ($p in $props.PSObject.Properties) {
                        if (@('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider') -notcontains $p.Name) {
                            $propMap[$p.Name] = $p.Value
                        }
                    }
                }
                $list.Add([pscustomobject]@{
                    InterfaceGuid = $guid
                    Family        = $family
                    ServerKey     = $sk.PSChildName
                    Properties    = [pscustomobject]$propMap
                })
            }
        }
    }
    return $list.ToArray()
}

function Get-CombinedNrptRules {
    [CmdletBinding()]
    param()

    $cmdRules = @{}
    foreach ($r in @(Get-DnsClientNrptRule -ErrorAction SilentlyContinue)) {
        $key = ([string]$r.Name).ToUpperInvariant()
        $cmdRules[$key] = $r
    }

    $regRules = @{}
    if (Test-Path -LiteralPath $script:NrptRegistryRoot) {
        foreach ($item in @(Get-ChildItem -LiteralPath $script:NrptRegistryRoot -ErrorAction SilentlyContinue)) {
            $key = ([string]$item.PSChildName).ToUpperInvariant()
            $props = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction SilentlyContinue
            $regRules[$key] = [pscustomobject]@{
                KeyName    = [string]$item.PSChildName
                PSPath     = [string]$item.PSPath
                Properties = $props
            }
        }
    }

    $allKeys = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $cmdRules.Keys) { [void]$allKeys.Add($k) }
    foreach ($k in $regRules.Keys) { [void]$allKeys.Add($k) }

    $combined = New-Object System.Collections.Generic.List[object]
    foreach ($k in ($allKeys | Sort-Object)) {
        $cRule = if ($cmdRules.ContainsKey($k)) { $cmdRules[$k] } else { $null }
        $rEntry = if ($regRules.ContainsKey($k)) { $regRules[$k] } else { $null }
        $rProps = if ($null -ne $rEntry) { $rEntry.Properties } else { $null }

        $ruleName = if ($null -ne $cRule) { [string]$cRule.Name } else { [string]$rEntry.KeyName }

        $namespaces = @()
        if ($null -ne $cRule -and $null -ne $cRule.Namespace) {
            $namespaces = @($cRule.Namespace | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
        } elseif ($null -ne $rProps -and $null -ne $rProps.PSObject.Properties['Name']) {
            $namespaces = @($rProps.Name | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
        }

        $nameServers = @()
        if ($null -ne $cRule -and $null -ne $cRule.NameServers) {
            $nameServers = @($cRule.NameServers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
        } elseif ($null -ne $rProps -and $null -ne $rProps.PSObject.Properties['GenericDNSServers']) {
            $rawNs = [string]$rProps.GenericDNSServers
            if (-not [string]::IsNullOrWhiteSpace($rawNs)) {
                $nameServers = @($rawNs -split '[;,\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            }
        }

        $displayName = if ($null -ne $cRule -and -not [string]::IsNullOrWhiteSpace([string]$cRule.DisplayName)) {
            [string]$cRule.DisplayName
        } elseif ($null -ne $rProps -and $null -ne $rProps.PSObject.Properties['DisplayName']) {
            [string]$rProps.DisplayName
        } else {
            ''
        }

        $comment = if ($null -ne $cRule -and -not [string]::IsNullOrWhiteSpace([string]$cRule.Comment)) {
            [string]$cRule.Comment
        } elseif ($null -ne $rProps -and $null -ne $rProps.PSObject.Properties['Comment']) {
            [string]$rProps.Comment
        } else {
            ''
        }

        $nameEncoding = if ($null -ne $cRule -and $null -ne $cRule.NameEncoding) { [string]$cRule.NameEncoding } else { 'Disable' }
        $version = if ($null -ne $cRule -and $null -ne $cRule.Version) {
            [int]$cRule.Version
        } elseif ($null -ne $rProps -and $null -ne $rProps.PSObject.Properties['Version']) {
            [int]$rProps.Version
        } else {
            2
        }
        $configOptions = if ($null -ne $rProps -and $null -ne $rProps.PSObject.Properties['ConfigOptions']) {
            $rProps.ConfigOptions
        } else {
            $null
        }
        $dnsSecEnabled = if ($null -ne $cRule) { [bool]$cRule.DnsSecEnabled } else { $false }
        $directAccessEnabled = if ($null -ne $cRule) { [bool]$cRule.DirectAccessEnabled } else { $false }

        $combined.Add([pscustomobject]@{
            Name                = $ruleName
            Namespace           = $namespaces
            NameServers         = $nameServers
            DisplayName         = $displayName
            Comment             = $comment
            NameEncoding        = $nameEncoding
            Version             = $version
            ConfigOptions       = $configOptions
            DnsSecEnabled       = $dnsSecEnabled
            DirectAccessEnabled = $directAccessEnabled
            InCmdlet            = ($null -ne $cRule)
            InRegistry          = ($null -ne $rEntry)
        })
    }

    return $combined.ToArray()
}

function Save-DnsStateBackup {
    <#
    .SYNOPSIS
        Atomically saves a JSON backup of adapters' IPv4 DNS, DoH server templates, InterfaceSpecificParameters, and NRPT rules.
    #>
    [CmdletBinding()]
    param(
        [string]$BackupDir,
        [string]$Label = 'manual'
    )

    if ([string]::IsNullOrWhiteSpace($BackupDir)) {
        $BackupDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'backups'
    }
    if (-not (Test-Path -LiteralPath $BackupDir)) {
        [void](New-Item -Path $BackupDir -ItemType Directory -Force -ErrorAction Stop)
    }

    $safeLabel = ([string]$Label -replace '[^a-zA-Z0-9_-]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($safeLabel)) {
        $safeLabel = 'manual'
    }

    $snapshot = Get-NetworkDnsSnapshot -IncludeAllAdapters
    $ifDohReg = Get-AllInterfaceDohRegistrySnapshot
    $nrptRules = Get-CombinedNrptRules

    $payload = [ordered]@{
        schema_version         = 1
        created_at             = (Get-Date).ToString('o')
        label                  = $safeLabel
        computer_name          = $env:COMPUTERNAME
        vpn_state              = $snapshot.VpnState
        adapters               = @($snapshot.Adapters)
        doh_servers            = @($snapshot.DohServers)
        interface_doh_registry = @($ifDohReg)
        nrpt_rules             = @($nrptRules)
    }

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $fileName = "dns-backup-$stamp-$safeLabel.json"
    $finalPath = Join-Path $BackupDir $fileName
    if (Test-Path -LiteralPath $finalPath) {
        $stampMs = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
        $fileName = "dns-backup-$stampMs-$safeLabel.json"
        $finalPath = Join-Path $BackupDir $fileName
    }

    $tmpPath = "$finalPath.tmp.$PID.$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    $json = $payload | ConvertTo-Json -Depth 12
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    try {
        [System.IO.File]::WriteAllText($tmpPath, $json, $utf8NoBom)
        if (Test-Path -LiteralPath $finalPath) {
            Remove-Item -LiteralPath $finalPath -Force -ErrorAction Stop
        }
        [System.IO.File]::Move($tmpPath, $finalPath)
    } catch {
        if (Test-Path -LiteralPath $tmpPath) {
            Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
        }
        throw "Failed to save DNS state backup to '$finalPath': $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        BackupPath     = $finalPath
        FileName       = $fileName
        CreatedAt      = $payload.created_at
        Label          = $safeLabel
        AdapterCount   = @($payload.adapters).Count
        DohServerCount = @($payload.doh_servers).Count
        NrptRuleCount  = @($payload.nrpt_rules).Count
    }
}

function Get-DnsBackups {
    <#
    .SYNOPSIS
        Lists saved DNS state backup JSON files sorted newest first.
    #>
    [CmdletBinding()]
    param(
        [string]$BackupDir
    )

    if ([string]::IsNullOrWhiteSpace($BackupDir)) {
        $BackupDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'backups'
    }
    if (-not (Test-Path -LiteralPath $BackupDir -PathType Container)) {
        return @()
    }

    $files = @(Get-ChildItem -LiteralPath $BackupDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    $items = New-Object System.Collections.Generic.List[object]

    foreach ($file in $files) {
        $createdAt = $file.LastWriteTimeUtc
        $createdAtStr = $file.LastWriteTime.ToString('o')
        $label = ''
        $adapterCount = 0
        $dohCount = 0
        $nrptCount = 0
        $isValid = $false

        try {
            $raw = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
            $obj = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $obj.PSObject.Properties['created_at'] -and -not [string]::IsNullOrWhiteSpace([string]$obj.created_at)) {
                $parsedDt = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse([string]$obj.created_at, [ref]$parsedDt)) {
                    $createdAt = $parsedDt.UtcDateTime
                    $createdAtStr = [string]$obj.created_at
                }
            }
            if ($null -ne $obj.PSObject.Properties['label']) { $label = [string]$obj.label }
            if ($null -ne $obj.PSObject.Properties['adapters']) { $adapterCount = @($obj.adapters | Where-Object { $null -ne $_ }).Count }
            if ($null -ne $obj.PSObject.Properties['doh_servers']) { $dohCount = @($obj.doh_servers | Where-Object { $null -ne $_ }).Count }
            if ($null -ne $obj.PSObject.Properties['nrpt_rules']) { $nrptCount = @($obj.nrpt_rules | Where-Object { $null -ne $_ }).Count }
            $isValid = $true
        } catch {
            $isValid = $false
        }

        $items.Add([pscustomobject]@{
            FullName       = $file.FullName
            FileName       = $file.Name
            CreatedAt      = $createdAtStr
            SortTimestamp  = $createdAt
            Label          = $label
            AdapterCount   = $adapterCount
            DohServerCount = $dohCount
            NrptRuleCount  = $nrptCount
            LengthBytes    = $file.Length
            IsValid        = $isValid
        })
    }

    return @($items.ToArray() | Sort-Object -Property SortTimestamp, FullName -Descending)
}

function Get-NrptAudit {
    <#
    .SYNOPSIS
        Read-only audit of Windows NRPT rules (Get-DnsClientNrptRule + DnsPolicyConfig registry), flagging dead/stale/conflicting entries.
    #>
    [CmdletBinding()]
    param(
        [string[]]$DeprecatedIps,
        [string]$ConfigPath
    )

    $deprecatedSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ip in (Get-NrptDefaultBuiltInDeprecatedIps)) {
        [void]$deprecatedSet.Add($ip)
    }
    if ($null -ne $DeprecatedIps) {
        foreach ($ip in $DeprecatedIps) {
            if (-not [string]::IsNullOrWhiteSpace([string]$ip)) {
                [void]$deprecatedSet.Add(([string]$ip).Trim())
            }
        }
    } else {
        try {
            $cfg = Get-DnsProfilesConfig -ConfigPath $ConfigPath -ErrorAction Stop
            foreach ($entry in @($cfg.deprecated_or_blocked)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$entry.ip)) {
                    [void]$deprecatedSet.Add(([string]$entry.ip).Trim())
                }
            }
        } catch {
            # Built-in deprecated IP list still covers all known bad IPs.
        }
    }

    $xboxSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($xip in @('111.88.96.54', '111.88.96.55', '111.88.96.56', '111.88.96.57', '2a00:ab00:1233:26::50', '2a00:ab00:1233:26::51')) {
        [void]$xboxSet.Add($xip)
    }

    $protectedDomains = Get-NrptGoogleAndAntigravityDomains -ConfigPath $ConfigPath
    $rules = @(Get-CombinedNrptRules)
    $auditedRules = New-Object System.Collections.Generic.List[object]

    foreach ($rule in $rules) {
        $reasons = New-Object System.Collections.Generic.List[string]
        $hasDeadLocal = $false
        $hasXbox = $false
        $matchedDeprecated = New-Object System.Collections.Generic.List[string]
        $matchedProtected = New-Object System.Collections.Generic.List[string]

        foreach ($ns in @($rule.NameServers)) {
            if ($ns -eq '127.0.0.53') {
                $hasDeadLocal = $true
            }
            if ($xboxSet.Contains($ns)) {
                $hasXbox = $true
            }
            if ($deprecatedSet.Contains($ns)) {
                if (-not $matchedDeprecated.Contains($ns)) {
                    $matchedDeprecated.Add($ns)
                }
            }
        }

        foreach ($nsDomain in @($rule.Namespace)) {
            $cleanNs = ([string]$nsDomain).Trim().TrimStart('.').ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($cleanNs)) {
                continue
            }
            if ($protectedDomains.Contains($cleanNs) -or $cleanNs -like '*.googleapis.com' -or $cleanNs -like '*.google.com' -or $cleanNs -eq 'antigravity.google' -or $cleanNs -eq 'antigravity-unleash.goog') {
                if (-not $matchedProtected.Contains($nsDomain)) {
                    $matchedProtected.Add($nsDomain)
                }
            }
        }

        $isLegacyUnblocker = ($rule.Comment -match '(?i)(_UNBLOCK\b|DNS_UNBLOCK|AI_UNBLOCK)' -or $rule.DisplayName -match '(?i)(Unblocker|DNS\s*Unblock|AI\s*Unblock)')

        if ($hasDeadLocal) {
            $reasons.Add('Points to dead local forwarder 127.0.0.53 (causes ~200-1100ms stall)')
        }
        if ($hasXbox) {
            $reasons.Add('Points to Xbox DNS 111.88.96.54-55 (blocks generativelanguage/gemini/aistudio with 0.0.0.0)')
        }
        $otherDeprecated = @($matchedDeprecated.ToArray() | Where-Object { $_ -ne '127.0.0.53' -and -not $xboxSet.Contains($_) })
        if ($otherDeprecated.Count -gt 0) {
            $reasons.Add("Points to deprecated/dead IP(s): $($otherDeprecated -join ', ')")
        }
        if ($matchedProtected.Count -gt 0) {
            $reasons.Add("Overrides Antigravity/Google domain(s): $($matchedProtected -join ', ')")
        }
        if ($isLegacyUnblocker -and $reasons.Count -eq 0) {
            $reasons.Add('Remnant legacy AI/DNS unblocker NRPT rule')
        }

        $isFlagged = ($reasons.Count -gt 0)

        $auditedRules.Add([pscustomobject]@{
            Name                        = $rule.Name
            Namespace                   = @($rule.Namespace)
            NameServers                 = @($rule.NameServers)
            DisplayName                 = $rule.DisplayName
            Comment                     = $rule.Comment
            IsFlagged                   = $isFlagged
            HasDeadLocalForwarder       = $hasDeadLocal
            HasXboxDns                  = $hasXbox
            MatchedDeprecatedIps        = $matchedDeprecated.ToArray()
            OverridesAntigravityGoogle  = ($matchedProtected.Count -gt 0)
            MatchedProtectedNamespaces  = $matchedProtected.ToArray()
            IsLegacyUnblockerRule       = $isLegacyUnblocker
            Reasons                     = $reasons.ToArray()
        })
    }

    $allAudited = $auditedRules.ToArray()
    $flagged = @($allAudited | Where-Object { $_.IsFlagged })

    return [pscustomobject]@{
        TotalRules            = $allAudited.Count
        FlaggedCount          = $flagged.Count
        CleanCount            = ($allAudited.Count - $flagged.Count)
        DeadLocalCount        = @($flagged | Where-Object { $_.HasDeadLocalForwarder }).Count
        XboxDnsCount          = @($flagged | Where-Object { $_.HasXboxDns }).Count
        GoogleOverrideCount   = @($flagged | Where-Object { $_.OverridesAntigravityGoogle }).Count
        DeprecatedIpsChecked  = @($deprecatedSet | Sort-Object)
        Rules                 = $allAudited
    }
}

function Clear-StaleNrptRules {
    <#
    .SYNOPSIS
        Backs up all NRPT rules first, then removes stale/conflicting rules (or previews actions if -DryRun).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$BackupDir,
        [string[]]$DeprecatedIps,
        [string]$ConfigPath,
        [switch]$DryRun
    )

    $audit = Get-NrptAudit -DeprecatedIps $DeprecatedIps -ConfigPath $ConfigPath
    $targets = @($audit.Rules | Where-Object { $_.IsFlagged })

    if ($DryRun) {
        return [pscustomobject]@{
            DryRun           = $true
            Executed         = $false
            TotalRules       = $audit.TotalRules
            TotalBefore      = $audit.TotalRules
            TargetCount      = $targets.Count
            RemovedCount     = 0
            RemainingTotal   = $audit.TotalRules
            RemainingFlagged = $audit.FlaggedCount
            BackupPath       = $null
            RemovedRules     = @()
            PlannedRules     = @($targets | ForEach-Object {
                [pscustomobject]@{
                    Name        = $_.Name
                    Namespace   = ($_.Namespace -join ', ')
                    NameServers = ($_.NameServers -join ', ')
                    Reasons     = ($_.Reasons -join '; ')
                }
            })
            Errors           = @()
        }
    }

    if (-not (Test-IsAdministrator)) {
        throw 'Clear-StaleNrptRules requires elevated Administrator privileges when not running with -DryRun.'
    }

    if ($targets.Count -eq 0) {
        return [pscustomobject]@{
            DryRun           = $false
            Executed         = $false
            TotalRules       = $audit.TotalRules
            TotalBefore      = $audit.TotalRules
            TargetCount      = 0
            RemovedCount     = 0
            RemainingTotal   = $audit.TotalRules
            RemainingFlagged = 0
            BackupPath       = $null
            RemovedRules     = @()
            PlannedRules     = @()
            Errors           = @()
        }
    }

    $backup = Save-DnsStateBackup -BackupDir $BackupDir -Label 'pre-nrpt-clean'
    $removed = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($target in $targets) {
        $desc = "$($target.Name) [$($target.Namespace -join ', ')]"
        if (-not $PSCmdlet.ShouldProcess($desc, 'Remove stale NRPT rule')) {
            continue
        }
        $didRemove = $false
        try {
            Remove-DnsClientNrptRule -Name $target.Name -Force -ErrorAction Stop
            $didRemove = $true
        } catch {
            $regKeyPath = Join-Path $script:NrptRegistryRoot $target.Name
            if (Test-Path -LiteralPath $regKeyPath) {
                try {
                    Remove-Item -LiteralPath $regKeyPath -Recurse -Force -ErrorAction Stop
                    $didRemove = $true
                } catch {
                    $errors.Add("Failed to remove NRPT rule '$($target.Name)': $($_.Exception.Message)")
                }
            } else {
                $errors.Add("Failed to remove NRPT rule '$($target.Name)': $($_.Exception.Message)")
            }
        }
        if ($didRemove) {
            $removed.Add([pscustomobject]@{
                Name        = $target.Name
                Namespace   = @($target.Namespace)
                NameServers = @($target.NameServers)
            })
        }
    }

    [void](Invoke-DnsCacheFlush)
    $afterAudit = Get-NrptAudit -DeprecatedIps $DeprecatedIps -ConfigPath $ConfigPath

    return [pscustomobject]@{
        DryRun            = $false
        Executed          = $true
        TotalBefore       = $audit.TotalRules
        TargetCount       = $targets.Count
        RemovedCount      = $removed.Count
        RemainingTotal    = $afterAudit.TotalRules
        RemainingFlagged  = $afterAudit.FlaggedCount
        BackupPath        = $backup.BackupPath
        RemovedRules      = $removed.ToArray()
        Errors            = $errors.ToArray()
    }
}

function Read-DnsBackupFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BackupPath
    )
    if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new("Backup file not found at '$BackupPath'.", $BackupPath)
    }
    $raw = [System.IO.File]::ReadAllText($BackupPath, [System.Text.Encoding]::UTF8)
    try {
        $backup = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Failed to parse backup JSON '$BackupPath': $($_.Exception.Message)"
    }
    if ($null -eq $backup.PSObject.Properties['schema_version']) {
        throw "Invalid backup file '$BackupPath': missing schema_version."
    }
    return $backup
}

function Restore-NrptFromBackup {
    <#
    .SYNOPSIS
        Restores NRPT rules from a JSON state backup (or previews actions with -DryRun).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [switch]$ReplaceExisting,
        [switch]$DryRun
    )

    $backup = Read-DnsBackupFile -BackupPath $BackupPath
    $backupRules = @($backup.nrpt_rules | Where-Object { $null -ne $_ })
    $existingRules = @(Get-CombinedNrptRules)

    $existingSignatures = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($er in $existingRules) {
        $sig = (([string]($er.Namespace -join ',')) + '|' + ([string]($er.NameServers -join ',')) + '|' + [string]$er.DisplayName)
        [void]$existingSignatures.Add($sig)
    }

    $toAdd = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]

    foreach ($br in $backupRules) {
        $nsList = @($br.Namespace | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
        $srvList = @($br.NameServers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
        $disp = if ($null -ne $br.PSObject.Properties['DisplayName']) { [string]$br.DisplayName } else { '' }
        $sig = (($nsList -join ',') + '|' + ($srvList -join ',') + '|' + $disp)

        if (-not $ReplaceExisting -and $existingSignatures.Contains($sig)) {
            $skipped.Add($br)
        } else {
            $toAdd.Add($br)
        }
    }

    if ($DryRun) {
        return [pscustomobject]@{
            DryRun            = $true
            Executed          = $false
            BackupPath        = $BackupPath
            BackupRuleCount   = $backupRules.Count
            WouldRemoveCount  = if ($ReplaceExisting) { $existingRules.Count } else { 0 }
            WouldAddCount     = $toAdd.Count
            WouldSkipCount    = $skipped.Count
            PlannedAdditions  = @($toAdd.ToArray() | ForEach-Object {
                [pscustomobject]@{
                    Name        = $_.Name
                    Namespace   = ($_.Namespace -join ', ')
                    NameServers = ($_.NameServers -join ', ')
                    DisplayName = $_.DisplayName
                }
            })
        }
    }

    if (-not (Test-IsAdministrator)) {
        throw 'Restore-NrptFromBackup requires elevated Administrator privileges when not running with -DryRun.'
    }

    $errors = New-Object System.Collections.Generic.List[string]
    $removedCount = 0
    if ($ReplaceExisting -and $existingRules.Count -gt 0) {
        foreach ($er in $existingRules) {
            if ($PSCmdlet.ShouldProcess($er.Name, 'Remove existing NRPT rule prior to restore')) {
                try {
                    Remove-DnsClientNrptRule -Name $er.Name -Force -ErrorAction Stop
                    $removedCount++
                } catch {
                    $errors.Add("Failed removing existing NRPT rule '$($er.Name)': $($_.Exception.Message)")
                }
            }
        }
    }

    $addedCount = 0
    foreach ($br in $toAdd) {
        $nsList = @($br.Namespace | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
        $srvList = @($br.NameServers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
        if ($nsList.Count -eq 0) {
            continue
        }
        $desc = "$($nsList -join ', ') -> $($srvList -join ', ')"
        if (-not $PSCmdlet.ShouldProcess($desc, 'Add NRPT rule from backup')) {
            continue
        }

        $params = @{
            Namespace   = $nsList
            ErrorAction = 'Stop'
        }
        if ($srvList.Count -gt 0) {
            $params['NameServers'] = $srvList
        }
        if ($null -ne $br.PSObject.Properties['DisplayName'] -and -not [string]::IsNullOrWhiteSpace([string]$br.DisplayName)) {
            $params['DisplayName'] = [string]$br.DisplayName
        }
        if ($null -ne $br.PSObject.Properties['Comment'] -and -not [string]::IsNullOrWhiteSpace([string]$br.Comment)) {
            $params['Comment'] = [string]$br.Comment
        }
        if ($null -ne $br.PSObject.Properties['NameEncoding'] -and -not [string]::IsNullOrWhiteSpace([string]$br.NameEncoding)) {
            $params['NameEncoding'] = [string]$br.NameEncoding
        }
        if ($null -ne $br.PSObject.Properties['DnsSecEnabled'] -and [bool]$br.DnsSecEnabled) {
            $params['DnsSecEnable'] = $true
        }

        try {
            [void](Add-DnsClientNrptRule @params)
            $addedCount++
        } catch {
            $errors.Add("Failed restoring NRPT rule for '$($nsList -join ', ')': $($_.Exception.Message)")
        }
    }

    [void](Invoke-DnsCacheFlush)

    return [pscustomobject]@{
        DryRun          = $false
        Executed        = ($errors.Count -eq 0)
        BackupPath      = $BackupPath
        BackupRuleCount = $backupRules.Count
        RemovedCount    = $removedCount
        AddedCount      = $addedCount
        SkippedCount    = $skipped.Count
        Errors          = $errors.ToArray()
    }
}

function Restore-DnsStateBackup {
    <#
    .SYNOPSIS
        Restores adapter IPv4 DNS, Windows DoH templates, and NRPT rules from backup without touching VPN routes or tunnel services.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [switch]$SkipNrpt,
        [switch]$SkipDohTemplates,
        [switch]$DryRun
    )

    $backup = Read-DnsBackupFile -BackupPath $BackupPath
    $backupAdapters = @($backup.adapters | Where-Object { $null -ne $_ })
    $backupDohServers = @($backup.doh_servers | Where-Object { $null -ne $_ })

    $liveAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
    $adapterPlans = New-Object System.Collections.Generic.List[object]

    foreach ($bAdapter in $backupAdapters) {
        $match = $liveAdapters | Where-Object {
            ([string]$_.InterfaceGuid).Equals([string]$bAdapter.InterfaceGuid, [System.StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1
        if ($null -eq $match) {
            $match = $liveAdapters | Where-Object {
                ([string]$_.Name).Equals([string]$bAdapter.Name, [System.StringComparison]::OrdinalIgnoreCase)
            } | Select-Object -First 1
        }
        if ($null -eq $match) {
            $adapterPlans.Add([pscustomobject]@{
                AdapterName    = [string]$bAdapter.Name
                InterfaceIndex = $null
                Action         = 'SkipMissing'
                TargetDns      = @()
            })
            continue
        }

        $isDhcp = $false
        if ($null -ne $bAdapter.PSObject.Properties['IsDhcpDns']) {
            $isDhcp = [bool]$bAdapter.IsDhcpDns
        }
        $targetDns = @($bAdapter.IPv4DnsServers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })

        $action = if ($isDhcp) { 'ResetToDhcp' } elseif ($targetDns.Count -gt 0) { 'SetStaticDns' } else { 'ResetToDhcp' }
        $adapterPlans.Add([pscustomobject]@{
            AdapterName    = [string]$match.Name
            InterfaceIndex = [int]$match.ifIndex
            InterfaceGuid  = [string]$match.InterfaceGuid
            Action         = $action
            TargetDns      = $targetDns
        })
    }

    $currentSnapshot = Get-NetworkDnsSnapshot -IncludeAllAdapters
    $currentDoh = @($currentSnapshot.DohServers)
    $dohPlans = New-Object System.Collections.Generic.List[object]

    if (-not $SkipDohTemplates) {
        $backupDohByIp = @{}
        foreach ($bd in $backupDohServers) {
            $backupDohByIp[[string]$bd.ServerAddress] = $bd
            $existing = $currentDoh | Where-Object { ([string]$_.ServerAddress) -eq ([string]$bd.ServerAddress) } | Select-Object -First 1
            $op = if ($null -ne $existing) { 'Update' } else { 'Add' }
            $dohPlans.Add([pscustomobject]@{
                Action             = $op
                ServerAddress      = [string]$bd.ServerAddress
                DohTemplate        = [string]$bd.DohTemplate
                AllowFallbackToUdp = [bool]$bd.AllowFallbackToUdp
                AutoUpgrade        = [bool]$bd.AutoUpgrade
            })
        }

        # Remove IPv4 DoH templates that did not exist in the backup so Windows returns to exact captured state.
        foreach ($cd in $currentDoh) {
            if ($cd.AddressFamily -eq 'IPv4' -and -not $backupDohByIp.ContainsKey([string]$cd.ServerAddress)) {
                $dohPlans.Add([pscustomobject]@{
                    Action             = 'RemoveExtraIPv4'
                    ServerAddress      = [string]$cd.ServerAddress
                    DohTemplate        = [string]$cd.DohTemplate
                    AllowFallbackToUdp = [bool]$cd.AllowFallbackToUdp
                    AutoUpgrade        = [bool]$cd.AutoUpgrade
                })
            }
        }
    }

    $nrptPreview = if (-not $SkipNrpt) {
        Restore-NrptFromBackup -BackupPath $BackupPath -ReplaceExisting -DryRun
    } else {
        $null
    }

    if ($DryRun) {
        return [pscustomobject]@{
            DryRun         = $true
            Executed       = $false
            BackupPath     = $BackupPath
            AdapterActions = $adapterPlans.ToArray()
            DohActions     = $dohPlans.ToArray()
            NrptPreview    = $nrptPreview
        }
    }

    if (-not (Test-IsAdministrator)) {
        throw 'Restore-DnsStateBackup requires elevated Administrator privileges when not running with -DryRun.'
    }

    $errors = New-Object System.Collections.Generic.List[string]
    $appliedAdapters = New-Object System.Collections.Generic.List[object]
    $appliedDoh = New-Object System.Collections.Generic.List[object]

    foreach ($dp in $dohPlans) {
        if (-not $PSCmdlet.ShouldProcess($dp.ServerAddress, "DoH template $($dp.Action)")) {
            continue
        }
        try {
            if ($dp.Action -eq 'RemoveExtraIPv4') {
                Remove-DnsClientDohServerAddress -ServerAddress $dp.ServerAddress -ErrorAction Stop
            } elseif ($dp.Action -eq 'Update') {
                Set-DnsClientDohServerAddress -ServerAddress $dp.ServerAddress -DohTemplate $dp.DohTemplate -AllowFallbackToUdp $dp.AllowFallbackToUdp -AutoUpgrade $dp.AutoUpgrade -ErrorAction Stop
            } elseif ($dp.Action -eq 'Add') {
                Add-DnsClientDohServerAddress -ServerAddress $dp.ServerAddress -DohTemplate $dp.DohTemplate -AllowFallbackToUdp $dp.AllowFallbackToUdp -AutoUpgrade $dp.AutoUpgrade -ErrorAction Stop
            }
            $appliedDoh.Add($dp)
        } catch {
            $errors.Add("DoH $($dp.Action) failed for $($dp.ServerAddress): $($_.Exception.Message)")
        }
    }

    foreach ($ap in $adapterPlans) {
        if ($ap.Action -eq 'SkipMissing') {
            $appliedAdapters.Add($ap)
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($ap.AdapterName, "Adapter DNS $($ap.Action)")) {
            continue
        }
        try {
            if ($ap.Action -eq 'ResetToDhcp') {
                Set-DnsClientServerAddress -InterfaceIndex $ap.InterfaceIndex -ResetServerAddresses -ErrorAction Stop
            } elseif ($ap.Action -eq 'SetStaticDns') {
                Set-DnsClientServerAddress -InterfaceIndex $ap.InterfaceIndex -ServerAddresses $ap.TargetDns -ErrorAction Stop
            }
            $appliedAdapters.Add($ap)
        } catch {
            $errors.Add("Adapter DNS restore failed on '$($ap.AdapterName)': $($_.Exception.Message)")
        }
    }

    $nrptResult = $null
    if (-not $SkipNrpt) {
        $nrptResult = Restore-NrptFromBackup -BackupPath $BackupPath -ReplaceExisting
        foreach ($err in @($nrptResult.Errors)) {
            $errors.Add($err)
        }
    }

    $flushResult = Invoke-DnsCacheFlush

    return [pscustomobject]@{
        DryRun          = $false
        Executed        = ($errors.Count -eq 0)
        BackupPath      = $BackupPath
        AdapterResults  = $appliedAdapters.ToArray()
        DohResults      = $appliedDoh.ToArray()
        NrptResult      = $nrptResult
        CacheFlush      = $flushResult
        Errors          = $errors.ToArray()
    }
}

Export-ModuleMember -Function @(
    'Save-DnsStateBackup',
    'Get-DnsBackups',
    'Get-NrptAudit',
    'Clear-StaleNrptRules',
    'Restore-NrptFromBackup',
    'Restore-DnsStateBackup'
)
