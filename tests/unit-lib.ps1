Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'TestHarness.ps1')

$projectRoot = Split-Path -Parent $PSScriptRoot
$libDir = Join-Path $projectRoot 'lib'
$moduleNames = @('DnsCommon.psm1', 'DnsBackupAndNrpt.psm1', 'DnsProbe.psm1', 'DnsSwitcher.psm1')

$state = New-TestSuiteState -SuiteName 'unit-lib'
Write-Host ("Running {0} on PowerShell {1}..." -f $state.SuiteName, $PSVersionTable.PSVersion.ToString())

$script:ModuleStubBackups = New-Object System.Collections.Generic.List[object]
$script:InitialVpn = $null

function Add-ModuleStub {
    param(
        [Parameter(Mandatory = $true)][string]$ModuleName,
        [Parameter(Mandatory = $true)][string]$FunctionName,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    $mod = Get-Module -Name $ModuleName | Select-Object -First 1
    if ($null -eq $mod) {
        throw "Module '$ModuleName' is not loaded."
    }
    $origSb = & $mod {
        param($fn)
        $item = Get-Item -Path ("Function:" + $fn) -ErrorAction SilentlyContinue
        if ($null -ne $item) { return $item.ScriptBlock }
        return $null
    } $FunctionName

    $script:ModuleStubBackups.Add([pscustomobject]@{
        ModuleName   = $ModuleName
        FunctionName = $FunctionName
        Original     = $origSb
    })

    & $mod {
        param($fn, $sb)
        Set-Item -Path ("Function:script:" + $fn) -Value $sb
    } $FunctionName $Body
}

function Restore-AllModuleStubs {
    for ($i = $script:ModuleStubBackups.Count - 1; $i -ge 0; $i--) {
        $entry = $script:ModuleStubBackups[$i]
        $mod = Get-Module -Name $entry.ModuleName | Select-Object -First 1
        if ($null -ne $mod) {
            if ($null -ne $entry.Original) {
                & $mod {
                    param($fn, $orig)
                    Set-Item -Path ("Function:script:" + $fn) -Value $orig
                } $entry.FunctionName $entry.Original
            } else {
                & $mod {
                    param($fn)
                    Remove-Item -Path ("Function:script:" + $fn) -ErrorAction SilentlyContinue
                } $entry.FunctionName
            }
        }
    }
    $script:ModuleStubBackups.Clear()
}

Invoke-TestCase -State $state -Name 'All 4 lib/*.psm1 modules are pure ASCII, parse cleanly, and export expected functions' {
    foreach ($m in $moduleNames) {
        $p = Join-Path $libDir $m
        Assert-True (Test-Path -LiteralPath $p -PathType Leaf) "Missing module '$p'"
        $asc = Test-FilePureAscii -Path $p
        Assert-True $asc.IsPureAscii "Module '$m' contains non-ASCII byte $($asc.FirstBadByteValue) at offset $($asc.FirstBadByteOffset)"
        $syn = Test-PowerShellSyntax -Path $p
        Assert-True $syn.Valid "Module '$m' has syntax errors: $($syn.Errors -join '; ')"
        Import-Module $p -Force -ErrorAction Stop
    }

    $expectedExports = @(
        'Get-DnsProfilesConfig', 'Get-DnsProfileById', 'Test-IsAdministrator', 'Invoke-SelfElevation',
        'Get-VpnTunnelState', 'Get-NetworkDnsSnapshot', 'Invoke-DnsCacheFlush',
        'Save-DnsStateBackup', 'Get-DnsBackups', 'Get-NrptAudit', 'Clear-StaleNrptRules',
        'Restore-NrptFromBackup', 'Restore-DnsStateBackup',
        'New-DnsWireQuery', 'Read-DnsWireResponse', 'Invoke-DohQuery', 'Test-TlsEndpoint',
        'Test-ProfileHealth', 'Invoke-ProfileBenchmark', 'Get-LiveDnsAvailability',
        'Resolve-TargetAdapters', 'Register-WindowsDohProfile', 'Switch-DnsProfile', 'Reset-DnsToDefault'
    )
    foreach ($fn in $expectedExports) {
        Assert-NotNull (Get-Command -Name $fn -ErrorAction SilentlyContinue) "Expected exported function '$fn' missing"
    }
    $script:InitialVpn = Get-VpnTunnelState
}

Invoke-TestCase -State $state -Name 'New-DnsWireQuery builds valid RFC 1035 query header and question bytes' {
    $pkt = New-DnsWireQuery -Domain 'cloudcode-pa.googleapis.com' -RecordType 1 -TransactionId 0x1234
    Assert-True ($pkt -is [byte[]]) 'Expected byte[] output'
    # Header (12) + 1+12 + 1+10 + 1+3 + 1(root) + QTYPE(2) + QCLASS(2) = 45 bytes
    Assert-Equal 45 $pkt.Length 'Unexpected wire query packet length'

    # Header checks
    Assert-Equal 0x12 $pkt[0]
    Assert-Equal 0x34 $pkt[1]
    Assert-Equal 0x01 $pkt[2]
    Assert-Equal 0x00 $pkt[3]
    Assert-Equal 0x00 $pkt[4]
    Assert-Equal 0x01 $pkt[5]
    Assert-Equal 0x00 $pkt[6]
    Assert-Equal 0x00 $pkt[7]

    # Question labels
    Assert-Equal 12 $pkt[12]
    Assert-Equal 'cloudcode-pa' ([System.Text.Encoding]::ASCII.GetString($pkt, 13, 12))
    Assert-Equal 10 $pkt[25]
    Assert-Equal 'googleapis' ([System.Text.Encoding]::ASCII.GetString($pkt, 26, 10))
    Assert-Equal 3 $pkt[36]
    Assert-Equal 'com' ([System.Text.Encoding]::ASCII.GetString($pkt, 37, 3))
    Assert-Equal 0 $pkt[40]
    # QTYPE=1 (A), QCLASS=1 (IN)
    Assert-Equal 0 $pkt[41]
    Assert-Equal 1 $pkt[42]
    Assert-Equal 0 $pkt[43]
    Assert-Equal 1 $pkt[44]

    # Trailing dot stripped and AAAA QTYPE=28
    $pkt6 = New-DnsWireQuery -Domain 'example.com.' -RecordType 28 -TransactionId 0xABCD
    Assert-Equal 0xAB $pkt6[0]
    Assert-Equal 0xCD $pkt6[1]
    Assert-Equal 28 $pkt6[$pkt6.Length - 3]
}

Invoke-TestCase -State $state -Name 'New-DnsWireQuery rejects empty, oversized, or invalid-label domains' {
    Assert-Throws { New-DnsWireQuery -Domain '   ' } 'empty'
    $longLabel = 'a' * 64 + '.com'
    Assert-Throws { New-DnsWireQuery -Domain $longLabel } 'Invalid DNS label'
    $longDomain = (('a' * 50) + '.') * 5 + 'com'
    Assert-Throws { New-DnsWireQuery -Domain $longDomain } 'exceeds 253'
}

Invoke-TestCase -State $state -Name 'Read-DnsWireResponse parses compressed pointer A record' {
    # Query for example.com (TxID 0x1357)
    $q = New-DnsWireQuery -Domain 'example.com' -RecordType 1 -TransactionId 0x1357
    $resp = New-Object System.Collections.Generic.List[byte]
    $resp.AddRange($q)
    # Set QR=1 (0x81 0x80) and ANCOUNT=1 (0x00 0x01)
    $resp[2] = 0x81
    $resp[3] = 0x80
    $resp[6] = 0x00
    $resp[7] = 0x01
    # Answer: NAME pointer 0xC0 0x0C (offset 12 -> example.com)
    $resp.Add(0xC0); $resp.Add(0x0C)
    # TYPE=A (1), CLASS=IN (1), TTL=300 (0x0000012C), RDLEN=4
    $resp.Add(0x00); $resp.Add(0x01)
    $resp.Add(0x00); $resp.Add(0x01)
    $resp.Add(0x00); $resp.Add(0x00); $resp.Add(0x01); $resp.Add(0x2C)
    $resp.Add(0x00); $resp.Add(0x04)
    # RDATA=93.184.216.34
    $resp.Add(93); $resp.Add(184); $resp.Add(216); $resp.Add(34)

    $parsed = Read-DnsWireResponse -Bytes ([byte[]]$resp.ToArray())
    Assert-True $parsed.Success
    Assert-Equal 0x1357 $parsed.TransactionId
    Assert-Equal 0 $parsed.RCode
    Assert-Equal 'NOERROR' $parsed.RCodeName
    Assert-Equal 1 $parsed.AnswerCount
    Assert-Equal 300 $parsed.MinTtl
    Assert-Equal 1 (@($parsed.ARecords)).Count
    Assert-Equal '93.184.216.34' $parsed.ARecords[0]
    Assert-Equal 'example.com' $parsed.Records[0].Name
}

Invoke-TestCase -State $state -Name 'Read-DnsWireResponse parses CNAME + compressed A + AAAA + TXT records' {
    # Question: www.example.com (starts at offset 12: 3 'www' 7 'example' 3 'com' 0 -> 'example.com' starts at offset 16)
    $q = New-DnsWireQuery -Domain 'www.example.com' -RecordType 1 -TransactionId 0x2222
    $resp = New-Object System.Collections.Generic.List[byte]
    $resp.AddRange($q)
    $resp[2] = 0x81; $resp[3] = 0x80
    $resp[6] = 0x00; $resp[7] = 0x04  # 4 answers: CNAME, A, AAAA, TXT

    # Answer 1: CNAME www.example.com (0xC0 0x0C) -> cdn.example.com (3 'cdn' + 0xC0 0x10)
    $cnameRdataOffset = $resp.Count + 12 # offset where RDATA starts
    $resp.Add(0xC0); $resp.Add(0x0C)
    $resp.Add(0x00); $resp.Add(0x05) # TYPE=CNAME
    $resp.Add(0x00); $resp.Add(0x01) # CLASS=IN
    $resp.Add(0x00); $resp.Add(0x00); $resp.Add(0x00); $resp.Add(120) # TTL=120
    $resp.Add(0x00); $resp.Add(0x06) # RDLEN=6
    $resp.Add(0x03); $resp.AddRange([System.Text.Encoding]::ASCII.GetBytes('cdn'))
    $resp.Add(0xC0); $resp.Add(0x10) # pointer to example.com at offset 16

    # Answer 2: A record for cdn.example.com (pointer to $cnameRdataOffset) -> 1.2.3.4, TTL=60
    $resp.Add([byte](0xC0 -bor (($cnameRdataOffset -shr 8) -band 0x3F)))
    $resp.Add([byte]($cnameRdataOffset -band 0xFF))
    $resp.Add(0x00); $resp.Add(0x01) # TYPE=A
    $resp.Add(0x00); $resp.Add(0x01)
    $resp.Add(0x00); $resp.Add(0x00); $resp.Add(0x00); $resp.Add(60) # TTL=60
    $resp.Add(0x00); $resp.Add(0x04)
    $resp.Add(1); $resp.Add(2); $resp.Add(3); $resp.Add(4)

    # Answer 3: AAAA record -> 2001:db8::1, TTL=90
    $resp.Add(0xC0); $resp.Add(0x0C)
    $resp.Add(0x00); $resp.Add(0x1C) # TYPE=28 (AAAA)
    $resp.Add(0x00); $resp.Add(0x01)
    $resp.Add(0x00); $resp.Add(0x00); $resp.Add(0x00); $resp.Add(90)
    $resp.Add(0x00); $resp.Add(0x10) # RDLEN=16
    $aaaaBytes = ([System.Net.IPAddress]::Parse('2001:db8::1')).GetAddressBytes()
    $resp.AddRange($aaaaBytes)

    # Answer 4: TXT record -> "v=test", TTL=180
    $txtBytes = [System.Text.Encoding]::ASCII.GetBytes('v=test')
    $resp.Add(0xC0); $resp.Add(0x0C)
    $resp.Add(0x00); $resp.Add(0x10) # TYPE=16 (TXT)
    $resp.Add(0x00); $resp.Add(0x01)
    $resp.Add(0x00); $resp.Add(0x00); $resp.Add(0x00); $resp.Add(180)
    $resp.Add(0x00); $resp.Add([byte]($txtBytes.Length + 1))
    $resp.Add([byte]$txtBytes.Length)
    $resp.AddRange($txtBytes)

    $parsed = Read-DnsWireResponse -Bytes ([byte[]]$resp.ToArray())
    Assert-True $parsed.Success
    Assert-Equal 60 $parsed.MinTtl 'MinTtl should be 60'
    Assert-Contains $parsed.CNames 'cdn.example.com'
    Assert-Contains $parsed.ARecords '1.2.3.4'
    Assert-Contains $parsed.AAAARecords '2001:db8::1'
    $txtRec = $parsed.Records | Where-Object { $_.TypeName -eq 'TXT' } | Select-Object -First 1
    Assert-NotNull $txtRec
    Assert-Equal 'v=test' $txtRec.Value
}

Invoke-TestCase -State $state -Name 'Read-DnsWireResponse handles non-zero RCODEs and rejects malformed/truncated/looped packets' {
    # NXDOMAIN (RCODE=3)
    $qNx = New-DnsWireQuery -Domain 'missing.example.com' -RecordType 1 -TransactionId 0x0001
    $qNx[2] = 0x81
    $qNx[3] = 0x83 # RCODE=3
    $nx = Read-DnsWireResponse -Bytes $qNx
    Assert-False $nx.Success
    Assert-Equal 3 $nx.RCode
    Assert-Equal 'NXDOMAIN' $nx.RCodeName

    # SERVFAIL (RCODE=2)
    $qSf = New-DnsWireQuery -Domain 'fail.example.com' -RecordType 1 -TransactionId 0x0002
    $qSf[2] = 0x81
    $qSf[3] = 0x82 # RCODE=2
    $sf = Read-DnsWireResponse -Bytes $qSf
    Assert-False $sf.Success
    Assert-Equal 2 $sf.RCode
    Assert-Equal 'SERVFAIL' $sf.RCodeName

    # Too short (<12 bytes)
    Assert-Throws { Read-DnsWireResponse -Bytes ([byte[]]@(1, 2, 3, 4, 5)) } 'too short'

    # Truncated question
    $qTrunc = New-DnsWireQuery -Domain 'example.com' -RecordType 1 -TransactionId 10
    $shortQ = [byte[]]($qTrunc[0..18])
    Assert-Throws { Read-DnsWireResponse -Bytes $shortQ } 'Truncated'

    # Truncated answer RDATA
    $badAns = New-Object System.Collections.Generic.List[byte]
    $badAns.AddRange((New-DnsWireQuery -Domain 'example.com' -RecordType 1 -TransactionId 11))
    $badAns[2] = 0x81; $badAns[6] = 0x00; $badAns[7] = 0x01
    $badAns.Add(0xC0); $badAns.Add(0x0C)
    $badAns.Add(0x00); $badAns.Add(0x01)
    $badAns.Add(0x00); $badAns.Add(0x01)
    $badAns.Add(0x00); $badAns.Add(0x00); $badAns.Add(0x00); $badAns.Add(60)
    $badAns.Add(0x00); $badAns.Add(0x04)
    $badAns.Add(1) # Only 1 byte of 4-byte RDATA
    Assert-Throws { Read-DnsWireResponse -Bytes ([byte[]]$badAns.ToArray()) } 'Truncated DNS answer RDATA'

    # Out-of-bounds compression pointer
    $oob = [byte[]]@(0, 1, 0x81, 0x80, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 0xFF, 0, 1, 0, 1)
    Assert-Throws { Read-DnsWireResponse -Bytes $oob } 'Out-of-bounds'

    # Self-referential compression loop at offset 12 (0xC0 0x0C)
    $loopPkt = [byte[]]@(0, 1, 0x81, 0x80, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 0x0C, 0, 1, 0, 1)
    Assert-Throws { Read-DnsWireResponse -Bytes $loopPkt } 'maximum DNS compression pointer hops'
}

Invoke-TestCase -State $state -Name 'DnsCommon: Get-DnsProfilesConfig, Get-DnsProfileById, Test-IsAdministrator' {
    $cfg = Get-DnsProfilesConfig
    Assert-Equal 12 (@($cfg.profiles)).Count
    Assert-GreaterThan (@($cfg.deprecated_or_blocked)).Count 10

    $cf = Get-DnsProfileById -Id 'CloudFlare'
    Assert-Equal 'cloudflare' ([string]$cf.id)
    Assert-Equal 'https://cloudflare-dns.com/dns-query' ([string]$cf.doh_template)

    Assert-Throws { Get-DnsProfileById -Id 'does-not-exist-xyz' } 'Unknown DNS profile'
    Assert-Throws { Get-DnsProfilesConfig -ConfigPath (Join-Path $env:TEMP 'missing-profiles-xyz.json') } 'not found'

    $badJsonPath = Join-Path $env:TEMP ("bad_profiles_" + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        [System.IO.File]::WriteAllText($badJsonPath, '{ not valid json', [System.Text.Encoding]::UTF8)
        Assert-Throws { Get-DnsProfilesConfig -ConfigPath $badJsonPath } 'Failed to parse JSON'
    } finally {
        if (Test-Path -LiteralPath $badJsonPath) { Remove-Item -LiteralPath $badJsonPath -Force -ErrorAction SilentlyContinue }
    }

    $isAdmin = Test-IsAdministrator
    Assert-True ($isAdmin -is [bool])
}

Invoke-TestCase -State $state -Name 'DnsCommon: Get-VpnTunnelState and Get-NetworkDnsSnapshot are state-agnostic and read-only' {
    $vpn = Get-VpnTunnelState
    Assert-True ($vpn.AdapterPresent -is [bool]) 'Expected AdapterPresent to be bool'
    Assert-True ($vpn.IsActive -is [bool]) 'Expected IsActive to be bool'
    Assert-True ($vpn.HijackDnsExpected -is [bool]) 'Expected HijackDnsExpected to be bool'
    Assert-True ($vpn.IPv4RouteCount -ge 0) 'Expected non-negative IPv4RouteCount'
    Assert-NotNull $vpn.PSObject.Properties['DetectedAdapters']
    Assert-NotNull $vpn.PSObject.Properties['RasConnections']
    if ($vpn.IsActive) {
        $hasAdaptersOrRas = ((@($vpn.DetectedAdapters)).Count -gt 0) -or ((@($vpn.RasConnections)).Count -gt 0)
        Assert-True $hasAdaptersOrRas 'Active VPN must report at least one DetectedAdapter or RasConnection'
        if ($vpn.AdapterPresent) {
            Assert-False ([string]::IsNullOrWhiteSpace([string]$vpn.AdapterName)) 'AdapterName must be populated when AdapterPresent=$true'
            Assert-Equal 'Up' ([string]$vpn.AdapterStatus)
        }
    } else {
        Assert-True (([string]$vpn.AdapterStatus) -ne 'Up') 'Inactive VPN must not report AdapterStatus=Up'
        if (-not $vpn.AdapterPresent) {
            Assert-Equal $null $vpn.AdapterName 'Expected AdapterName=$null when no VPN adapter is present'
            Assert-Equal 'Absent' ([string]$vpn.AdapterStatus)
        }
    }

    $snap = Get-NetworkDnsSnapshot
    Assert-NotNull $snap.Timestamp
    Assert-True ($snap.IsAdministrator -is [bool])
    Assert-NotNull $snap.VpnState
    Assert-Equal ([bool]$vpn.IsActive) ([bool]$snap.VpnState.IsActive)
    Assert-GreaterThan (@($snap.Adapters)).Count 0 'Expected at least 1 adapter in snapshot'
    if ($vpn.IsActive -and $vpn.AdapterPresent -and -not [string]::IsNullOrWhiteSpace([string]$vpn.AdapterName)) {
        $vpnAdapter = @($snap.Adapters) | Where-Object { $_.Name -eq $vpn.AdapterName } | Select-Object -First 1
        Assert-NotNull $vpnAdapter "VPN adapter '$($vpn.AdapterName)' missing from Get-NetworkDnsSnapshot when active"
    }
    Assert-NotNull $snap.DohServers
    Assert-True ($snap.NrptRuleCount -ge 0)
}

Invoke-TestCase -State $state -Name 'DnsCommon: Get-VpnTunnelState detects mocked WireGuard/TUN, RAS VPN, and no-VPN states cleanly' {
    try {
        # (a) Active generic WireGuard/TUN adapter
        Add-ModuleStub -ModuleName 'DnsCommon' -FunctionName 'Get-VpnConnection' -Body { return @() }
        Add-ModuleStub -ModuleName 'DnsCommon' -FunctionName 'Get-NetAdapter' -Body {
            return @(
                [pscustomobject]@{
                    Name = 'Ethernet'; InterfaceDescription = 'Realtek PCIe GbE'; Status = 'Up'; Virtual = $false
                    ifIndex = 10; InterfaceGuid = '{10000000-0000-0000-0000-000000000010}'
                },
                [pscustomobject]@{
                    Name = 'vEthernet (Default Switch)'; InterfaceDescription = 'Hyper-V Virtual Ethernet Adapter'; Status = 'Up'; Virtual = $true
                    ifIndex = 50; InterfaceGuid = '{50000000-0000-0000-0000-000000000050}'
                },
                [pscustomobject]@{
                    Name = 'wg0'; InterfaceDescription = 'WireGuard Tunnel'; Status = 'Up'; Virtual = $true
                    ifIndex = 99; InterfaceGuid = '{99000000-0000-0000-0000-000000000099}'
                }
            )
        }
        Add-ModuleStub -ModuleName 'DnsCommon' -FunctionName 'Get-NetIPAddress' -Body {
            param([int]$InterfaceIndex, [string]$AddressFamily)
            if ($InterfaceIndex -eq 99) {
                return @([pscustomobject]@{ IPAddress = '10.8.0.2'; PrefixLength = 24 })
            }
            return @([pscustomobject]@{ IPAddress = '192.168.1.50'; PrefixLength = 24 })
        }
        Add-ModuleStub -ModuleName 'DnsCommon' -FunctionName 'Get-DnsClientServerAddress' -Body {
            param([int]$InterfaceIndex, [string]$AddressFamily)
            if ($InterfaceIndex -eq 99) {
                return [pscustomobject]@{ ServerAddresses = @('10.8.0.1') }
            }
            return [pscustomobject]@{ ServerAddresses = @('192.168.1.1') }
        }
        Add-ModuleStub -ModuleName 'DnsCommon' -FunctionName 'Get-NetIPInterface' -Body {
            param([int]$InterfaceIndex, [string]$AddressFamily)
            return [pscustomobject]@{ InterfaceMetric = 5; AutomaticMetric = 'Disabled' }
        }
        Add-ModuleStub -ModuleName 'DnsCommon' -FunctionName 'Get-NetRoute' -Body {
            param([int]$InterfaceIndex, [string]$AddressFamily)
            if ($InterfaceIndex -eq 99) {
                return @(
                    [pscustomobject]@{ DestinationPrefix = '0.0.0.0/1' },
                    [pscustomobject]@{ DestinationPrefix = '128.0.0.0/1' }
                )
            }
            return @([pscustomobject]@{ DestinationPrefix = '0.0.0.0/0' })
        }

        $wgState = Get-VpnTunnelState
        Assert-True $wgState.IsActive 'WireGuard/TUN mock should report IsActive=$true'
        Assert-True $wgState.AdapterPresent 'WireGuard/TUN mock should report AdapterPresent=$true'
        Assert-Equal 'wg0' ([string]$wgState.AdapterName)
        Assert-Equal 'Up' ([string]$wgState.AdapterStatus)
        Assert-Equal 99 ([int]$wgState.InterfaceIndex)
        Assert-Equal 2 ([int]$wgState.IPv4RouteCount)
        Assert-Equal 1 (@($wgState.DetectedAdapters)).Count
        Assert-Equal 0 (@($wgState.RasConnections)).Count

        # (b) Active Windows RAS VPN (Get-VpnConnection)
        Add-ModuleStub -ModuleName 'DnsCommon' -FunctionName 'Get-VpnConnection' -Body {
            return @(
                [pscustomobject]@{
                    Name = 'CorpIKEv2'; ConnectionStatus = 'Connected'; TunnelType = 'Ikev2'; SplitTunneling = $false
                }
            )
        }
        Add-ModuleStub -ModuleName 'DnsCommon' -FunctionName 'Get-NetAdapter' -Body {
            return @(
                [pscustomobject]@{
                    Name = 'Ethernet'; InterfaceDescription = 'Realtek PCIe GbE'; Status = 'Up'; Virtual = $false
                    ifIndex = 10; InterfaceGuid = '{10000000-0000-0000-0000-000000000010}'
                },
                [pscustomobject]@{
                    Name = 'CorpIKEv2'; InterfaceDescription = 'WAN Miniport (IKEv2)'; Status = 'Up'; Virtual = $true
                    ifIndex = 77; InterfaceGuid = '{77000000-0000-0000-0000-000000000077}'
                }
            )
        }
        $rasState = Get-VpnTunnelState
        Assert-True $rasState.IsActive 'RAS VPN mock should report IsActive=$true'
        Assert-True $rasState.AdapterPresent 'RAS VPN mock should report AdapterPresent=$true'
        Assert-Equal 'CorpIKEv2' ([string]$rasState.AdapterName)
        Assert-Equal 1 (@($rasState.RasConnections)).Count
        Assert-Equal 'CorpIKEv2' ([string]$rasState.RasConnections[0].Name)
        Assert-Equal 'Ikev2' ([string]$rasState.RasConnections[0].TunnelType)

        # (c) No VPN installed or active
        Add-ModuleStub -ModuleName 'DnsCommon' -FunctionName 'Get-VpnConnection' -Body { return @() }
        Add-ModuleStub -ModuleName 'DnsCommon' -FunctionName 'Get-NetAdapter' -Body {
            return @(
                [pscustomobject]@{
                    Name = 'Ethernet'; InterfaceDescription = 'Realtek PCIe GbE'; Status = 'Up'; Virtual = $false
                    ifIndex = 10; InterfaceGuid = '{10000000-0000-0000-0000-000000000010}'
                },
                [pscustomobject]@{
                    Name = 'vEthernet (WSL)'; InterfaceDescription = 'Hyper-V Virtual Ethernet Adapter'; Status = 'Up'; Virtual = $true
                    ifIndex = 51; InterfaceGuid = '{51000000-0000-0000-0000-000000000051}'
                },
                [pscustomobject]@{
                    Name = 'WAN Miniport (IKEv2)'; InterfaceDescription = 'WAN Miniport (IKEv2)'; Status = 'Disconnected'; Virtual = $true
                    ifIndex = 52; InterfaceGuid = '{52000000-0000-0000-0000-000000000052}'
                }
            )
        }
        $noVpn = Get-VpnTunnelState
        Assert-False $noVpn.IsActive 'No-VPN mock should report IsActive=$false'
        Assert-False $noVpn.AdapterPresent 'No-VPN mock should report AdapterPresent=$false'
        Assert-Equal $null $noVpn.AdapterName 'No-VPN mock should report AdapterName=$null'
        Assert-Equal 'Absent' ([string]$noVpn.AdapterStatus)
        Assert-Equal 0 (@($noVpn.DetectedAdapters)).Count
        Assert-Equal 0 (@($noVpn.RasConnections)).Count
        Assert-False $noVpn.HijackDnsExpected
    } finally {
        Restore-AllModuleStubs
    }
}

Invoke-TestCase -State $state -Name 'DnsBackupAndNrpt: Get-NrptAudit handles live NRPT state and detects 127.0.0.53, 111.88.96.54, and Google overrides' {
    $liveAudit = Get-NrptAudit
    Assert-True ($liveAudit.TotalRules -ge 0)
    Assert-True ($liveAudit.FlaggedCount -ge 0)
    Assert-True ($liveAudit.DeadLocalCount -ge 0)
    Assert-True ($liveAudit.XboxDnsCount -ge 0)
    Assert-Contains $liveAudit.DeprecatedIpsChecked '127.0.0.53'
    Assert-Contains $liveAudit.DeprecatedIpsChecked '111.88.96.54'

    # Deterministic synthetic unit test using stubbed Get-CombinedNrptRules
    try {
        Add-ModuleStub -ModuleName 'DnsBackupAndNrpt' -FunctionName 'Get-CombinedNrptRules' -Body {
            return @(
                [pscustomobject]@{
                    Name = '{11111111-1111-1111-1111-111111111111}'
                    Namespace = @('cloudcode-pa.googleapis.com')
                    NameServers = @('127.0.0.53')
                    DisplayName = 'Legacy AI Unblocker Dead Local'
                    Comment = 'AI_UNBLOCK_RULE'
                },
                [pscustomobject]@{
                    Name = '{22222222-2222-2222-2222-222222222222}'
                    Namespace = @('gemini.google.com')
                    NameServers = @('111.88.96.54', '111.88.96.55')
                    DisplayName = 'Xbox Rule'
                    Comment = ''
                },
                [pscustomobject]@{
                    Name = '{33333333-3333-3333-3333-333333333333}'
                    Namespace = @('corp.internal.local')
                    NameServers = @('10.0.0.10')
                    DisplayName = 'Corp Internal'
                    Comment = ''
                }
            )
        }

        $synAudit = Get-NrptAudit
        Assert-Equal 3 $synAudit.TotalRules
        Assert-Equal 2 $synAudit.FlaggedCount
        Assert-Equal 1 $synAudit.CleanCount
        Assert-Equal 1 $synAudit.DeadLocalCount
        Assert-Equal 1 $synAudit.XboxDnsCount
        Assert-Equal 2 $synAudit.GoogleOverrideCount

        $r1 = $synAudit.Rules | Where-Object { $_.Name -eq '{11111111-1111-1111-1111-111111111111}' } | Select-Object -First 1
        Assert-True $r1.IsFlagged
        Assert-True $r1.HasDeadLocalForwarder
        Assert-True $r1.OverridesAntigravityGoogle
        Assert-True $r1.IsLegacyUnblockerRule

        $r2 = $synAudit.Rules | Where-Object { $_.Name -eq '{22222222-2222-2222-2222-222222222222}' } | Select-Object -First 1
        Assert-True $r2.IsFlagged
        Assert-True $r2.HasXboxDns
        Assert-True $r2.OverridesAntigravityGoogle
        Assert-False $r2.IsLegacyUnblockerRule

        $r3 = $synAudit.Rules | Where-Object { $_.Name -eq '{33333333-3333-3333-3333-333333333333}' } | Select-Object -First 1
        Assert-False $r3.IsFlagged
        Assert-False $r3.IsLegacyUnblockerRule
    } finally {
        Restore-AllModuleStubs
    }
}

Invoke-TestCase -State $state -Name 'DnsBackupAndNrpt: Save-DnsStateBackup, Get-DnsBackups, Clear-StaleNrptRules/Restore DryRun in isolated temp dir' {
    $tempBackupDir = Join-Path $env:TEMP ('dns_switcher_test_' + [Guid]::NewGuid().ToString('N'))
    try {
        $b1 = Save-DnsStateBackup -BackupDir $tempBackupDir -Label 'unit test 1!'
        Start-Sleep -Milliseconds 50
        $b2 = Save-DnsStateBackup -BackupDir $tempBackupDir -Label 'unit-test-2'

        Assert-True (Test-Path -LiteralPath $b1.BackupPath -PathType Leaf)
        Assert-True (Test-Path -LiteralPath $b2.BackupPath -PathType Leaf)
        Assert-Equal 'unit-test-1' $b1.Label
        Assert-GreaterThan $b1.AdapterCount 0

        # Ensure no leftover .tmp.* files from atomic write
        $tmpFiles = @(Get-ChildItem -LiteralPath $tempBackupDir -Filter '*.tmp.*' -ErrorAction SilentlyContinue)
        Assert-Equal 0 $tmpFiles.Count 'Atomic backup left temporary files behind'

        # Corrupt file should be reported cleanly with IsValid=$false
        $corruptPath = Join-Path $tempBackupDir 'corrupt-test.json'
        [System.IO.File]::WriteAllText($corruptPath, '{ broken json', [System.Text.Encoding]::UTF8)

        $list = @(Get-DnsBackups -BackupDir $tempBackupDir)
        Assert-Equal 3 $list.Count
        $validBackups = @($list | Where-Object { $_.IsValid })
        Assert-Equal 2 $validBackups.Count
        Assert-Equal 'unit-test-2' $validBackups[0].Label 'Newest backup should sort first'
        $badItem = $list | Where-Object { $_.FileName -eq 'corrupt-test.json' } | Select-Object -First 1
        Assert-NotNull $badItem
        Assert-False $badItem.IsValid

        $nrptDry = Clear-StaleNrptRules -BackupDir $tempBackupDir -DryRun
        Assert-True $nrptDry.DryRun
        Assert-False $nrptDry.Executed
        Assert-Equal $null $nrptDry.BackupPath
        Assert-True ($nrptDry.TotalBefore -ge 0)
        Assert-True ($nrptDry.TargetCount -ge 0)
        Assert-Equal 0 $nrptDry.RemovedCount
        Assert-Equal $nrptDry.TotalBefore $nrptDry.RemainingTotal
        Assert-Equal $nrptDry.TargetCount $nrptDry.RemainingFlagged
        Assert-Equal $nrptDry.TargetCount (@($nrptDry.PlannedRules)).Count

        $nrptRestDry = Restore-NrptFromBackup -BackupPath $b2.BackupPath -DryRun
        Assert-True $nrptRestDry.DryRun
        Assert-False $nrptRestDry.Executed
        Assert-Equal $b2.NrptRuleCount $nrptRestDry.BackupRuleCount
        Assert-Equal 0 $nrptRestDry.WouldAddCount

        $nrptRestReplaceDry = Restore-NrptFromBackup -BackupPath $b2.BackupPath -ReplaceExisting -DryRun
        Assert-Equal $b2.NrptRuleCount $nrptRestReplaceDry.WouldRemoveCount
        Assert-Equal $b2.NrptRuleCount $nrptRestReplaceDry.WouldAddCount

        $fullRestDry = Restore-DnsStateBackup -BackupPath $b2.BackupPath -DryRun
        Assert-True $fullRestDry.DryRun
        Assert-False $fullRestDry.Executed
        Assert-GreaterThan (@($fullRestDry.AdapterActions)).Count 0
        Assert-True $fullRestDry.NrptPreview.DryRun

        Assert-Throws { Restore-DnsStateBackup -BackupPath (Join-Path $tempBackupDir 'missing.json') -DryRun } 'not found'
    } finally {
        if (Test-Path -LiteralPath $tempBackupDir) {
            Remove-Item -LiteralPath $tempBackupDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Invoke-TestCase -State $state -Name 'DnsBackupAndNrpt: Clear-StaleNrptRules handles empty (TargetCount=0) and mocked flagged (TargetCount>0) cases' {
    $tempBackupDir = Join-Path $env:TEMP ('dns_switcher_nrpt_' + [Guid]::NewGuid().ToString('N'))
    $global:__MockNrptRemoved = $false
    try {
        Add-ModuleStub -ModuleName 'DnsBackupAndNrpt' -FunctionName 'Test-IsAdministrator' -Body { return $true }
        Add-ModuleStub -ModuleName 'DnsBackupAndNrpt' -FunctionName 'Invoke-DnsCacheFlush' -Body {
            return [pscustomobject]@{ Success = $true; Method = 'Mock'; Message = 'Flushed' }
        }
        Add-ModuleStub -ModuleName 'DnsBackupAndNrpt' -FunctionName 'Remove-DnsClientNrptRule' -Body {
            param([string]$Name, [switch]$Force)
            $global:__MockNrptRemoved = $true
        }

        # Case 1: Empty NRPT (TargetCount == 0)
        Add-ModuleStub -ModuleName 'DnsBackupAndNrpt' -FunctionName 'Get-CombinedNrptRules' -Body { return @() }
        $emptyDry = Clear-StaleNrptRules -BackupDir $tempBackupDir -DryRun
        Assert-True $emptyDry.DryRun
        Assert-False $emptyDry.Executed
        Assert-Equal 0 $emptyDry.TotalBefore
        Assert-Equal 0 $emptyDry.TargetCount
        Assert-Equal 0 $emptyDry.RemovedCount
        Assert-Equal 0 $emptyDry.RemainingTotal
        Assert-Equal 0 $emptyDry.RemainingFlagged

        $emptyReal = Clear-StaleNrptRules -BackupDir $tempBackupDir -Confirm:$false
        Assert-False $emptyReal.DryRun
        Assert-False $emptyReal.Executed
        Assert-Equal 0 $emptyReal.TotalBefore
        Assert-Equal 0 $emptyReal.TargetCount
        Assert-Equal 0 $emptyReal.RemovedCount
        Assert-Equal 0 $emptyReal.RemainingTotal
        Assert-Equal 0 $emptyReal.RemainingFlagged
        Assert-Equal $null $emptyReal.BackupPath

        # Case 2: Mocked flagged NRPT rule (TargetCount > 0)
        $global:__MockNrptRemoved = $false
        Add-ModuleStub -ModuleName 'DnsBackupAndNrpt' -FunctionName 'Get-CombinedNrptRules' -Body {
            if ($global:__MockNrptRemoved) {
                return @()
            }
            return @(
                [pscustomobject]@{
                    Name        = '{aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa}'
                    Namespace   = @('cloudcode-pa.googleapis.com')
                    NameServers = @('127.0.0.53')
                    DisplayName = 'Mock Stale Rule'
                    Comment     = ''
                }
            )
        }
        $flaggedDry = Clear-StaleNrptRules -BackupDir $tempBackupDir -DryRun
        Assert-True $flaggedDry.DryRun
        Assert-False $flaggedDry.Executed
        Assert-Equal 1 $flaggedDry.TotalBefore
        Assert-Equal 1 $flaggedDry.TargetCount
        Assert-Equal 0 $flaggedDry.RemovedCount
        Assert-Equal 1 $flaggedDry.RemainingTotal
        Assert-Equal 1 $flaggedDry.RemainingFlagged

        $flaggedReal = Clear-StaleNrptRules -BackupDir $tempBackupDir -Confirm:$false
        Assert-False $flaggedReal.DryRun
        Assert-True $flaggedReal.Executed
        Assert-Equal 1 $flaggedReal.TotalBefore
        Assert-Equal 1 $flaggedReal.TargetCount
        Assert-Equal 1 $flaggedReal.RemovedCount
        Assert-Equal 0 $flaggedReal.RemainingTotal
        Assert-Equal 0 $flaggedReal.RemainingFlagged
        Assert-True (Test-Path -LiteralPath $flaggedReal.BackupPath -PathType Leaf)
    } finally {
        Restore-AllModuleStubs
        Remove-Variable -Name '__MockNrptRemoved' -Scope Global -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $tempBackupDir) {
            Remove-Item -LiteralPath $tempBackupDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Invoke-TestCase -State $state -Name 'DnsSwitcher: Resolve-TargetAdapters and DryRun paths across categories with zero mutations' {
    $autoRes = Resolve-TargetAdapters -TargetMode 'auto'
    Assert-Equal ([bool]$script:InitialVpn.IsActive) ([bool]$autoRes.VpnActive)
    Assert-NotNull $autoRes.VpnState
    Assert-GreaterThan (@($autoRes.Adapters)).Count 0
    $autoNames = @($autoRes.Adapters | ForEach-Object { $_.Name })
    if ($script:InitialVpn.IsActive -and $script:InitialVpn.AdapterPresent -and -not [string]::IsNullOrWhiteSpace([string]$script:InitialVpn.AdapterName)) {
        Assert-Contains $autoNames ([string]$script:InitialVpn.AdapterName)
        $vpnRes = Resolve-TargetAdapters -TargetMode 'vpn'
        Assert-GreaterThan (@($vpnRes.Adapters)).Count 0
        Assert-Contains @($vpnRes.Adapters | ForEach-Object { $_.Name }) ([string]$script:InitialVpn.AdapterName)
    } elseif (-not $script:InitialVpn.IsActive) {
        Assert-Throws { Resolve-TargetAdapters -TargetMode 'vpn' } '(No active VPN|cannot target)'
    }

    $ethRes = Resolve-TargetAdapters -TargetMode 'ethernet'
    Assert-Equal 1 (@($ethRes.Adapters)).Count

    $bothRes = Resolve-TargetAdapters -TargetMode 'both'
    if ($script:InitialVpn.IsActive -and $script:InitialVpn.AdapterPresent) {
        Assert-GreaterThan (@($bothRes.Adapters)).Count 1
    } else {
        Assert-GreaterThan (@($bothRes.Adapters)).Count 0
    }

    $customTargetName = [string]$autoRes.Adapters[0].Name
    $custRes = Resolve-TargetAdapters -TargetMode 'custom' -AdapterNames @($customTargetName)
    Assert-Equal $customTargetName $custRes.Adapters[0].Name

    Assert-Throws { Resolve-TargetAdapters -TargetMode 'custom' -AdapterNames @() } 'requires at least one'
    Assert-Throws { Resolve-TargetAdapters -TargetMode 'custom' -AdapterNames @('NoSuchAdapterXYZ') } 'not found'

    # Trap stubs verify -DryRun NEVER invokes mutating or VPN-disrupting commands
    $global:__DryRunTrapsHit = New-Object System.Collections.Generic.List[string]
    $trappedCmds = @(
        'Set-DnsClientServerAddress', 'Add-DnsClientDohServerAddress', 'Set-DnsClientDohServerAddress',
        'Remove-DnsClientDohServerAddress', 'Remove-DnsClientNrptRule', 'Add-DnsClientNrptRule',
        'Clear-DnsClientCache', 'Stop-Service', 'Restart-Service', 'Disable-NetAdapter',
        'Restart-NetAdapter', 'Remove-NetRoute'
    )
    try {
        foreach ($modName in @('DnsSwitcher', 'DnsBackupAndNrpt', 'DnsCommon')) {
            foreach ($cmd in $trappedCmds) {
                $trapSb = [scriptblock]::Create("param() `$global:__DryRunTrapsHit.Add('$modName::$cmd'); throw 'Unexpected mutation call $modName::$cmd during DryRun'")
                Add-ModuleStub -ModuleName $modName -FunctionName $cmd -Body $trapSb
            }
        }

        $dohDry = Register-WindowsDohProfile -Profile 'cloudflare' -DryRun
        Assert-Equal 2 (@($dohDry)).Count
        Assert-Equal 'DryRun' $dohDry[0].Method
        Assert-False $dohDry[0].Executed

        # Test all 3 categories in Switch-DnsProfile -DryRun
        $swVpnClean = Switch-DnsProfile -Profile 'cloudflare' -CleanNrpt -DryRun
        Assert-True $swVpnClean.Success
        Assert-True $swVpnClean.DryRun
        Assert-False $swVpnClean.Applied
        Assert-Equal 'vpn-clean' $swVpnClean.Category
        Assert-True $swVpnClean.PreflightPassed
        Assert-Equal $null $swVpnClean.BackupPath
        Assert-NotNull $swVpnClean.PlannedNrptCleanup
        Assert-True $swVpnClean.PlannedNrptCleanup.DryRun

        $swRfSmart = Switch-DnsProfile -Profile 'geohide' -SkipPreflight -DryRun
        Assert-True $swRfSmart.Success
        Assert-True $swRfSmart.DryRun
        Assert-Equal 'rf-smart' $swRfSmart.Category
        Assert-True $swRfSmart.AllowFallbackToUdp

        $swRfClean = Switch-DnsProfile -Profile 'yandex' -SkipPreflight -DryRun
        Assert-True $swRfClean.Success
        Assert-True $swRfClean.DryRun
        Assert-Equal 'rf-clean' $swRfClean.Category

        Assert-Throws { Switch-DnsProfile -Profile 'nonexistent-profile' -DryRun } 'Unknown DNS profile'

        $resetDry = Reset-DnsToDefault -TargetMode 'both' -DryRun
        Assert-True $resetDry.Success
        Assert-True $resetDry.DryRun
        Assert-False $resetDry.Applied
        if ($script:InitialVpn.IsActive -and $script:InitialVpn.AdapterPresent) {
            $vpnPlan = $resetDry.PlannedActions | Where-Object { $_.AdapterType -eq 'VpnTunnel' } | Select-Object -First 1
            Assert-NotNull $vpnPlan
            Assert-Equal 'ResetToDhcp' $vpnPlan.Action
            Assert-Equal 0 (@($vpnPlan.TargetDns)).Count
        }
        $physPlan = $resetDry.PlannedActions | Where-Object { $_.AdapterType -eq 'Physical' } | Select-Object -First 1
        Assert-NotNull $physPlan
        Assert-Equal 'ResetToDhcp' $physPlan.Action

        Assert-Equal 0 $global:__DryRunTrapsHit.Count "DryRun triggered trapped calls: $($global:__DryRunTrapsHit -join ', ')"
    } finally {
        Restore-AllModuleStubs
        Remove-Variable -Name '__DryRunTrapsHit' -Scope Global -ErrorAction SilentlyContinue
    }
}

Invoke-TestCase -State $state -Name 'DnsSwitcher: Mocked Resolve-TargetAdapters (auto) and Reset-DnsToDefault handle active-VPN and no-VPN states' {
    $tempBackupDir = Join-Path $env:TEMP ('dns_switcher_vpn_mock_' + [Guid]::NewGuid().ToString('N'))
    $global:__MockVpnResetCalls = New-Object System.Collections.Generic.List[string]
    try {
        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Test-IsAdministrator' -Body { return $true }
        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Get-DnsClientServerAddress' -Body {
            param([int]$InterfaceIndex, [string]$AddressFamily)
            if ($InterfaceIndex -eq 88) {
                return [pscustomobject]@{ ServerAddresses = @('1.1.1.1', '1.0.0.1') }
            }
            return [pscustomobject]@{ ServerAddresses = @('192.168.1.1') }
        }
        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Set-DnsClientServerAddress' -Body {
            param([int]$InterfaceIndex, [string[]]$ServerAddresses, [switch]$ResetServerAddresses)
            if ($ResetServerAddresses) {
                $global:__MockVpnResetCalls.Add("ResetToDhcp:$InterfaceIndex")
            } else {
                $global:__MockVpnResetCalls.Add("SetStatic:$InterfaceIndex")
            }
        }
        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Invoke-DnsCacheFlush' -Body {
            return [pscustomobject]@{ Success = $true; Method = 'Mock'; Message = 'Flushed' }
        }
        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Get-NetworkDnsSnapshot' -Body {
            return [pscustomobject]@{ Adapters = @(); DohServers = @() }
        }
        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Get-NetAdapter' -Body {
            return @(
                [pscustomobject]@{
                    Name = 'Ethernet'; InterfaceDescription = 'Intel Gigabit'; Status = 'Up'; Virtual = $false
                    ifIndex = 12; InterfaceGuid = '{12000000-0000-0000-0000-000000000012}'
                },
                [pscustomobject]@{
                    Name = 'sing-tun'; InterfaceDescription = 'sing-box TUN'; Status = 'Up'; Virtual = $true
                    ifIndex = 88; InterfaceGuid = '{88000000-0000-0000-0000-000000000088}'
                }
            )
        }

        # Case 1: Mocked active VPN -> auto selects both VPN + physical, Reset-DnsToDefault resets both to DHCP with VpnPreserved=$true
        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Get-VpnTunnelState' -Body {
            return [pscustomobject]@{
                IsActive             = $true
                AdapterPresent       = $true
                AdapterName          = 'sing-tun'
                InterfaceDescription = 'sing-box TUN'
                AdapterStatus        = 'Up'
                InterfaceIndex       = 88
                InterfaceGuid        = '{88000000-0000-0000-0000-000000000088}'
                IPv4Addresses        = @('172.18.0.1/30')
                DnsServers           = @('1.1.1.1')
                InterfaceMetric      = 5
                AutomaticMetric      = 'Disabled'
                IPv4RouteCount       = 2
                DetectedAdapters     = @(
                    [pscustomobject]@{ Name = 'sing-tun'; InterfaceIndex = 88; IsTunHijackCapable = $true }
                )
                RasConnections       = @()
                HijackDnsExpected    = $true
            }
        }

        $autoVpn = Resolve-TargetAdapters -TargetMode 'auto'
        Assert-True $autoVpn.VpnActive
        Assert-Equal 'sing-tun' ([string]$autoVpn.VpnState.AdapterName)
        Assert-Equal 2 (@($autoVpn.Adapters)).Count
        $autoVpnNames = @($autoVpn.Adapters | ForEach-Object { $_.Name })
        Assert-Contains $autoVpnNames 'sing-tun'
        Assert-Contains $autoVpnNames 'Ethernet'
        Assert-GreaterThan (@($autoVpn.Warnings)).Count 0

        $rstMock = Reset-DnsToDefault -TargetMode 'auto' -BackupDir $tempBackupDir -Confirm:$false
        Assert-True $rstMock.Success
        Assert-True $rstMock.Applied
        Assert-True $rstMock.VpnPreserved
        Assert-Equal 2 (@($rstMock.Actions)).Count
        $vpnAction = $rstMock.Actions | Where-Object { $_.Name -eq 'sing-tun' } | Select-Object -First 1
        $physAction = $rstMock.Actions | Where-Object { $_.Name -eq 'Ethernet' } | Select-Object -First 1
        Assert-NotNull $vpnAction
        Assert-NotNull $physAction
        Assert-Equal 'VpnTunnel' ([string]$vpnAction.AdapterType)
        Assert-Equal 'ResetToDhcp' ([string]$vpnAction.Action)
        Assert-Equal 'Physical' ([string]$physAction.AdapterType)
        Assert-Equal 'ResetToDhcp' ([string]$physAction.Action)
        Assert-Contains $global:__MockVpnResetCalls 'ResetToDhcp:88'
        Assert-Contains $global:__MockVpnResetCalls 'ResetToDhcp:12'

        # Case 2: Mocked no-VPN -> auto selects physical NIC ONLY with 0 warnings
        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Get-NetAdapter' -Body {
            return @(
                [pscustomobject]@{
                    Name = 'Ethernet'; InterfaceDescription = 'Intel Gigabit'; Status = 'Up'; Virtual = $false
                    ifIndex = 12; InterfaceGuid = '{12000000-0000-0000-0000-000000000012}'
                }
            )
        }
        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Get-VpnTunnelState' -Body {
            return [pscustomobject]@{
                IsActive             = $false
                AdapterPresent       = $false
                AdapterName          = $null
                InterfaceDescription = $null
                AdapterStatus        = 'Absent'
                InterfaceIndex       = $null
                InterfaceGuid        = $null
                IPv4Addresses        = @()
                DnsServers           = @()
                InterfaceMetric      = $null
                AutomaticMetric      = $null
                IPv4RouteCount       = 0
                DetectedAdapters     = @()
                RasConnections       = @()
                HijackDnsExpected    = $false
            }
        }

        $autoNoVpn = Resolve-TargetAdapters -TargetMode 'auto'
        Assert-False $autoNoVpn.VpnActive
        Assert-Equal 1 (@($autoNoVpn.Adapters)).Count
        Assert-Equal 'Ethernet' ([string]$autoNoVpn.Adapters[0].Name)
        Assert-Equal 0 (@($autoNoVpn.Warnings)).Count 'No-VPN auto target resolution must emit 0 warnings'
    } finally {
        Restore-AllModuleStubs
        Remove-Variable -Name '__MockVpnResetCalls' -Scope Global -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $tempBackupDir) {
            Remove-Item -LiteralPath $tempBackupDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Invoke-TestCase -State $state -Name 'DnsSwitcher: Mocked execution verifies preflight abort, backup, adapter/DoH updates, and zero VPN disruption' {
    $tempBackupDir = Join-Path $env:TEMP ('dns_switcher_mock_' + [Guid]::NewGuid().ToString('N'))
    $global:__MockLog = New-Object System.Collections.Generic.List[string]
    $global:__MockDohSuccess = $false
    $global:__MockIsAdmin = $false

    try {
        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Test-IsAdministrator' -Body { return $global:__MockIsAdmin }
        Add-ModuleStub -ModuleName 'DnsBackupAndNrpt' -FunctionName 'Test-IsAdministrator' -Body { return $global:__MockIsAdmin }

        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Invoke-DohQuery' -Body {
            param([string]$Domain, [string]$DohTemplate, [string]$ServerIp, [int]$RecordType = 1, [int]$TimeoutSec = 5, [string]$Method = 'POST', [switch]$RequireHttp2)
            $global:__MockLog.Add("Invoke-DohQuery:$Domain@$ServerIp")
            if ($global:__MockDohSuccess) {
                return [pscustomobject]@{
                    Success = $true; Domain = $Domain; HttpStatus = 200; HttpVersion = '2.0'; RttMs = 12.5
                    ARecords = @('142.250.1.1'); Error = ''
                }
            }
            return [pscustomobject]@{
                Success = $false; Domain = $Domain; HttpStatus = 0; HttpVersion = ''; RttMs = 5000.0
                ARecords = @(); Error = 'Simulated DoH failure'
            }
        }

        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Get-DnsClientDohServerAddress' -Body {
            param([string]$ServerAddress)
            return $null
        }
        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Add-DnsClientDohServerAddress' -Body {
            param([string]$ServerAddress, [string]$DohTemplate, [bool]$AllowFallbackToUdp, [bool]$AutoUpgrade)
            $global:__MockLog.Add("Add-Doh:$ServerAddress=$DohTemplate")
        }
        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Set-DnsClientDohServerAddress' -Body {
            param([string]$ServerAddress, [string]$DohTemplate, [bool]$AllowFallbackToUdp, [bool]$AutoUpgrade)
            $global:__MockLog.Add("Set-Doh:$ServerAddress=$DohTemplate")
        }
        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Set-DnsClientServerAddress' -Body {
            param([int]$InterfaceIndex, [string[]]$ServerAddresses, [switch]$ResetServerAddresses)
            if ($ResetServerAddresses) {
                $global:__MockLog.Add("Reset-Dns:if=$InterfaceIndex")
            } else {
                $global:__MockLog.Add("Set-Dns:if=$InterfaceIndex=" + ($ServerAddresses -join ','))
            }
        }
        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Invoke-DnsCacheFlush' -Body {
            $global:__MockLog.Add('FlushDns')
            return [pscustomobject]@{ Success = $true; Method = 'Mock'; Message = 'Flushed' }
        }
        Add-ModuleStub -ModuleName 'DnsCommon' -FunctionName 'Invoke-DnsCacheFlush' -Body {
            $global:__MockLog.Add('FlushDnsCommon')
            return [pscustomobject]@{ Success = $true; Method = 'Mock'; Message = 'Flushed' }
        }
        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Get-NetworkDnsSnapshot' -Body {
            $res = Resolve-TargetAdapters -TargetMode 'both'
            $mockAdapters = @($res.Adapters | ForEach-Object {
                [pscustomobject]@{
                    Name = $_.Name
                    InterfaceIndex = $_.InterfaceIndex
                    IPv4DnsServers = @('1.1.1.1', '1.0.0.1')
                }
            })
            return [pscustomobject]@{
                Adapters = $mockAdapters
                DohServers = @(
                    [pscustomobject]@{ ServerAddress = '1.1.1.1'; DohTemplate = 'https://cloudflare-dns.com/dns-query' },
                    [pscustomobject]@{ ServerAddress = '1.0.0.1'; DohTemplate = 'https://cloudflare-dns.com/dns-query' }
                )
            }
        }

        foreach ($danger in @('Stop-Service', 'Restart-Service', 'Disable-NetAdapter', 'Restart-NetAdapter', 'Remove-NetRoute')) {
            $sbDanger = [scriptblock]::Create("param() `$global:__MockLog.Add('FORBIDDEN:$danger'); throw 'Forbidden VPN-disruptive call: $danger'")
            Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName $danger -Body $sbDanger
        }

        # Case A: Non-admin non-DryRun throws before touching anything
        $global:__MockIsAdmin = $false
        Assert-Throws { Switch-DnsProfile -Profile 'cloudflare' -BackupDir $tempBackupDir } 'Administrator'
        Assert-Equal 0 $global:__MockLog.Count 'Non-admin failure must not invoke DoH or mutations'

        # Case B: Admin + failed preflight aborts before backup or mutation
        $global:__MockIsAdmin = $true
        $global:__MockDohSuccess = $false
        Assert-Throws { Switch-DnsProfile -Profile 'cloudflare' -BackupDir $tempBackupDir } 'DoH preflight failed'
        Assert-False (@($global:__MockLog | Where-Object { $_ -like 'Set-Dns:*' -or $_ -like 'Add-Doh:*' }).Count -gt 0) 'Failed preflight must not mutate DNS'
        Assert-False (Test-Path -LiteralPath $tempBackupDir) 'Failed preflight must not create backup'

        # Case C: Admin + passing preflight applies DoH, adapter DNS, backup, flush, zero VPN disruption
        $global:__MockLog.Clear()
        $global:__MockDohSuccess = $true
        $swRes = Switch-DnsProfile -Profile 'cloudflare' -TargetMode 'both' -BackupDir $tempBackupDir -Confirm:$false
        Assert-True $swRes.Success
        Assert-True $swRes.Applied
        Assert-NotNull $swRes.PSObject.Properties['AllowFallbackToUdp'] 'Applied Switch-DnsProfile must expose AllowFallbackToUdp'
        Assert-NotNull $swRes.PSObject.Properties['AutoUpgrade'] 'Applied Switch-DnsProfile must expose AutoUpgrade'
        Assert-False $swRes.AllowFallbackToUdp
        Assert-True $swRes.AutoUpgrade
        Assert-True (Test-Path -LiteralPath $swRes.BackupPath -PathType Leaf)
        Assert-Contains $global:__MockLog 'Add-Doh:1.1.1.1=https://cloudflare-dns.com/dns-query'
        Assert-Contains $global:__MockLog 'Add-Doh:1.0.0.1=https://cloudflare-dns.com/dns-query'
        Assert-Contains $global:__MockLog 'FlushDns'
        $minAdapterWrites = if ($script:InitialVpn.IsActive) { 1 } else { 0 }
        Assert-GreaterThan (@($global:__MockLog | Where-Object { $_ -like 'Set-Dns:*=1.1.1.1,1.0.0.1' })).Count $minAdapterWrites
        Assert-Equal 0 (@($global:__MockLog | Where-Object { $_ -like 'FORBIDDEN:*' })).Count

        # Case D: Admin Reset-DnsToDefault resets adapters to DHCP with VpnPreserved=$true
        $global:__MockLog.Clear()
        $rstRes = Reset-DnsToDefault -TargetMode 'both' -BackupDir $tempBackupDir -Confirm:$false
        Assert-True $rstRes.Success
        Assert-True $rstRes.Applied
        Assert-True $rstRes.VpnPreserved
        Assert-True (Test-Path -LiteralPath $rstRes.BackupPath -PathType Leaf)
        Assert-GreaterThan (@($global:__MockLog | Where-Object { $_ -like 'Reset-Dns:*' })).Count 0
        Assert-Equal 0 (@($global:__MockLog | Where-Object { $_ -like 'FORBIDDEN:*' })).Count
    } finally {
        Restore-AllModuleStubs
        Remove-Variable -Name '__MockLog' -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name '__MockDohSuccess' -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name '__MockIsAdmin' -Scope Global -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $tempBackupDir) {
            Remove-Item -LiteralPath $tempBackupDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Invoke-TestCase -State $state -Name 'Regression: Switch-DnsProfile mocked real + CleanNrpt passes Show-SwitchResult (AST) under StrictMode' {
    $cliPath = Join-Path $projectRoot 'dns-switch.ps1'
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($cliPath, [ref]$tokens, [ref]$parseErrors)
    Assert-Equal 0 (@($parseErrors)).Count 'dns-switch.ps1 AST parse errors'

    $wantedFns = @('Test-ObjectHasProperty', 'Get-SafePropertyValue', 'Show-SwitchResult')
    $fnDefs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and ($wantedFns -contains $n.Name) }, $false))
    Assert-Equal $wantedFns.Count $fnDefs.Count 'Missing Show-SwitchResult helper AST functions in dns-switch.ps1'

    $tempBackupDir = Join-Path $env:TEMP ('dns_switcher_reg_' + [Guid]::NewGuid().ToString('N'))
    $global:__RegCapturedLines = New-Object System.Collections.Generic.List[string]
    $global:__RegNrptRemoved = $false

    try {
        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Test-IsAdministrator' -Body { return $true }
        Add-ModuleStub -ModuleName 'DnsBackupAndNrpt' -FunctionName 'Test-IsAdministrator' -Body { return $true }
        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Invoke-DohQuery' -Body {
            param([string]$Domain, [string]$DohTemplate, [string]$ServerIp, [int]$RecordType = 1, [int]$TimeoutSec = 5, [string]$Method = 'POST', [switch]$RequireHttp2)
            return [pscustomobject]@{
                Success = $true; Domain = $Domain; HttpStatus = 200; HttpVersion = '2.0'; RttMs = 15.0
                ARecords = @('142.250.1.1'); Error = ''
            }
        }
        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Get-DnsClientDohServerAddress' -Body { param([string]$ServerAddress) return $null }
        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Add-DnsClientDohServerAddress' -Body { param([string]$ServerAddress, [string]$DohTemplate, [bool]$AllowFallbackToUdp, [bool]$AutoUpgrade) }
        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Set-DnsClientDohServerAddress' -Body { param([string]$ServerAddress, [string]$DohTemplate, [bool]$AllowFallbackToUdp, [bool]$AutoUpgrade) }
        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Set-DnsClientServerAddress' -Body { param([int]$InterfaceIndex, [string[]]$ServerAddresses, [switch]$ResetServerAddresses) }
        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Invoke-DnsCacheFlush' -Body { return [pscustomobject]@{ Success = $true; Method = 'Mock'; Message = 'Flushed' } }
        Add-ModuleStub -ModuleName 'DnsCommon' -FunctionName 'Invoke-DnsCacheFlush' -Body { return [pscustomobject]@{ Success = $true; Method = 'Mock'; Message = 'Flushed' } }
        Add-ModuleStub -ModuleName 'DnsBackupAndNrpt' -FunctionName 'Invoke-DnsCacheFlush' -Body { return [pscustomobject]@{ Success = $true; Method = 'Mock'; Message = 'Flushed' } }
        Add-ModuleStub -ModuleName 'DnsBackupAndNrpt' -FunctionName 'Remove-DnsClientNrptRule' -Body {
            param([string]$Name, [switch]$Force)
            $global:__RegNrptRemoved = $true
        }
        Add-ModuleStub -ModuleName 'DnsSwitcher' -FunctionName 'Get-NetworkDnsSnapshot' -Body {
            $res = Resolve-TargetAdapters -TargetMode 'auto'
            $mockAdapters = @($res.Adapters | ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; InterfaceIndex = $_.InterfaceIndex; IPv4DnsServers = @('1.1.1.1', '1.0.0.1') }
            })
            return [pscustomobject]@{
                Adapters = $mockAdapters
                DohServers = @(
                    [pscustomobject]@{ ServerAddress = '1.1.1.1'; DohTemplate = 'https://cloudflare-dns.com/dns-query' },
                    [pscustomobject]@{ ServerAddress = '1.0.0.1'; DohTemplate = 'https://cloudflare-dns.com/dns-query' }
                )
            }
        }

        $renderInStrictMode = {
            param($ResultObj, $ProfileObj)
            Set-StrictMode -Version Latest
            function Write-CliHost {
                param([object]$Object = '', [System.ConsoleColor]$ForegroundColor, [switch]$NoNewline)
                $global:__RegCapturedLines.Add([string]$Object)
            }
            foreach ($fnAst in $fnDefs) {
                . ([scriptblock]::Create($fnAst.Extent.Text))
            }
            Show-SwitchResult -Result $ResultObj -ProfileObj $ProfileObj
        }

        $cfProfile = Get-DnsProfileById -Id 'cloudflare'

        # Case 1: -CleanNrpt with TargetCount == 0
        Add-ModuleStub -ModuleName 'DnsBackupAndNrpt' -FunctionName 'Get-CombinedNrptRules' -Body { return @() }
        $swZero = Switch-DnsProfile -Profile $cfProfile -TargetMode 'auto' -CleanNrpt -BackupDir $tempBackupDir -Confirm:$false
        Assert-True $swZero.Applied
        Assert-NotNull $swZero.PSObject.Properties['AllowFallbackToUdp']
        Assert-NotNull $swZero.PSObject.Properties['AutoUpgrade']
        Assert-Equal 0 $swZero.NrptResult.TargetCount
        $global:__RegCapturedLines.Clear()
        & $renderInStrictMode $swZero $cfProfile
        $renderedZero = ($global:__RegCapturedLines.ToArray()) -join "`n"
        Assert-Match 'UdpFallback=False' $renderedZero
        Assert-Match 'AutoUpgrade=True' $renderedZero
        Assert-Match 'no stale or conflicting rules found' $renderedZero

        # Case 2: -CleanNrpt with TargetCount > 0
        $global:__RegNrptRemoved = $false
        Add-ModuleStub -ModuleName 'DnsBackupAndNrpt' -FunctionName 'Get-CombinedNrptRules' -Body {
            if ($global:__RegNrptRemoved) { return @() }
            return @(
                [pscustomobject]@{
                    Name        = '{bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb}'
                    Namespace   = @('cloudcode-pa.googleapis.com')
                    NameServers = @('127.0.0.53')
                    DisplayName = 'Mock Stale NRPT'
                    Comment     = ''
                }
            )
        }
        $swFlagged = Switch-DnsProfile -Profile $cfProfile -TargetMode 'auto' -CleanNrpt -BackupDir $tempBackupDir -Confirm:$false
        Assert-True $swFlagged.Applied
        Assert-NotNull $swFlagged.PSObject.Properties['AllowFallbackToUdp']
        Assert-NotNull $swFlagged.PSObject.Properties['AutoUpgrade']
        Assert-Equal 1 $swFlagged.NrptResult.TargetCount
        Assert-Equal 1 $swFlagged.NrptResult.RemovedCount
        Assert-Equal 0 $swFlagged.NrptResult.RemainingFlagged
        $global:__RegCapturedLines.Clear()
        & $renderInStrictMode $swFlagged $cfProfile
        $renderedFlagged = ($global:__RegCapturedLines.ToArray()) -join "`n"
        Assert-Match 'removed 1/1 flagged rule\(s\), remaining flagged=0' $renderedFlagged

        # Case 3: -WhatIf return passes Show-SwitchResult cleanly under StrictMode
        $swWhatIf = Switch-DnsProfile -Profile $cfProfile -TargetMode 'auto' -BackupDir $tempBackupDir -WhatIf
        Assert-False $swWhatIf.Applied
        Assert-NotNull $swWhatIf.PSObject.Properties['AllowFallbackToUdp']
        Assert-NotNull $swWhatIf.PSObject.Properties['AutoUpgrade']
        $global:__RegCapturedLines.Clear()
        & $renderInStrictMode $swWhatIf $cfProfile
        Assert-Match '\[SKIPPED\]' (($global:__RegCapturedLines.ToArray()) -join "`n")
    } finally {
        Restore-AllModuleStubs
        Remove-Variable -Name '__RegCapturedLines' -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name '__RegNrptRemoved' -Scope Global -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $tempBackupDir) {
            Remove-Item -LiteralPath $tempBackupDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Invoke-TestCase -State $state -Name 'Regression: Test-ProfileHealth handles multi-IP RRset strict-TLS fallback and all-fail' {
    $global:__TlsFailSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $global:__TlsTriedIps = New-Object System.Collections.Generic.List[string]
    try {
        Add-ModuleStub -ModuleName 'DnsProbe' -FunctionName 'Invoke-DohQuery' -Body {
            param([string]$Domain, [string]$DohTemplate, [string]$ServerIp, [int]$RecordType = 1, [int]$TimeoutSec = 5, [string]$Method = 'POST', [switch]$RequireHttp2)
            return [pscustomobject]@{
                Success     = $true
                Domain      = $Domain
                HttpStatus  = 200
                HttpVersion = '2.0'
                RttMs       = 25.0
                ARecords    = @('203.0.113.10', '203.0.113.11', '203.0.113.12')
                CNames      = @()
                Error       = ''
            }
        }
        Add-ModuleStub -ModuleName 'DnsProbe' -FunctionName 'Test-TlsEndpoint' -Body {
            param([string]$Hostname, [string]$IpAddress, [int]$Port = 443, [int]$TimeoutSec = 5)
            $global:__TlsTriedIps.Add($IpAddress)
            if ($global:__TlsFailSet.Contains($IpAddress)) {
                return [pscustomobject]@{
                    Success      = $false
                    Hostname     = $Hostname
                    IpAddress    = $IpAddress
                    Port         = $Port
                    TcpRttMs     = $null
                    TlsRttMs     = $null
                    TotalMs      = 100.0
                    SslProtocol  = ''
                    CertSubject  = ''
                    CertIssuer   = ''
                    CertNotAfter = $null
                    Error        = "Simulated TLS timeout on $IpAddress"
                }
            }
            return [pscustomobject]@{
                Success      = $true
                Hostname     = $Hostname
                IpAddress    = $IpAddress
                Port         = $Port
                TcpRttMs     = 10.0
                TlsRttMs     = 20.0
                TotalMs      = 30.0
                SslProtocol  = 'Tls13'
                CertSubject  = 'CN=*.googleapis.com'
                CertIssuer   = 'CN=WR2'
                CertNotAfter = (Get-Date).AddDays(60).ToString('o')
                Error        = ''
            }
        }

        # Case 1: Earlier IP fails (203.0.113.10), later IP passes (203.0.113.11) -> TlsAllPassed=$true
        [void]$global:__TlsFailSet.Add('203.0.113.10')
        $global:__TlsTriedIps.Clear()
        $resPass = Test-ProfileHealth -Profile 'cloudflare' -Domains @('cloudcode-pa.googleapis.com') -Samples 1 -CheckTls -TimeoutSec 3
        Assert-True $resPass.TlsAllPassed 'Expected TlsAllPassed=$true when fallback IP passes'
        Assert-Equal 'HEALTHY' $resPass.Status
        Assert-Equal 1 (@($resPass.TlsResults)).Count
        Assert-True $resPass.TlsResults[0].Success
        Assert-Equal '203.0.113.11' $resPass.TlsResults[0].IpAddress
        Assert-Equal 1 $resPass.TlsResults[0].FailedAttemptCount
        Assert-Equal '203.0.113.10,203.0.113.11,203.0.113.12' (($resPass.TlsResults[0].AttemptedIps) -join ',')
        Assert-Equal '203.0.113.10,203.0.113.11' ($global:__TlsTriedIps.ToArray() -join ',')
        Assert-Equal 2 $global:__TlsTriedIps.Count 'Should stop trying further RRset IPs once one passes'

        # Case 2: All IPs fail -> TlsAllPassed=$false and DEGRADED
        [void]$global:__TlsFailSet.Add('203.0.113.11')
        [void]$global:__TlsFailSet.Add('203.0.113.12')
        $global:__TlsTriedIps.Clear()
        $resFail = Test-ProfileHealth -Profile 'cloudflare' -Domains @('cloudcode-pa.googleapis.com') -Samples 1 -CheckTls -TimeoutSec 3
        Assert-False $resFail.TlsAllPassed 'Expected TlsAllPassed=$false when all RRset IPs fail'
        Assert-Equal 'DEGRADED' $resFail.Status
        Assert-Equal 1 (@($resFail.TlsResults)).Count
        Assert-False $resFail.TlsResults[0].Success
        Assert-Equal 3 $resFail.TlsResults[0].FailedAttemptCount
        Assert-Equal '203.0.113.10,203.0.113.11,203.0.113.12' (($resFail.TlsResults[0].AttemptedIps) -join ',')
    } finally {
        Restore-AllModuleStubs
        Remove-Variable -Name '__TlsFailSet' -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name '__TlsTriedIps' -Scope Global -ErrorAction SilentlyContinue
    }
}

Invoke-TestCase -State $state -Name 'Regression: Get-LiveDnsAvailability -TimeoutSec 3 returns 12 profiles, RecommendedIds, CheckedAt, DurationMs' {
    $avail = Get-LiveDnsAvailability -ConfigPath (Join-Path $projectRoot 'config\profiles.json') -TimeoutSec 3
    Assert-NotNull $avail
    Assert-False ([string]::IsNullOrWhiteSpace([string]$avail.CheckedAt)) 'CheckedAt must be populated'
    $parsedDate = [datetime]::MinValue
    Assert-True ([datetime]::TryParse([string]$avail.CheckedAt, [ref]$parsedDate)) 'CheckedAt must be parseable datetime'
    Assert-Equal ([bool]$script:InitialVpn.IsActive) ([bool]$avail.VpnActive)
    Assert-GreaterThan ([double]$avail.DurationMs) 0 'DurationMs must be > 0'
    Assert-NotNull $avail.RecommendedIds
    Assert-GreaterThan (@($avail.RecommendedIds)).Count 0 'Expected at least 1 RecommendedId'
    Assert-True ((@($avail.RecommendedIds)).Count -le 3) 'RecommendedIds should contain at most 3 profiles'
    $results = @($avail.Results)
    Assert-Equal 12 $results.Count 'Expected 12 profile results from Get-LiveDnsAvailability'
    foreach ($item in $results) {
        Assert-False ([string]::IsNullOrWhiteSpace([string]$item.ProfileId))
        Assert-Contains @('ONLINE', 'DEGRADED', 'OFFLINE') ([string]$item.Status)
        Assert-Equal 3 ([int]$item.TotalDomains)
    }
}

Invoke-TestCase -State $state -Name 'Live non-destructive DoH probe (cloudflare & quad9) and strict TLS check' {
    $cf = Get-DnsProfileById -Id 'cloudflare'
    $q9 = Get-DnsProfileById -Id 'quad9'
    $testDomains = @('cloudcode-pa.googleapis.com', 'accounts.google.com')

    $resolvedCloudcodeIp = $null
    foreach ($d in $testDomains) {
        $rCf = Invoke-DohQuery -Domain $d -DohTemplate ([string]$cf.doh_template) -ServerIp ([string]$cf.doh_ips[0]) -TimeoutSec 8
        Assert-True $rCf.Success "Cloudflare DoH failed for $d : $($rCf.Error)"
        Assert-Equal 200 $rCf.HttpStatus
        Assert-Equal 0 $rCf.RCode
        Assert-GreaterThan (@($rCf.ARecords)).Count 0 "No A records from cloudflare for $d"
        Assert-NotContains $rCf.ARecords '0.0.0.0'
        if ($d -eq 'cloudcode-pa.googleapis.com') {
            $resolvedCloudcodeIp = [string]$rCf.ARecords[0]
        }

        $rQ9 = Invoke-DohQuery -Domain $d -DohTemplate ([string]$q9.doh_template) -ServerIp ([string]$q9.doh_ips[0]) -TimeoutSec 8 -RequireHttp2
        Assert-True $rQ9.Success "Quad9 DoH failed for $d : $($rQ9.Error)"
        Assert-Equal 200 $rQ9.HttpStatus
        Assert-Match '^2' ([string]$rQ9.HttpVersion) "Expected HTTP/2 from Quad9, got '$($rQ9.HttpVersion)'"
        Assert-Equal 0 $rQ9.RCode
        Assert-GreaterThan (@($rQ9.ARecords)).Count 0 "No A records from quad9 for $d"
        Assert-NotContains $rQ9.ARecords '0.0.0.0'
    }

    Assert-NotNull $resolvedCloudcodeIp
    $tls = Test-TlsEndpoint -Hostname 'cloudcode-pa.googleapis.com' -IpAddress $resolvedCloudcodeIp -TimeoutSec 8
    Assert-True $tls.Success "Strict TLS check failed for cloudcode-pa.googleapis.com at $resolvedCloudcodeIp : $($tls.Error)"
    Assert-Match 'Tls1[23]' ([string]$tls.SslProtocol)
    Assert-False ([string]::IsNullOrWhiteSpace([string]$tls.CertSubject))
}

Invoke-TestCase -State $state -Name 'Post-test check: VPN state remains unchanged' {
    $vpnAfter = Get-VpnTunnelState
    Assert-Equal ([bool]$script:InitialVpn.IsActive) ([bool]$vpnAfter.IsActive) 'VPN IsActive changed during unit tests'
    Assert-Equal ([bool]$script:InitialVpn.AdapterPresent) ([bool]$vpnAfter.AdapterPresent) 'VPN AdapterPresent changed during unit tests'
    Assert-Equal ([string]$script:InitialVpn.AdapterStatus) ([string]$vpnAfter.AdapterStatus) 'VPN AdapterStatus changed during unit tests'
    Assert-Equal ([string]$script:InitialVpn.AdapterName) ([string]$vpnAfter.AdapterName) 'VPN AdapterName changed during unit tests'
}

$exitCode = Complete-TestSuite -State $state
exit $exitCode
