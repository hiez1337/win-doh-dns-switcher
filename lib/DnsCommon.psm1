Set-StrictMode -Version Latest

# Shared helper utilities and read-only system/config inspection for Windows 11 DNS Switcher.
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.

function Get-ProjectRootPath {
    [CmdletBinding()]
    param()
    return (Split-Path -Parent $PSScriptRoot)
}

function Test-ObjectHasProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $InputObject) {
        return $false
    }
    return ($null -ne $InputObject.PSObject.Properties[$Name])
}

function Get-ObjectPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )
    if (Test-ObjectHasProperty -InputObject $InputObject -Name $Name) {
        return $InputObject.PSObject.Properties[$Name].Value
    }
    return $Default
}

function Test-ValidIPv4Address {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Address
    )
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) {
        return $false
    }
    return ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork)
}

function Write-Utf8NoBomFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Read-Utf8File {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Format-WindowsArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )
    if ($Value.Length -eq 0) {
        return '""'
    }
    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    # Escape backslashes before double quotes and trailing backslashes per CommandLineToArgvW.
    $escaped = [System.Text.RegularExpressions.Regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [System.Text.RegularExpressions.Regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Assert-ProfileEntryValid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][int]$Index
    )
    $requiredFields = @(
        'id', 'name', 'category', 'recommended_for', 'ipv4', 'doh_template',
        'doh_ips', 'dot_host', 'requires_http2', 'default_allow_udp_fallback',
        'auto_upgrade_doh', 'smart_proxy_domains', 'trust_note', 'notes'
    )
    foreach ($field in $requiredFields) {
        if (-not (Test-ObjectHasProperty -InputObject $Profile -Name $field)) {
            throw "Invalid profiles.json: profile at index $Index is missing required property '$field'."
        }
    }

    $id = [string]$Profile.id
    if ($id -notmatch '^[a-z0-9-]+$') {
        throw "Invalid profiles.json: profile id '$id' must match ^[a-z0-9-]+$."
    }
    if ([string]::IsNullOrWhiteSpace([string]$Profile.name)) {
        throw "Invalid profiles.json: profile '$id' has an empty name."
    }
    $validCategories = @('vpn-clean', 'rf-smart', 'rf-clean')
    if ($validCategories -notcontains [string]$Profile.category) {
        throw "Invalid profiles.json: profile '$id' has invalid category '$($Profile.category)'."
    }

    $recFor = @($Profile.recommended_for | Where-Object { $null -ne $_ })
    if ($recFor.Count -lt 1) {
        throw "Invalid profiles.json: profile '$id' must have at least one recommended_for value."
    }
    foreach ($tag in $recFor) {
        if (@('vpn-on', 'vpn-off') -notcontains [string]$tag) {
            throw "Invalid profiles.json: profile '$id' has invalid recommended_for value '$tag'."
        }
    }

    $ipv4List = @($Profile.ipv4 | Where-Object { $null -ne $_ })
    if ($ipv4List.Count -lt 1) {
        throw "Invalid profiles.json: profile '$id' must have at least one ipv4 address."
    }
    foreach ($ip in $ipv4List) {
        if (-not (Test-ValidIPv4Address -Address ([string]$ip))) {
            throw "Invalid profiles.json: profile '$id' contains invalid IPv4 '$ip'."
        }
    }

    $dohTemplate = [string]$Profile.doh_template
    if ($dohTemplate -notmatch '^https://[^\s/]+/.*') {
        throw "Invalid profiles.json: profile '$id' has invalid doh_template '$dohTemplate'."
    }

    $dohIps = @($Profile.doh_ips | Where-Object { $null -ne $_ })
    if ($dohIps.Count -lt 1) {
        throw "Invalid profiles.json: profile '$id' must have at least one doh_ips entry."
    }
    foreach ($ip in $dohIps) {
        if (-not (Test-ValidIPv4Address -Address ([string]$ip))) {
            throw "Invalid profiles.json: profile '$id' contains invalid doh_ips IPv4 '$ip'."
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$Profile.dot_host)) {
        throw "Invalid profiles.json: profile '$id' has an empty dot_host."
    }
    foreach ($boolField in @('requires_http2', 'default_allow_udp_fallback', 'auto_upgrade_doh')) {
        if ($Profile.$boolField -isnot [bool]) {
            throw "Invalid profiles.json: profile '$id' field '$boolField' must be a boolean."
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Profile.trust_note)) {
        throw "Invalid profiles.json: profile '$id' has an empty trust_note."
    }
    if ([string]::IsNullOrWhiteSpace([string]$Profile.notes)) {
        throw "Invalid profiles.json: profile '$id' has an empty notes."
    }
}

function Get-DnsProfilesConfig {
    <#
    .SYNOPSIS
        Loads and validates config\profiles.json.
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath
    )

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path (Get-ProjectRootPath) 'config\profiles.json'
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new("DNS profiles configuration file not found at '$ConfigPath'.", $ConfigPath)
    }

    $raw = Read-Utf8File -Path $ConfigPath
    try {
        $config = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Failed to parse JSON configuration '$ConfigPath': $($_.Exception.Message)"
    }

    $requiredTop = @('schema_version', 'generated_at', 'environment_notes', 'deprecated_or_blocked', 'test_domains', 'profiles')
    foreach ($key in $requiredTop) {
        if (-not (Test-ObjectHasProperty -InputObject $config -Name $key)) {
            throw "Invalid profiles.json '$ConfigPath': missing required top-level key '$key'."
        }
    }
    if ([int]$config.schema_version -lt 1) {
        throw "Invalid profiles.json '$ConfigPath': schema_version must be >= 1."
    }

    $domainGroups = @('antigravity_core', 'google_auth', 'ai_inference', 'ecosystem')
    foreach ($group in $domainGroups) {
        if (-not (Test-ObjectHasProperty -InputObject $config.test_domains -Name $group)) {
            throw "Invalid profiles.json '$ConfigPath': test_domains missing group '$group'."
        }
        $items = @($config.test_domains.$group | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($items.Count -lt 1) {
            throw "Invalid profiles.json '$ConfigPath': test_domains.$group must contain at least one domain."
        }
    }

    $deprecated = @($config.deprecated_or_blocked | Where-Object { $null -ne $_ })
    if ($deprecated.Count -lt 1) {
        throw "Invalid profiles.json '$ConfigPath': deprecated_or_blocked must contain at least one entry."
    }
    foreach ($entry in $deprecated) {
        if (-not (Test-ObjectHasProperty -InputObject $entry -Name 'ip') -or -not (Test-ValidIPv4Address -Address ([string]$entry.ip))) {
            throw "Invalid profiles.json '$ConfigPath': deprecated_or_blocked contains invalid IPv4 entry."
        }
    }

    $profiles = @($config.profiles | Where-Object { $null -ne $_ })
    if ($profiles.Count -lt 1) {
        throw "Invalid profiles.json '$ConfigPath': profiles list must not be empty."
    }

    $seenIds = @{}
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        $p = $profiles[$i]
        Assert-ProfileEntryValid -Profile $p -Index $i
        $keyId = ([string]$p.id).ToLowerInvariant()
        if ($seenIds.ContainsKey($keyId)) {
            throw "Invalid profiles.json '$ConfigPath': duplicate profile id '$($p.id)'."
        }
        $seenIds[$keyId] = $true
    }

    return $config
}

function Get-DnsProfileById {
    <#
    .SYNOPSIS
        Resolves a DNS profile by id from config\profiles.json or throws a clear error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$ConfigPath
    )

    if ([string]::IsNullOrWhiteSpace($Id)) {
        throw 'Profile Id must not be empty.'
    }

    $config = Get-DnsProfilesConfig -ConfigPath $ConfigPath
    $profiles = @($config.profiles)
    foreach ($profile in $profiles) {
        if (([string]$profile.id).Equals($Id, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $profile
        }
    }

    $available = ($profiles | ForEach-Object { $_.id }) -join ', '
    throw "Unknown DNS profile '$Id'. Available profile IDs: $available"
}

function Test-IsAdministrator {
    <#
    .SYNOPSIS
        Returns $true if the current PowerShell process has elevated Administrator privileges.
    #>
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevation {
    <#
    .SYNOPSIS
        Re-launches a PowerShell script elevated via UAC (-Verb RunAs) if not already Administrator.
    #>
    [CmdletBinding()]
    param(
        [string]$ScriptPath,
        [string[]]$Arguments = @(),
        [switch]$NoWait
    )

    if (Test-IsAdministrator) {
        return [pscustomobject]@{
            Elevated   = $true
            Relaunched = $false
            ProcessId  = $PID
            ExitCode   = 0
        }
    }

    if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
        if (Test-Path variable:PSCommandPath) {
            $ScriptPath = $PSCommandPath
        }
        if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
            $ScriptPath = $MyInvocation.ScriptName
        }
    }
    if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
        throw 'Invoke-SelfElevation requires -ScriptPath when not invoked directly from a script file.'
    }

    $resolvedScript = (Resolve-Path -LiteralPath $ScriptPath -ErrorAction Stop).Path
    $hostExe = (Get-Process -Id $PID -ErrorAction Stop).Path
    if ([string]::IsNullOrWhiteSpace($hostExe)) {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $hostExe = 'pwsh.exe'
        } else {
            $hostExe = 'powershell.exe'
        }
    }

    $argTokens = New-Object System.Collections.Generic.List[string]
    $argTokens.Add('-NoProfile')
    $argTokens.Add('-ExecutionPolicy')
    $argTokens.Add('Bypass')
    $argTokens.Add('-File')
    $argTokens.Add((Format-WindowsArgument -Value $resolvedScript))

    foreach ($arg in @($Arguments)) {
        if ($null -ne $arg) {
            $argTokens.Add((Format-WindowsArgument -Value ([string]$arg)))
        }
    }

    $joinedArgs = ($argTokens.ToArray()) -join ' '
    try {
        $proc = Start-Process -FilePath $hostExe -ArgumentList $joinedArgs -Verb RunAs -PassThru -ErrorAction Stop
    } catch {
        throw "Failed to elevate script '$resolvedScript' via UAC: $($_.Exception.Message)"
    }

    $exitCode = $null
    if (-not $NoWait -and $null -ne $proc) {
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
    }

    return [pscustomobject]@{
        Elevated   = $false
        Relaunched = $true
        HostExe    = $hostExe
        ScriptPath = $resolvedScript
        ProcessId  = if ($null -ne $proc) { $proc.Id } else { $null }
        ExitCode   = $exitCode
    }
}

function Get-VpnTunnelState {
    <#
    .SYNOPSIS
        Universal read-only detection of active VPN/TUN/TAP adapters and Windows RAS VPN connections.
    #>
    [CmdletBinding()]
    param()

    $excludeRegex = '(?i)(vEthernet|WSL|Docker|VMware|VirtualBox|Bluetooth|Loopback|Teredo|6to4|IP-HTTPS|ISATAP|Kernel Debug)'
    $vpnPatternRegex = '(?i)(sing-tun|wintun|wireguard|openvpn|tap-windows|vpn|utun|(?<![a-z])tun(?![a-z])|-tun\b|\btun-|amnezia|nekoray|nekobox|hiddify|v2ray|xray|clash|outline|warp|mullvad|proton|tailscale|nordlynx|ikev2|sstp|l2tp)'
    $tunDriverRegex = '(?i)(sing-tun|wintun|clash|nekoray|nekobox|hiddify|v2ray|xray|amnezia|mihomo|utun|(?<![a-z])tun(?![a-z])|-tun\b|\btun-)'
    $privateOrSpecialRouteRegex = '^(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|22[4-9]\.|23[0-9]\.|24[0-9]\.|25[0-5]\.)'

    $rasConnections = New-Object System.Collections.Generic.List[object]
    if (Get-Command -Name 'Get-VpnConnection' -ErrorAction SilentlyContinue) {
        try {
            $rasRaw = @(Get-VpnConnection -ErrorAction SilentlyContinue | Where-Object {
                $null -ne $_ -and [string]$_.ConnectionStatus -eq 'Connected'
            })
            foreach ($rc in $rasRaw) {
                $rasConnections.Add([pscustomobject]@{
                    Name             = [string]$rc.Name
                    ConnectionStatus = [string]$rc.ConnectionStatus
                    TunnelType       = [string](Get-ObjectPropertyValue -InputObject $rc -Name 'TunnelType' -Default '')
                    SplitTunneling   = [bool](Get-ObjectPropertyValue -InputObject $rc -Name 'SplitTunneling' -Default $false)
                })
            }
        } catch {
            # RAS VPN enumeration may be unavailable on some Windows configurations.
        }
    }

    $rasNames = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($rc in $rasConnections) {
        if (-not [string]::IsNullOrWhiteSpace($rc.Name)) {
            [void]$rasNames.Add($rc.Name)
        }
    }

    $allAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Sort-Object -Property ifIndex)
    $detectedAdapters = New-Object System.Collections.Generic.List[object]
    $inactiveCandidates = New-Object System.Collections.Generic.List[object]

    foreach ($adapter in $allAdapters) {
        $name = [string]$adapter.Name
        $desc = [string]$adapter.InterfaceDescription
        if ($name -match $excludeRegex -or $desc -match $excludeRegex) {
            continue
        }

        $status = [string]$adapter.Status
        $isPatternMatch = ($name -match $vpnPatternRegex -or $desc -match $vpnPatternRegex -or $rasNames.Contains($name))
        $isVirtual = [bool]$adapter.Virtual

        if ($status -ne 'Up') {
            # Skip built-in Windows WAN Miniports when inactive so stock systems report Absent.
            if ($isPatternMatch -and $desc -notmatch '(?i)^WAN Miniport') {
                $inactiveCandidates.Add($adapter)
            }
            continue
        }

        $ifIndex = [int]$adapter.ifIndex
        $ifGuid = [string]$adapter.InterfaceGuid
        $ipObjects = @(Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        $ipv4List = @($ipObjects | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
        $usableIpv4 = @($ipObjects | Where-Object {
            $addr = [string]$_.IPAddress
            -not [string]::IsNullOrWhiteSpace($addr) -and $addr -notlike '169.254.*' -and $addr -notlike '127.*'
        })

        $dnsObj = Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $dnsList = @()
        if ($null -ne $dnsObj) {
            $dnsList = @($dnsObj.ServerAddresses | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        }

        $ipIf = Get-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        $ifMetric = if ($null -ne $ipIf) { $ipIf.InterfaceMetric } else { $null }
        $autoMetric = if ($null -ne $ipIf) { [string]$ipIf.AutomaticMetric } else { $null }
        if ($null -eq $ifMetric -or [string]::IsNullOrWhiteSpace([string]$ifMetric)) {
            $wmiIf = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex=$ifIndex" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $wmiIf) {
                $ifMetric = $wmiIf.IPConnectionMetric
            }
        }

        $routes = @(Get-NetRoute -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        $routeCount = $routes.Count

        $isHeuristicMatch = $false
        if (-not $isPatternMatch -and $isVirtual -and $usableIpv4.Count -gt 0) {
            $hasDefaultRoute = $false
            $publicRouteCount = 0
            foreach ($rt in $routes) {
                $pfx = [string]$rt.DestinationPrefix
                if ($pfx -eq '0.0.0.0/0' -or $pfx -eq '0.0.0.0/1' -or $pfx -eq '128.0.0.0/1') {
                    $hasDefaultRoute = $true
                    break
                }
                if ($pfx -notmatch $privateOrSpecialRouteRegex -and $pfx -ne '255.255.255.255/32') {
                    $publicRouteCount++
                }
            }
            $metricOk = ($null -eq $ifMetric -or [int]$ifMetric -le 100)
            if ($hasDefaultRoute -or ($publicRouteCount -ge 2 -and $metricOk)) {
                $isHeuristicMatch = $true
            }
        }

        if ($isPatternMatch -or $isHeuristicMatch) {
            $isTunCapable = ($name -match $tunDriverRegex -or $desc -match $tunDriverRegex)
            $detectedAdapters.Add([pscustomobject]@{
                Name                 = $name
                InterfaceDescription = $desc
                Status               = $status
                InterfaceIndex       = $ifIndex
                InterfaceGuid        = $ifGuid
                IPv4Addresses        = $ipv4List
                DnsServers           = $dnsList
                InterfaceMetric      = $ifMetric
                AutomaticMetric      = $autoMetric
                IPv4RouteCount       = $routeCount
                IsTunHijackCapable   = $isTunCapable
            })
        }
    }

    $sortedDetected = @($detectedAdapters.ToArray() | Sort-Object -Property @(
        @{ Expression = { if ($_.IsTunHijackCapable) { 0 } else { 1 } }; Ascending = $true },
        @{ Expression = { if ($null -eq $_.InterfaceMetric) { 999999 } else { [int]$_.InterfaceMetric } }; Ascending = $true },
        @{ Expression = { $_.IPv4RouteCount }; Descending = $true },
        @{ Expression = { $_.InterfaceIndex }; Ascending = $true }
    ))

    $primaryActive = if ($sortedDetected.Count -gt 0) { $sortedDetected[0] } else { $null }
    $primaryInactive = if ($null -eq $primaryActive -and $inactiveCandidates.Count -gt 0) { $inactiveCandidates[0] } else { $null }

    $adapterPresent = ($null -ne $primaryActive -or $null -ne $primaryInactive)
    $isActive = ($sortedDetected.Count -gt 0 -or $rasConnections.Count -gt 0)
    $hijackExpected = ($sortedDetected.Count -gt 0 -and (@($sortedDetected | Where-Object { $_.IsTunHijackCapable }).Count -gt 0))

    if ($null -ne $primaryActive) {
        $adapterName = [string]$primaryActive.Name
        $ifDesc = [string]$primaryActive.InterfaceDescription
        $adapterStatus = [string]$primaryActive.Status
        $ifIndexOut = [int]$primaryActive.InterfaceIndex
        $ifGuidOut = [string]$primaryActive.InterfaceGuid
        $ipv4Out = @($primaryActive.IPv4Addresses)
        $dnsOut = @($primaryActive.DnsServers)
        $metricOut = $primaryActive.InterfaceMetric
        $autoMetricOut = $primaryActive.AutomaticMetric
        $routeCountOut = [int]$primaryActive.IPv4RouteCount
    } elseif ($null -ne $primaryInactive) {
        $inIdx = [int]$primaryInactive.ifIndex
        $inDnsObj = Get-DnsClientServerAddress -InterfaceIndex $inIdx -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $inDns = if ($null -ne $inDnsObj) { @($inDnsObj.ServerAddresses | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) } else { @() }
        $inIps = @(Get-NetIPAddress -InterfaceIndex $inIdx -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
        $inIf = Get-NetIPInterface -InterfaceIndex $inIdx -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        $inRoutes = @(Get-NetRoute -InterfaceIndex $inIdx -AddressFamily IPv4 -ErrorAction SilentlyContinue).Count

        $adapterName = [string]$primaryInactive.Name
        $ifDesc = [string]$primaryInactive.InterfaceDescription
        $adapterStatus = [string]$primaryInactive.Status
        $ifIndexOut = $inIdx
        $ifGuidOut = [string]$primaryInactive.InterfaceGuid
        $ipv4Out = $inIps
        $dnsOut = $inDns
        $metricOut = if ($null -ne $inIf) { $inIf.InterfaceMetric } else { $null }
        $autoMetricOut = if ($null -ne $inIf) { [string]$inIf.AutomaticMetric } else { $null }
        $routeCountOut = [int]$inRoutes
    } else {
        $adapterName = $null
        $ifDesc = $null
        $adapterStatus = if ($rasConnections.Count -gt 0) { 'Connected' } else { 'Absent' }
        $ifIndexOut = $null
        $ifGuidOut = $null
        $ipv4Out = @()
        $dnsOut = @()
        $metricOut = $null
        $autoMetricOut = $null
        $routeCountOut = 0
    }

    return [pscustomobject]@{
        IsActive             = $isActive
        AdapterPresent       = $adapterPresent
        AdapterName          = $adapterName
        InterfaceDescription = $ifDesc
        AdapterStatus        = $adapterStatus
        InterfaceIndex       = $ifIndexOut
        InterfaceGuid        = $ifGuidOut
        IPv4Addresses        = $ipv4Out
        DnsServers           = $dnsOut
        InterfaceMetric      = $metricOut
        AutomaticMetric      = $autoMetricOut
        IPv4RouteCount       = $routeCountOut
        DetectedAdapters     = $sortedDetected
        RasConnections       = $rasConnections.ToArray()
        HijackDnsExpected    = $hijackExpected
    }
}

function Get-DohServersFromCmdletOrNetsh {
    [CmdletBinding()]
    param()

    $results = New-Object System.Collections.Generic.List[object]
    $source = 'Get-DnsClientDohServerAddress'

    $cmd = Get-Command -Name 'Get-DnsClientDohServerAddress' -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        try {
            $entries = @(Get-DnsClientDohServerAddress -ErrorAction Stop)
            foreach ($entry in $entries) {
                $addr = [string]$entry.ServerAddress
                $family = if ($addr -like '*:*') { 'IPv6' } else { 'IPv4' }
                $results.Add([pscustomobject]@{
                    ServerAddress      = $addr
                    AddressFamily      = $family
                    DohTemplate        = [string]$entry.DohTemplate
                    AllowFallbackToUdp = [bool]$entry.AllowFallbackToUdp
                    AutoUpgrade        = [bool]$entry.AutoUpgrade
                    Source             = $source
                })
            }
            return [pscustomobject]@{
                Source  = $source
                Servers = $results.ToArray()
            }
        } catch {
            # Fall through to netsh parser if CIM cmdlet fails.
        }
    }

    $source = 'netsh'
    $lines = @(& netsh dns show encryption 2>&1)
    $currentIp = $null
    $currentTemplate = $null
    $currentAuto = $false
    $currentFallback = $false

    foreach ($rawLine in $lines) {
        $line = ([string]$rawLine).Trim()
        if ($line -match '([0-9]{1,3}(?:\.[0-9]{1,3}){3}|[0-9a-fA-F:]*:[0-9a-fA-F:]+)\s*$') {
            $candidateIp = $Matches[1]
            $parsed = $null
            if ([System.Net.IPAddress]::TryParse($candidateIp, [ref]$parsed)) {
                if ($null -ne $currentIp) {
                    $fam = if ($currentIp -like '*:*') { 'IPv6' } else { 'IPv4' }
                    $results.Add([pscustomobject]@{
                        ServerAddress      = $currentIp
                        AddressFamily      = $fam
                        DohTemplate        = $currentTemplate
                        AllowFallbackToUdp = $currentFallback
                        AutoUpgrade        = $currentAuto
                        Source             = $source
                    })
                }
                $currentIp = $candidateIp
                $currentTemplate = $null
                $currentAuto = $false
                $currentFallback = $false
                continue
            }
        }
        if ($null -ne $currentIp) {
            if ($line -match ':\s*(https://\S+)\s*$') {
                $currentTemplate = $Matches[1]
            } elseif ($line -match '(?i)(autoupgrade|\u0430\u0432\u0442\u043e\u043c\u0430\u0442\u0438\u0447\u0435\u0441\u043a\u043e\u0435 \u043e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u0435).*:\s*(yes|no|true|false)') {
                $currentAuto = ($Matches[2] -match '^(?i)(yes|true)$')
            } elseif ($line -match '(?i)(udp|fallback|\u0440\u0435\u0437\u0435\u0440\u0432).*:\s*(yes|no|true|false)') {
                $currentFallback = ($Matches[2] -match '^(?i)(yes|true)$')
            }
        }
    }
    if ($null -ne $currentIp) {
        $fam = if ($currentIp -like '*:*') { 'IPv6' } else { 'IPv4' }
        $results.Add([pscustomobject]@{
            ServerAddress      = $currentIp
            AddressFamily      = $fam
            DohTemplate        = $currentTemplate
            AllowFallbackToUdp = $currentFallback
            AutoUpgrade        = $currentAuto
            Source             = $source
        })
    }

    return [pscustomobject]@{
        Source  = $source
        Servers = $results.ToArray()
    }
}

function Get-InterfaceDohRegistrySettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InterfaceGuid
    )

    $guidLower = $InterfaceGuid.ToLowerInvariant()
    $basePath = "HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters\$guidLower\DohInterfaceSettings"
    $entries = New-Object System.Collections.Generic.List[object]

    foreach ($subType in @('Doh', 'Doh6')) {
        $typePath = Join-Path $basePath $subType
        if (-not (Test-Path -LiteralPath $typePath)) {
            continue
        }
        $subKeys = @(Get-ChildItem -LiteralPath $typePath -ErrorAction SilentlyContinue)
        foreach ($sk in $subKeys) {
            $props = Get-ItemProperty -LiteralPath $sk.PSPath -ErrorAction SilentlyContinue
            $propMap = [ordered]@{}
            if ($null -ne $props) {
                foreach ($p in $props.PSObject.Properties) {
                    if (@('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider') -notcontains $p.Name) {
                        $propMap[$p.Name] = $p.Value
                    }
                }
            }
            $entries.Add([pscustomobject]@{
                Family       = $subType
                ServerKey    = $sk.PSChildName
                RegistryPath = $sk.Name
                Properties   = [pscustomobject]$propMap
            })
        }
    }

    return $entries.ToArray()
}

function Get-NetworkDnsSnapshot {
    <#
    .SYNOPSIS
        Read-only snapshot of active IPv4 adapters, their DNS settings, Windows DoH templates, and per-interface DoH settings.
    #>
    [CmdletBinding()]
    param(
        [switch]$IncludeAllAdapters
    )

    $vpnState = Get-VpnTunnelState
    $activeVpnIndexes = New-Object System.Collections.Generic.HashSet[int]
    foreach ($va in @($vpnState.DetectedAdapters)) {
        if ($null -ne $va -and $null -ne $va.InterfaceIndex) {
            [void]$activeVpnIndexes.Add([int]$va.InterfaceIndex)
        }
    }

    $allAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Sort-Object -Property ifIndex)
    $selectedAdapters = New-Object System.Collections.Generic.List[object]

    foreach ($adapter in $allAdapters) {
        $name = [string]$adapter.Name
        if ($name -like '*Loopback*') {
            continue
        }
        $ifIndex = [int]$adapter.ifIndex
        $isActiveVpn = $activeVpnIndexes.Contains($ifIndex)
        $isPrimaryName = ($name -ieq 'Ethernet' -or $name -like 'Ethernet *' -or $name -like 'Wi-Fi*' -or $name -like 'WLAN*')
        $isUpPhysical = (-not [bool]$adapter.Virtual -and [string]$adapter.Status -eq 'Up')
        if (-not $IncludeAllAdapters) {
            if (-not ($isActiveVpn -or $isPrimaryName -or $isUpPhysical)) {
                continue
            }
        }
        $guid = [string]$adapter.InterfaceGuid
        $ipv4Addrs = @(Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
        $dnsObj = Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $dnsServers = @()
        if ($null -ne $dnsObj) {
            $dnsServers = @($dnsObj.ServerAddresses | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        }

        $ipIf = Get-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        $ifMetric = if ($null -ne $ipIf) { $ipIf.InterfaceMetric } else { $null }
        $autoMetric = if ($null -ne $ipIf) { [string]$ipIf.AutomaticMetric } else { $null }
        if ($null -eq $ifMetric -or [string]::IsNullOrWhiteSpace([string]$ifMetric)) {
            $wmiIf = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex=$ifIndex" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $wmiIf) {
                $ifMetric = $wmiIf.IPConnectionMetric
            }
        }

        $tcpipPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid"
        $isDhcpDns = $true
        $configuredNs = ''
        $dhcpNs = ''
        if (Test-Path -LiteralPath $tcpipPath) {
            $tcpProps = Get-ItemProperty -LiteralPath $tcpipPath -ErrorAction SilentlyContinue
            $configuredNs = [string](Get-ObjectPropertyValue -InputObject $tcpProps -Name 'NameServer' -Default '')
            $dhcpNs = [string](Get-ObjectPropertyValue -InputObject $tcpProps -Name 'DhcpNameServer' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($configuredNs)) {
                $isDhcpDns = $false
            }
        }

        $perIfDoh = Get-InterfaceDohRegistrySettings -InterfaceGuid $guid

        $selectedAdapters.Add([pscustomobject]@{
            Name                    = $name
            InterfaceDescription    = [string]$adapter.InterfaceDescription
            InterfaceIndex          = $ifIndex
            InterfaceGuid           = $guid
            Status                  = [string]$adapter.Status
            Virtual                 = [bool]$adapter.Virtual
            MacAddress              = [string]$adapter.MacAddress
            IPv4Addresses           = $ipv4Addrs
            IPv4DnsServers          = $dnsServers
            IsDhcpDns               = $isDhcpDns
            ConfiguredNameServer    = $configuredNs
            DhcpNameServer          = $dhcpNs
            InterfaceMetric         = $ifMetric
            AutomaticMetric         = $autoMetric
            PerInterfaceDohSettings = $perIfDoh
        })
    }

    $dohInfo = Get-DohServersFromCmdletOrNetsh
    $nrptRules = @(Get-DnsClientNrptRule -ErrorAction SilentlyContinue)
    $netshStateLines = @(& netsh dnsclient show state 2>&1 | ForEach-Object { [string]$_ })

    return [pscustomobject]@{
        Timestamp       = (Get-Date).ToString('o')
        ComputerName    = $env:COMPUTERNAME
        IsAdministrator = (Test-IsAdministrator)
        VpnState        = $vpnState
        Adapters        = $selectedAdapters.ToArray()
        DohSource       = $dohInfo.Source
        DohServers      = $dohInfo.Servers
        DohIPv4Count    = @($dohInfo.Servers | Where-Object { $_.AddressFamily -eq 'IPv4' }).Count
        DohIPv6Count    = @($dohInfo.Servers | Where-Object { $_.AddressFamily -eq 'IPv6' }).Count
        NrptRuleCount   = $nrptRules.Count
        DnsClientState  = ($netshStateLines -join "`n").Trim()
    }
}

function Invoke-DnsCacheFlush {
    <#
    .SYNOPSIS
        Flushes the Windows DNS resolver cache using Clear-DnsClientCache with ipconfig /flushdns fallback.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if (-not $PSCmdlet.ShouldProcess('Windows DNS Client Cache', 'Flush DNS cache')) {
        return [pscustomobject]@{
            Success = $true
            Method  = 'WhatIf'
            Message = 'Skipped due to -WhatIf.'
        }
    }

    $clearCmd = Get-Command -Name 'Clear-DnsClientCache' -ErrorAction SilentlyContinue
    if ($null -ne $clearCmd) {
        try {
            Clear-DnsClientCache -ErrorAction Stop
            return [pscustomobject]@{
                Success = $true
                Method  = 'Clear-DnsClientCache'
                Message = 'DNS resolver cache cleared.'
            }
        } catch {
            # Fall back to ipconfig /flushdns below.
        }
    }

    $out = @(& ipconfig.exe /flushdns 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        Success = ($exitCode -eq 0)
        Method  = 'ipconfig /flushdns'
        Message = ($out -join ' ').Trim()
    }
}

Export-ModuleMember -Function @(
    'Get-DnsProfilesConfig',
    'Get-DnsProfileById',
    'Test-IsAdministrator',
    'Invoke-SelfElevation',
    'Get-VpnTunnelState',
    'Get-NetworkDnsSnapshot',
    'Invoke-DnsCacheFlush'
)
