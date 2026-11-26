Set-StrictMode -Version Latest

foreach ($modName in @('DnsCommon.psm1', 'DnsBackupAndNrpt.psm1', 'DnsProbe.psm1')) {
    $modPath = Join-Path $PSScriptRoot $modName
    if ($modName -eq 'DnsCommon.psm1' -and -not (Get-Command -Name 'Get-VpnTunnelState' -ErrorAction SilentlyContinue)) {
        Import-Module $modPath -ErrorAction Stop
    } elseif ($modName -eq 'DnsBackupAndNrpt.psm1' -and -not (Get-Command -Name 'Save-DnsStateBackup' -ErrorAction SilentlyContinue)) {
        Import-Module $modPath -ErrorAction Stop
    } elseif ($modName -eq 'DnsProbe.psm1' -and -not (Get-Command -Name 'Invoke-DohQuery' -ErrorAction SilentlyContinue)) {
        Import-Module $modPath -ErrorAction Stop
    }
}

function ConvertTo-AdapterSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Adapter)

    $dnsObj = Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $currentDns = @()
    if ($null -ne $dnsObj) {
        $currentDns = @($dnsObj.ServerAddresses | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }
    return [pscustomobject]@{
        Name                 = [string]$Adapter.Name
        InterfaceDescription = [string]$Adapter.InterfaceDescription
        InterfaceIndex       = [int]$Adapter.ifIndex
        InterfaceGuid        = [string]$Adapter.InterfaceGuid
        Status               = [string]$Adapter.Status
        Virtual              = [bool]$Adapter.Virtual
        CurrentIPv4Dns       = $currentDns
    }
}

function Resolve-TargetAdapters {
    <#
    .SYNOPSIS
        Safely resolves target network adapters for DNS switching (auto, vpn, ethernet, both, custom).
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('auto', 'vpn', 'ethernet', 'both', 'custom')]
        [string]$TargetMode = 'auto',
        [string[]]$AdapterNames = @()
    )

    $allAdapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Name -notlike '*Loopback*' })
    $vpnState = Get-VpnTunnelState
    $warnings = New-Object System.Collections.Generic.List[string]
    $selected = New-Object System.Collections.Generic.List[object]
    $seenIndexes = New-Object System.Collections.Generic.HashSet[int]

    $activeVpnIndexSet = New-Object System.Collections.Generic.HashSet[int]
    foreach ($va in @($vpnState.DetectedAdapters)) {
        if ($null -ne $va -and $null -ne $va.InterfaceIndex) {
            [void]$activeVpnIndexSet.Add([int]$va.InterfaceIndex)
        }
    }
    $activeVpnAdapters = @($allAdapters | Where-Object { $activeVpnIndexSet.Contains([int]$_.ifIndex) })
    if ($activeVpnAdapters.Count -eq 0 -and $vpnState.IsActive -and -not [string]::IsNullOrWhiteSpace([string]$vpnState.AdapterName)) {
        $activeVpnAdapters = @($allAdapters | Where-Object {
            $_.Status -eq 'Up' -and ([string]$_.Name).Equals([string]$vpnState.AdapterName, [System.StringComparison]::OrdinalIgnoreCase)
        })
    }

    $ethAdapter = $allAdapters | Where-Object { ([string]$_.Name).Equals('Ethernet', [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
    $wifiAdapter = $allAdapters | Where-Object { $_.Name -like 'Wi-Fi*' -or $_.Name -like 'WLAN*' } | Select-Object -First 1
    $activePhysical = @($allAdapters | Where-Object { -not $_.Virtual -and $_.Status -eq 'Up' -and -not $activeVpnIndexSet.Contains([int]$_.ifIndex) })

    $addAdapter = {
        param($AdapterObj)
        if ($null -ne $AdapterObj -and $seenIndexes.Add([int]$AdapterObj.ifIndex)) {
            $selected.Add((ConvertTo-AdapterSummary -Adapter $AdapterObj))
        }
    }

    $addPhysicalAuto = {
        if ($activePhysical.Count -gt 0) {
            foreach ($pa in $activePhysical) { & $addAdapter $pa }
        } elseif ($null -ne $ethAdapter) {
            & $addAdapter $ethAdapter
        } elseif ($null -ne $wifiAdapter) {
            & $addAdapter $wifiAdapter
        }
    }

    switch ($TargetMode) {
        'auto' {
            if ($vpnState.IsActive) {
                foreach ($va in $activeVpnAdapters) {
                    & $addAdapter $va
                }
                & $addPhysicalAuto
                if ($activeVpnAdapters.Count -gt 0) {
                    $vpnNames = ($activeVpnAdapters | ForEach-Object { $_.Name }) -join ', '
                    $warnings.Add("Active VPN tunnel detected ($vpnNames): targeting VPN adapter(s) and active physical NIC(s).")
                }
            } else {
                & $addPhysicalAuto
            }
        }
        'vpn' {
            if ($activeVpnAdapters.Count -gt 0) {
                foreach ($va in $activeVpnAdapters) {
                    & $addAdapter $va
                }
            } elseif ($vpnState.AdapterPresent) {
                throw "VPN adapter '$($vpnState.AdapterName)' is currently '$($vpnState.AdapterStatus)'; cannot target disconnected VPN tunnel."
            } else {
                throw 'No active VPN or TUN network adapter was found.'
            }
        }
        'ethernet' {
            if ($null -ne $ethAdapter) {
                & $addAdapter $ethAdapter
                if ($ethAdapter.Status -ne 'Up') {
                    $warnings.Add("Adapter 'Ethernet' status is '$($ethAdapter.Status)'.")
                }
            } elseif ($null -ne $wifiAdapter) {
                & $addAdapter $wifiAdapter
                $warnings.Add("Adapter 'Ethernet' not found; falling back to '$($wifiAdapter.Name)'.")
            } elseif ($activePhysical.Count -gt 0) {
                & $addAdapter $activePhysical[0]
                $warnings.Add("Adapter 'Ethernet' not found; falling back to '$($activePhysical[0].Name)'.")
            } else {
                throw 'No Ethernet or active physical network adapter found.'
            }
        }
        'both' {
            if ($activeVpnAdapters.Count -gt 0) {
                foreach ($va in $activeVpnAdapters) {
                    & $addAdapter $va
                }
            } elseif ($vpnState.AdapterPresent) {
                $warnings.Add("VPN adapter '$($vpnState.AdapterName)' is '$($vpnState.AdapterStatus)' and was skipped.")
            } else {
                $warnings.Add('No active VPN adapter detected; targeting physical adapter(s) only.')
            }

            if ($activePhysical.Count -gt 0) {
                foreach ($pa in $activePhysical) { & $addAdapter $pa }
            } elseif ($null -ne $ethAdapter) {
                & $addAdapter $ethAdapter
            } elseif ($null -ne $wifiAdapter) {
                & $addAdapter $wifiAdapter
            } else {
                $warnings.Add('No physical Ethernet/Wi-Fi adapter found.')
            }
        }
        'custom' {
            $cleanNames = @($AdapterNames | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            if ($cleanNames.Count -eq 0) {
                throw "TargetMode 'custom' requires at least one adapter name in -AdapterNames."
            }
            foreach ($reqName in $cleanNames) {
                $match = $allAdapters | Where-Object { ([string]$_.Name).Equals($reqName.Trim(), [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
                if ($null -eq $match) {
                    $avail = ($allAdapters | ForEach-Object { $_.Name }) -join ', '
                    throw "Adapter '$reqName' not found. Available adapters: $avail"
                }
                & $addAdapter $match
            }
        }
    }

    if ($selected.Count -eq 0) {
        $avail = ($allAdapters | ForEach-Object { "$($_.Name) ($($_.Status))" }) -join ', '
        throw "No target adapters resolved for TargetMode '$TargetMode'. Available adapters: $avail"
    }

    return [pscustomobject]@{
        TargetMode = $TargetMode
        VpnActive  = $vpnState.IsActive
        VpnState   = $vpnState
        Warnings   = $warnings.ToArray()
        Adapters   = $selected.ToArray()
    }
}

function Register-WindowsDohProfile {
    <#
    .SYNOPSIS
        Registers or updates Windows 11 native IPv4 DoH templates for all doh_ips in a DNS profile.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [bool]$AllowFallbackToUdp,
        [bool]$AutoUpgrade,
        [string]$ConfigPath,
        [switch]$DryRun
    )

    $resolvedProfile = if ($Profile -is [string]) {
        Get-DnsProfileById -Id $Profile -ConfigPath $ConfigPath
    } else {
        $Profile
    }

    $effectiveFallback = if ($PSBoundParameters.ContainsKey('AllowFallbackToUdp')) {
        [bool]$AllowFallbackToUdp
    } else {
        [bool]$resolvedProfile.default_allow_udp_fallback
    }
    $effectiveAutoUpgrade = if ($PSBoundParameters.ContainsKey('AutoUpgrade')) {
        [bool]$AutoUpgrade
    } else {
        [bool]$resolvedProfile.auto_upgrade_doh
    }

    $dohTemplate = [string]$resolvedProfile.doh_template
    $targetIps = @($resolvedProfile.doh_ips | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    if ($targetIps.Count -eq 0) {
        $targetIps = @($resolvedProfile.ipv4 | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    }
    if ($targetIps.Count -eq 0) {
        throw "Profile '$($resolvedProfile.id)' does not define any doh_ips or ipv4 addresses."
    }

    if (-not $DryRun -and -not (Test-IsAdministrator)) {
        throw 'Register-WindowsDohProfile requires elevated Administrator privileges when not running with -DryRun.'
    }

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($ip in $targetIps) {
        $existing = Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue | Select-Object -First 1
        $op = if ($null -ne $existing) { 'Update' } else { 'Add' }

        if ($DryRun) {
            $results.Add([pscustomobject]@{
                ServerAddress      = $ip
                DohTemplate        = $dohTemplate
                AllowFallbackToUdp = $effectiveFallback
                AutoUpgrade        = $effectiveAutoUpgrade
                Action             = $op
                Executed           = $false
                Method             = 'DryRun'
                Error              = ''
            })
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($ip, "$op Windows DoH template '$dohTemplate'")) {
            continue
        }

        $methodUsed = 'DnsClientCmdlet'
        $errMsg = ''
        $ok = $false

        try {
            if ($op -eq 'Update') {
                Set-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $dohTemplate -AllowFallbackToUdp $effectiveFallback -AutoUpgrade $effectiveAutoUpgrade -ErrorAction Stop
            } else {
                Add-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $dohTemplate -AllowFallbackToUdp $effectiveFallback -AutoUpgrade $effectiveAutoUpgrade -ErrorAction Stop
            }
            $ok = $true
        } catch {
            $cmdErr = $_.Exception.Message
            # Fallback to netsh dns add/set encryption
            $netshOp = if ($op -eq 'Update') { 'set' } else { 'add' }
            $autoFlag = if ($effectiveAutoUpgrade) { 'yes' } else { 'no' }
            $udpFlag = if ($effectiveFallback) { 'yes' } else { 'no' }
            $netshArgs = @('dns', $netshOp, 'encryption', "server=$ip", "dohtemplate=$dohTemplate", "autoupgrade=$autoFlag", "udpfallback=$udpFlag")
            $netshOut = @(& netsh.exe @netshArgs 2>&1 | ForEach-Object { [string]$_ })
            if ($LASTEXITCODE -eq 0) {
                $ok = $true
                $methodUsed = "netsh ($netshOp)"
            } else {
                $errMsg = "Cmdlet error: $cmdErr | netsh error: $(($netshOut -join ' ').Trim())"
            }
        }

        $results.Add([pscustomobject]@{
            ServerAddress      = $ip
            DohTemplate        = $dohTemplate
            AllowFallbackToUdp = $effectiveFallback
            AutoUpgrade        = $effectiveAutoUpgrade
            Action             = $op
            Executed           = $ok
            Method             = $methodUsed
            Error              = $errMsg
        })

        if (-not $ok) {
            throw "Failed to register Windows DoH template for '$ip': $errMsg"
        }
    }

    return $results.ToArray()
}

function Switch-DnsProfile {
    <#
    .SYNOPSIS
        Safely switches Windows 11 IPv4 DNS + native DoH to a profile with live DoH preflight, backup, optional NRPT cleanup, and verification.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [ValidateSet('auto', 'vpn', 'ethernet', 'both', 'custom')]
        [string]$TargetMode = 'auto',
        [string[]]$AdapterNames = @(),
        [Nullable[bool]]$AllowFallbackToUdp = $null,
        [Nullable[bool]]$AutoUpgrade = $null,
        [switch]$CleanNrpt,
        [switch]$SkipPreflight,
        [string]$BackupDir,
        [string]$ConfigPath,
        [int]$TimeoutSec = 5,
        [switch]$DryRun
    )

    $resolvedProfile = if ($Profile -is [string]) {
        Get-DnsProfileById -Id $Profile -ConfigPath $ConfigPath
    } else {
        $Profile
    }

    if (-not $DryRun -and -not (Test-IsAdministrator)) {
        throw 'Switch-DnsProfile requires elevated Administrator privileges unless -DryRun is specified.'
    }

    $effectiveFallback = if ($null -ne $AllowFallbackToUdp) {
        [bool]$AllowFallbackToUdp
    } else {
        [bool]$resolvedProfile.default_allow_udp_fallback
    }
    $effectiveAutoUpgrade = if ($null -ne $AutoUpgrade) {
        [bool]$AutoUpgrade
    } else {
        [bool]$resolvedProfile.auto_upgrade_doh
    }

    $targetResolution = Resolve-TargetAdapters -TargetMode $TargetMode -AdapterNames $AdapterNames
    $vpnBefore = Get-VpnTunnelState

    # 1. Live DoH preflight before touching any system state.
    $preflightResults = New-Object System.Collections.Generic.List[object]
    $preflightPassed = $true
    if (-not $SkipPreflight) {
        $preflightIp = [string]@($resolvedProfile.doh_ips)[0]
        $preflightDomains = @('cloudcode-pa.googleapis.com', 'accounts.google.com')
        foreach ($pfDomain in $preflightDomains) {
            $pfRes = Invoke-DohQuery -Domain $pfDomain -DohTemplate ([string]$resolvedProfile.doh_template) -ServerIp $preflightIp -TimeoutSec $TimeoutSec -RequireHttp2:([bool]$resolvedProfile.requires_http2)
            $hasBlockedIp = $false
            foreach ($ip in @($pfRes.ARecords)) {
                if ($ip -eq '0.0.0.0' -or $ip -eq '127.0.0.1') {
                    $hasBlockedIp = $true
                }
            }
            $pfOk = ($pfRes.Success -and @($pfRes.ARecords).Count -gt 0 -and -not $hasBlockedIp)
            if (-not $pfOk) {
                $preflightPassed = $false
            }
            $preflightResults.Add([pscustomobject]@{
                Domain      = $pfDomain
                Success     = $pfOk
                HttpStatus  = $pfRes.HttpStatus
                HttpVersion = $pfRes.HttpVersion
                RttMs       = $pfRes.RttMs
                ARecords    = @($pfRes.ARecords)
                Error       = $pfRes.Error
            })
        }

        if (-not $preflightPassed -and -not $DryRun) {
            $failedNames = ($preflightResults.ToArray() | Where-Object { -not $_.Success } | ForEach-Object { "$($_.Domain) ($($_.Error))" }) -join '; '
            throw "DoH preflight failed for profile '$($resolvedProfile.id)' via '$preflightIp': $failedNames. System DNS was NOT modified."
        }
    }

    $nrptAuditBefore = Get-NrptAudit -ConfigPath $ConfigPath
    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($w in @($targetResolution.Warnings)) { $warnings.Add($w) }
    if ($nrptAuditBefore.FlaggedCount -gt 0 -and -not $CleanNrpt) {
        $warnings.Add("$($nrptAuditBefore.FlaggedCount) stale/conflicting NRPT rule(s) detected (e.g. dead 127.0.0.53 / Xbox DNS). Pass -CleanNrpt to back up and remove them.")
    }

    if ($DryRun) {
        $plannedDoh = Register-WindowsDohProfile -Profile $resolvedProfile -AllowFallbackToUdp $effectiveFallback -AutoUpgrade $effectiveAutoUpgrade -ConfigPath $ConfigPath -DryRun
        $plannedNrpt = if ($CleanNrpt) { Clear-StaleNrptRules -BackupDir $BackupDir -ConfigPath $ConfigPath -DryRun } else { $null }
        return [pscustomobject]@{
            Success              = $true
            DryRun               = $true
            Applied              = $false
            ProfileId            = [string]$resolvedProfile.id
            ProfileName          = [string]$resolvedProfile.name
            Category             = [string]$resolvedProfile.category
            TargetMode           = $TargetMode
            TargetAdapters       = @($targetResolution.Adapters)
            TargetIPv4Dns        = @($resolvedProfile.ipv4)
            AllowFallbackToUdp   = $effectiveFallback
            AutoUpgrade          = $effectiveAutoUpgrade
            PreflightSkipped     = [bool]$SkipPreflight
            PreflightPassed      = $preflightPassed
            PreflightResults     = $preflightResults.ToArray()
            PlannedDoh           = $plannedDoh
            NrptFlaggedBefore    = $nrptAuditBefore.FlaggedCount
            PlannedNrptCleanup   = $plannedNrpt
            Warnings             = $warnings.ToArray()
            BackupPath           = $null
        }
    }

    if (-not $PSCmdlet.ShouldProcess("Adapters: $(($targetResolution.Adapters | ForEach-Object { $_.Name }) -join ', ')", "Switch DNS to profile '$($resolvedProfile.id)'")) {
        return [pscustomobject]@{
            Success            = $true
            DryRun             = $false
            Applied            = $false
            ProfileId          = [string]$resolvedProfile.id
            ProfileName        = [string]$resolvedProfile.name
            Category           = [string]$resolvedProfile.category
            TargetMode         = $TargetMode
            AllowFallbackToUdp = $effectiveFallback
            AutoUpgrade        = $effectiveAutoUpgrade
            BackupPath         = $null
            PreflightSkipped   = [bool]$SkipPreflight
            PreflightPassed    = $preflightPassed
            PreflightResults   = $preflightResults.ToArray()
            DohRegistrations   = @()
            AdapterUpdates     = @()
            NrptResult         = $null
            CacheFlush         = $null
            Warnings           = $warnings.ToArray()
            PostVerification   = $null
            Message            = 'Cancelled via -WhatIf / ShouldProcess.'
        }
    }

    # 2. Save state backup before mutating system DNS / DoH / NRPT.
    $backup = Save-DnsStateBackup -BackupDir $BackupDir -Label ("pre-switch-" + [string]$resolvedProfile.id)

    # 3. Register Windows 11 native IPv4 DoH server templates.
    $dohReg = Register-WindowsDohProfile -Profile $resolvedProfile -AllowFallbackToUdp $effectiveFallback -AutoUpgrade $effectiveAutoUpgrade -ConfigPath $ConfigPath

    # 4. Set IPv4 DNS servers on target adapters ONLY (never alter VPN service/routes/MTU/link).
    $adapterUpdates = New-Object System.Collections.Generic.List[object]
    $dnsServers = @($resolvedProfile.ipv4 | ForEach-Object { [string]$_ })
    foreach ($adapter in @($targetResolution.Adapters)) {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses $dnsServers -ErrorAction Stop
        $adapterUpdates.Add([pscustomobject]@{
            Name           = $adapter.Name
            InterfaceIndex = $adapter.InterfaceIndex
            PreviousDns    = @($adapter.CurrentIPv4Dns)
            AppliedDns     = $dnsServers
        })
    }

    # 5. Optional stale NRPT cleanup (Clear-StaleNrptRules also takes its own safety backup if needed).
    $nrptResult = $null
    if ($CleanNrpt) {
        $nrptResult = Clear-StaleNrptRules -BackupDir $BackupDir -ConfigPath $ConfigPath
    }

    # 6. Flush DNS resolver cache.
    $cacheFlush = Invoke-DnsCacheFlush

    # 7. Post-switch verification.
    $postSnapshot = Get-NetworkDnsSnapshot
    $vpnAfter = Get-VpnTunnelState
    $allAdaptersVerified = $true
    foreach ($au in $adapterUpdates) {
        $live = $postSnapshot.Adapters | Where-Object { $_.InterfaceIndex -eq $au.InterfaceIndex } | Select-Object -First 1
        $liveDns = if ($null -ne $live) { @($live.IPv4DnsServers) } else { @() }
        if (($liveDns -join ',') -ne ($dnsServers -join ',')) {
            $allAdaptersVerified = $false
        }
    }

    $allDohVerified = $true
    foreach ($dip in @($resolvedProfile.doh_ips)) {
        $liveDoh = $postSnapshot.DohServers | Where-Object { $_.ServerAddress -eq [string]$dip } | Select-Object -First 1
        if ($null -eq $liveDoh -or $liveDoh.DohTemplate -ne [string]$resolvedProfile.doh_template) {
            $allDohVerified = $false
        }
    }

    $vpnPreserved = $true
    if ($vpnBefore.IsActive -and -not $vpnAfter.IsActive) {
        $vpnPreserved = $false
    }

    $sysResolveOk = $false
    $sysResolveIps = @()
    $sysResolveMs = $null
    $sysResolveErr = ''
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $addrs = [System.Net.Dns]::GetHostAddresses('cloudcode-pa.googleapis.com')
        $sw.Stop()
        $sysResolveMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
        $sysResolveIps = @($addrs | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | ForEach-Object { $_.ToString() })
        $sysResolveOk = ($sysResolveIps.Count -gt 0)
    } catch {
        $sysResolveErr = $_.Exception.GetBaseException().Message
    }

    return [pscustomobject]@{
        Success            = ($allAdaptersVerified -and $allDohVerified -and $vpnPreserved)
        DryRun             = $false
        Applied            = $true
        ProfileId          = [string]$resolvedProfile.id
        ProfileName        = [string]$resolvedProfile.name
        Category           = [string]$resolvedProfile.category
        TargetMode         = $TargetMode
        AllowFallbackToUdp = $effectiveFallback
        AutoUpgrade        = $effectiveAutoUpgrade
        BackupPath         = $backup.BackupPath
        PreflightSkipped   = [bool]$SkipPreflight
        PreflightPassed    = $preflightPassed
        PreflightResults   = $preflightResults.ToArray()
        DohRegistrations   = $dohReg
        AdapterUpdates     = $adapterUpdates.ToArray()
        NrptResult         = $nrptResult
        CacheFlush         = $cacheFlush
        Warnings           = $warnings.ToArray()
        PostVerification   = [pscustomobject]@{
            AdaptersVerified     = $allAdaptersVerified
            DohTemplatesVerified = $allDohVerified
            VpnPreserved         = $vpnPreserved
            SystemResolveOk      = $sysResolveOk
            SystemResolveRttMs   = $sysResolveMs
            SystemResolveIPv4    = $sysResolveIps
            SystemResolveError   = $sysResolveErr
        }
    }
}

function Reset-DnsToDefault {
    <#
    .SYNOPSIS
        Resets physical and active VPN/TUN adapter IPv4 DNS settings to automatic/DHCP without stopping VPN services or altering routes.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [ValidateSet('auto', 'vpn', 'ethernet', 'both', 'custom')]
        [string]$TargetMode = 'auto',
        [string[]]$AdapterNames = @(),
        [string]$BackupDir,
        [switch]$DryRun
    )

    if (-not $DryRun -and -not (Test-IsAdministrator)) {
        throw 'Reset-DnsToDefault requires elevated Administrator privileges unless -DryRun is specified.'
    }

    $targetResolution = Resolve-TargetAdapters -TargetMode $TargetMode -AdapterNames $AdapterNames
    $vpnBefore = Get-VpnTunnelState
    $activeVpnIndexSet = New-Object System.Collections.Generic.HashSet[int]
    foreach ($va in @($vpnBefore.DetectedAdapters)) {
        if ($null -ne $va -and $null -ne $va.InterfaceIndex) {
            [void]$activeVpnIndexSet.Add([int]$va.InterfaceIndex)
        }
    }

    $plans = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($w in @($targetResolution.Warnings)) {
        $warnings.Add($w)
    }

    $hasVpnTarget = $false
    foreach ($adapter in @($targetResolution.Adapters)) {
        $isVpnAdapter = $activeVpnIndexSet.Contains([int]$adapter.InterfaceIndex)
        if ($isVpnAdapter) {
            $hasVpnTarget = $true
        }
        $plans.Add([pscustomobject]@{
            Name           = $adapter.Name
            InterfaceIndex = $adapter.InterfaceIndex
            AdapterType    = if ($isVpnAdapter) { 'VpnTunnel' } else { 'Physical' }
            PreviousDns    = @($adapter.CurrentIPv4Dns)
            Action         = 'ResetToDhcp'
            TargetDns      = @()
            Note           = if ($isVpnAdapter) {
                'Resets VPN/TUN adapter DNS to automatic/DHCP; reconnecting your VPN client restores its own TUN DNS.'
            } else {
                'Resets physical adapter DNS to DHCP.'
            }
        })
    }

    if ($hasVpnTarget) {
        $warnings.Add('Active VPN/TUN adapter DNS will be reset to automatic/DHCP. Reconnect your VPN client if you want it to re-apply its own default TUN DNS.')
    }

    if ($DryRun) {
        return [pscustomobject]@{
            Success        = $true
            DryRun         = $true
            Applied        = $false
            TargetMode     = $TargetMode
            PlannedActions = $plans.ToArray()
            Warnings       = $warnings.ToArray()
            BackupPath     = $null
        }
    }

    if (-not $PSCmdlet.ShouldProcess("Adapters: $(($plans | ForEach-Object { $_.Name }) -join ', ')", 'Reset DNS servers to default')) {
        return [pscustomobject]@{
            Success = $true
            DryRun  = $false
            Applied = $false
            Message = 'Cancelled via -WhatIf / ShouldProcess.'
        }
    }

    $backup = Save-DnsStateBackup -BackupDir $BackupDir -Label 'pre-reset-default'

    foreach ($plan in $plans) {
        Set-DnsClientServerAddress -InterfaceIndex $plan.InterfaceIndex -ResetServerAddresses -ErrorAction Stop
    }

    $cacheFlush = Invoke-DnsCacheFlush
    $postSnapshot = Get-NetworkDnsSnapshot
    $vpnAfter = Get-VpnTunnelState
    $vpnPreserved = $true
    if ($vpnBefore.IsActive -and -not $vpnAfter.IsActive) {
        $vpnPreserved = $false
    }

    return [pscustomobject]@{
        Success       = $true
        DryRun        = $false
        Applied       = $true
        TargetMode    = $TargetMode
        BackupPath    = $backup.BackupPath
        Actions       = $plans.ToArray()
        Warnings      = $warnings.ToArray()
        CacheFlush    = $cacheFlush
        VpnPreserved  = $vpnPreserved
        SnapshotAfter = $postSnapshot
    }
}

Export-ModuleMember -Function @(
    'Resolve-TargetAdapters',
    'Register-WindowsDohProfile',
    'Switch-DnsProfile',
    'Reset-DnsToDefault'
)
