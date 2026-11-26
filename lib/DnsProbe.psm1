Set-StrictMode -Version Latest

if (-not (Get-Command -Name 'Get-DnsProfilesConfig' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'DnsCommon.psm1') -ErrorAction Stop
}

$script:DohCSharpSource = @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

namespace DnsSwitcherNet {
    public static class DohClient {
        public static byte[] Query(
            string dohUrl,
            string serverIp,
            byte[] dnsWireQuery,
            int timeoutMs,
            string method,
            bool requireHttp2,
            out int statusCode,
            out string httpVersion,
            out string errorMessage)
        {
            statusCode = 0;
            httpVersion = "";
            errorMessage = "";
            try {
                var uri = new Uri(dohUrl);
                if (string.Equals(method, "GET", StringComparison.OrdinalIgnoreCase)) {
                    string b64 = Convert.ToBase64String(dnsWireQuery).TrimEnd('=').Replace('+', '-').Replace('/', '_');
                    string sep = string.IsNullOrEmpty(uri.Query) ? "?" : "&";
                    uri = new Uri(dohUrl + sep + "dns=" + b64);
                }

                IPAddress pinnedIp = null;
                if (!string.IsNullOrEmpty(serverIp)) {
                    pinnedIp = IPAddress.Parse(serverIp);
                }

                using (var handler = new SocketsHttpHandler()) {
                    handler.PooledConnectionLifetime = TimeSpan.FromSeconds(1);
                    handler.AllowAutoRedirect = false;
                    if (pinnedIp != null) {
                        handler.ConnectCallback = async (context, cancellationToken) => {
                            var socket = new Socket(pinnedIp.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
                            socket.NoDelay = true;
                            try {
                                await socket.ConnectAsync(new IPEndPoint(pinnedIp, context.DnsEndPoint.Port), cancellationToken).ConfigureAwait(false);
                                return new NetworkStream(socket, true);
                            } catch {
                                socket.Dispose();
                                throw;
                            }
                        };
                    }

                    using (var client = new HttpClient(handler)) {
                        client.Timeout = TimeSpan.FromMilliseconds(timeoutMs);
                        var httpMethod = string.Equals(method, "GET", StringComparison.OrdinalIgnoreCase) ? HttpMethod.Get : HttpMethod.Post;
                        using (var req = new HttpRequestMessage(httpMethod, uri)) {
                            req.Version = new Version(2, 0);
                            req.VersionPolicy = requireHttp2 ? HttpVersionPolicy.RequestVersionExact : HttpVersionPolicy.RequestVersionOrLower;
                            req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/dns-message"));
                            if (httpMethod == HttpMethod.Post) {
                                var content = new ByteArrayContent(dnsWireQuery);
                                content.Headers.ContentType = new MediaTypeHeaderValue("application/dns-message");
                                req.Content = content;
                            }

                            using (var resp = client.SendAsync(req).GetAwaiter().GetResult()) {
                                statusCode = (int)resp.StatusCode;
                                httpVersion = resp.Version.ToString();
                                return resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult();
                            }
                        }
                    }
                }
            } catch (Exception ex) {
                errorMessage = ex.GetBaseException().Message;
                return Array.Empty<byte>();
            }
        }
    }
}
'@

function Ensure-DohClientType {
    [CmdletBinding()]
    param()
    if (-not ('DnsSwitcherNet.DohClient' -as [type])) {
        Add-Type -TypeDefinition $script:DohCSharpSource -Language CSharp -ErrorAction Stop
    }
}

function ConvertTo-Base64Url {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )
    $b64 = [Convert]::ToBase64String($Bytes)
    return $b64.TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Read-UInt16BE {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$Offset
    )
    return ([int]$Bytes[$Offset] -shl 8) -bor ([int]$Bytes[$Offset + 1])
}

function Read-UInt32BE {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$Offset
    )
    return ([uint32]$Bytes[$Offset] -shl 24) -bor
           ([uint32]$Bytes[$Offset + 1] -shl 16) -bor
           ([uint32]$Bytes[$Offset + 2] -shl 8) -bor
           ([uint32]$Bytes[$Offset + 3])
}

function Read-DnsWireName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$Offset
    )

    $labels = New-Object System.Collections.Generic.List[string]
    $pos = $Offset
    $nextOffset = -1
    $jumped = $false
    $jumps = 0
    $maxLen = $Bytes.Length

    while ($true) {
        if ($pos -ge $maxLen) {
            throw "Truncated DNS name at offset $pos."
        }
        $len = [int]$Bytes[$pos]
        if ($len -eq 0) {
            if (-not $jumped) {
                $nextOffset = $pos + 1
            }
            break
        }
        if (($len -band 0xC0) -eq 0xC0) {
            if (($pos + 1) -ge $maxLen) {
                throw "Truncated DNS compression pointer at offset $pos."
            }
            if (-not $jumped) {
                $nextOffset = $pos + 2
                $jumped = $true
            }
            $ptr = (($len -band 0x3F) -shl 8) -bor ([int]$Bytes[$pos + 1])
            if ($ptr -ge $maxLen) {
                throw "Out-of-bounds DNS compression pointer $ptr."
            }
            $jumps++
            if ($jumps -gt 32) {
                throw 'Exceeded maximum DNS compression pointer hops (possible loop).'
            }
            $pos = $ptr
            continue
        }
        if (($len -band 0xC0) -ne 0) {
            throw "Invalid DNS label header byte $len at offset $pos."
        }
        $pos++
        if (($pos + $len) -gt $maxLen) {
            throw "Truncated DNS label at offset $pos."
        }
        $label = [System.Text.Encoding]::ASCII.GetString($Bytes, $pos, $len)
        $labels.Add($label)
        $pos += $len
    }

    return [pscustomobject]@{
        Name       = ($labels.ToArray() -join '.')
        NextOffset = $nextOffset
    }
}

function Get-DnsRCodeName {
    [CmdletBinding()]
    param([int]$RCode)
    switch ($RCode) {
        0 { return 'NOERROR' }
        1 { return 'FORMERR' }
        2 { return 'SERVFAIL' }
        3 { return 'NXDOMAIN' }
        4 { return 'NOTIMP' }
        5 { return 'REFUSED' }
        default { return "RCODE_$RCode" }
    }
}

function Get-DnsRecordTypeName {
    [CmdletBinding()]
    param([int]$RecordType)
    switch ($RecordType) {
        1 { return 'A' }
        2 { return 'NS' }
        5 { return 'CNAME' }
        6 { return 'SOA' }
        12 { return 'PTR' }
        15 { return 'MX' }
        16 { return 'TXT' }
        28 { return 'AAAA' }
        default { return "TYPE$RecordType" }
    }
}

function New-DnsWireQuery {
    <#
    .SYNOPSIS
        Builds a pure-byte RFC 1035 DNS wire query packet.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [int]$RecordType = 1,
        [int]$TransactionId = -1
    )

    $trimmed = $Domain.Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw 'Domain must not be empty.'
    }
    if ($trimmed.Length -gt 253) {
        throw "Domain '$trimmed' exceeds 253 characters."
    }
    if ($TransactionId -lt 0) {
        $TransactionId = Get-Random -Minimum 1 -Maximum 65536
    }

    $buf = New-Object System.Collections.Generic.List[byte]
    # Header: ID (2), Flags RD=1 (2), QDCOUNT=1 (2), AN/NS/AR=0 (6)
    $buf.Add([byte](($TransactionId -shr 8) -band 0xFF))
    $buf.Add([byte]($TransactionId -band 0xFF))
    $buf.Add([byte]0x01)
    $buf.Add([byte]0x00)
    $buf.Add([byte]0x00)
    $buf.Add([byte]0x01)
    $buf.Add([byte]0x00)
    $buf.Add([byte]0x00)
    $buf.Add([byte]0x00)
    $buf.Add([byte]0x00)
    $buf.Add([byte]0x00)
    $buf.Add([byte]0x00)

    foreach ($label in ($trimmed -split '\.')) {
        $labelBytes = [System.Text.Encoding]::ASCII.GetBytes($label)
        if ($labelBytes.Length -eq 0 -or $labelBytes.Length -gt 63) {
            throw "Invalid DNS label '$label' in domain '$trimmed'."
        }
        $buf.Add([byte]$labelBytes.Length)
        foreach ($b in $labelBytes) {
            $buf.Add($b)
        }
    }
    $buf.Add([byte]0x00)

    # QTYPE and QCLASS (IN = 1)
    $buf.Add([byte](($RecordType -shr 8) -band 0xFF))
    $buf.Add([byte]($RecordType -band 0xFF))
    $buf.Add([byte]0x00)
    $buf.Add([byte]0x01)

    [byte[]]$outBytes = $buf.ToArray()
    return ,$outBytes
}

function Read-DnsWireResponse {
    <#
    .SYNOPSIS
        Parses an RFC 1035 DNS wire response packet (RCODE, A, AAAA, CNAME, TXT, compressed names).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    if ($null -eq $Bytes -or $Bytes.Length -lt 12) {
        throw "DNS wire response too short (expected >= 12 bytes, got $(if ($null -eq $Bytes) { 0 } else { $Bytes.Length }))."
    }

    $txId = Read-UInt16BE -Bytes $Bytes -Offset 0
    $flags = Read-UInt16BE -Bytes $Bytes -Offset 2
    $isResponse = (($flags -band 0x8000) -ne 0)
    $rcode = $flags -band 0x000F
    $rcodeName = Get-DnsRCodeName -RCode $rcode

    $qdCount = Read-UInt16BE -Bytes $Bytes -Offset 4
    $anCount = Read-UInt16BE -Bytes $Bytes -Offset 6
    $nsCount = Read-UInt16BE -Bytes $Bytes -Offset 8
    $arCount = Read-UInt16BE -Bytes $Bytes -Offset 10

    $pos = 12
    for ($q = 0; $q -lt $qdCount; $q++) {
        $qName = Read-DnsWireName -Bytes $Bytes -Offset $pos
        $pos = $qName.NextOffset + 4
        if ($pos -gt $Bytes.Length) {
            throw 'Truncated DNS question section.'
        }
    }

    $records = New-Object System.Collections.Generic.List[object]
    $aRecords = New-Object System.Collections.Generic.List[string]
    $aaaaRecords = New-Object System.Collections.Generic.List[string]
    $cnames = New-Object System.Collections.Generic.List[string]
    $minTtl = $null

    for ($a = 0; $a -lt $anCount; $a++) {
        $rrName = Read-DnsWireName -Bytes $Bytes -Offset $pos
        $pos = $rrName.NextOffset
        if (($pos + 10) -gt $Bytes.Length) {
            throw 'Truncated DNS answer RR header.'
        }

        $rrType = Read-UInt16BE -Bytes $Bytes -Offset $pos
        $rrClass = Read-UInt16BE -Bytes $Bytes -Offset ($pos + 2)
        $ttl = Read-UInt32BE -Bytes $Bytes -Offset ($pos + 4)
        $rdLen = Read-UInt16BE -Bytes $Bytes -Offset ($pos + 8)
        $pos += 10

        if (($pos + $rdLen) -gt $Bytes.Length) {
            throw 'Truncated DNS answer RDATA.'
        }

        if ($null -eq $minTtl -or $ttl -lt $minTtl) {
            $minTtl = $ttl
        }

        $typeName = Get-DnsRecordTypeName -RecordType $rrType
        $value = ''

        if ($rrType -eq 1 -and $rdLen -eq 4) {
            $value = "$($Bytes[$pos]).$($Bytes[$pos + 1]).$($Bytes[$pos + 2]).$($Bytes[$pos + 3])"
            $aRecords.Add($value)
        } elseif ($rrType -eq 28 -and $rdLen -eq 16) {
            $slice = New-Object byte[] 16
            [Array]::Copy($Bytes, $pos, $slice, 0, 16)
            $ipObj = New-Object System.Net.IPAddress -ArgumentList (,$slice)
            $value = $ipObj.ToString()
            $aaaaRecords.Add($value)
        } elseif ($rrType -eq 5 -or $rrType -eq 2 -or $rrType -eq 12) {
            $target = Read-DnsWireName -Bytes $Bytes -Offset $pos
            $value = $target.Name
            if ($rrType -eq 5) {
                $cnames.Add($value)
            }
        } elseif ($rrType -eq 16) {
            $txtParts = New-Object System.Collections.Generic.List[string]
            $tPos = $pos
            $tEnd = $pos + $rdLen
            while ($tPos -lt $tEnd) {
                $tLen = [int]$Bytes[$tPos]
                $tPos++
                if (($tPos + $tLen) -gt $tEnd) { break }
                $txtParts.Add([System.Text.Encoding]::UTF8.GetString($Bytes, $tPos, $tLen))
                $tPos += $tLen
            }
            $value = ($txtParts.ToArray() -join '')
        } else {
            $slice = New-Object byte[] $rdLen
            [Array]::Copy($Bytes, $pos, $slice, 0, $rdLen)
            $value = ([BitConverter]::ToString($slice)).Replace('-', '')
        }

        $records.Add([pscustomobject]@{
            Name     = $rrName.Name
            Type     = $rrType
            TypeName = $typeName
            Class    = $rrClass
            Ttl      = $ttl
            Value    = $value
        })

        $pos += $rdLen
    }

    return [pscustomobject]@{
        Success        = ($isResponse -and $rcode -eq 0)
        TransactionId  = $txId
        IsResponse     = $isResponse
        RCode          = $rcode
        RCodeName      = $rcodeName
        QuestionCount  = $qdCount
        AnswerCount    = $anCount
        AuthorityCount = $nsCount
        AdditionalCount = $arCount
        MinTtl         = $minTtl
        ARecords       = $aRecords.ToArray()
        AAAARecords    = $aaaaRecords.ToArray()
        CNames         = $cnames.ToArray()
        Records        = $records.ToArray()
    }
}

function Find-PwshExecutablePath {
    [CmdletBinding()]
    param()

    $cmd = Get-Command -Name 'pwsh.exe' -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace($cmd.Source)) {
        return $cmd.Source
    }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'),
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        (Join-Path $env:ProgramFiles 'PowerShell\7-preview\pwsh.exe')
    )
    foreach ($cand in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($cand) -and (Test-Path -LiteralPath $cand -PathType Leaf)) {
            return $cand
        }
    }
    return $null
}

function Invoke-DohViaPwshBridge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PwshPath,
        [Parameter(Mandatory = $true)][string]$DohTemplate,
        [string]$ServerIp,
        [Parameter(Mandatory = $true)][byte[]]$WireBytes,
        [Parameter(Mandatory = $true)][int]$TimeoutMs,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][bool]$RequireHttp2
    )

    $qB64 = [Convert]::ToBase64String($WireBytes)
    $escUrl = $DohTemplate.Replace("'", "''")
    $escIp = ([string]$ServerIp).Replace("'", "''")
    $escMethod = $Method.Replace("'", "''")
    $reqH2Literal = if ($RequireHttp2) { '$true' } else { '$false' }
    $csLiteral = $script:DohCSharpSource.Replace("'", "''")

    $bridgeScript = @"
`$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition '$csLiteral' -Language CSharp
`$q = [Convert]::FromBase64String('$qB64')
`$sc = 0; `$hv = ''; `$err = ''
`$sw = [System.Diagnostics.Stopwatch]::StartNew()
`$resp = [DnsSwitcherNet.DohClient]::Query('$escUrl', '$escIp', `$q, $TimeoutMs, '$escMethod', $reqH2Literal, [ref]`$sc, [ref]`$hv, [ref]`$err)
`$sw.Stop()
`$out = @{
    statusCode = `$sc
    httpVersion = `$hv
    rttMs = [math]::Round(`$sw.Elapsed.TotalMilliseconds, 2)
    bodyB64 = if (`$resp -and `$resp.Length -gt 0) { [Convert]::ToBase64String(`$resp) } else { '' }
    error = `$err
}
Write-Output ('__DOHOUT__' + (`$out | ConvertTo-Json -Compress))
"@

    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($bridgeScript))
    $stdoutLines = @(& $PwshPath -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1)
    $markerLine = $stdoutLines | Where-Object { [string]$_ -like '__DOHOUT__*' } | Select-Object -Last 1
    if ($null -eq $markerLine) {
        $errText = ($stdoutLines | ForEach-Object { [string]$_ }) -join ' '
        return [pscustomobject]@{
            StatusCode    = 0
            HttpVersion   = ''
            RttMs         = 0.0
            ResponseBytes = [byte[]]@()
            Error         = "pwsh bridge failed: $errText"
            Transport     = 'PwshBridge'
        }
    }

    $jsonStr = ([string]$markerLine).Substring(10)
    $parsed = $jsonStr | ConvertFrom-Json
    $respBytes = if (-not [string]::IsNullOrWhiteSpace([string]$parsed.bodyB64)) {
        [Convert]::FromBase64String([string]$parsed.bodyB64)
    } else {
        [byte[]]@()
    }

    return [pscustomobject]@{
        StatusCode    = [int]$parsed.statusCode
        HttpVersion   = [string]$parsed.httpVersion
        RttMs         = [double]$parsed.rttMs
        ResponseBytes = $respBytes
        Error         = [string]$parsed.error
        Transport     = 'PwshBridge'
    }
}

function Invoke-DohViaCurlOrDotNet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DohTemplate,
        [string]$ServerIp,
        [Parameter(Mandatory = $true)][byte[]]$WireBytes,
        [Parameter(Mandatory = $true)][int]$TimeoutSec,
        [Parameter(Mandatory = $true)][string]$Method
    )

    $curlCmd = Get-Command -Name 'curl.exe' -ErrorAction SilentlyContinue
    if ($null -ne $curlCmd) {
        $uri = [Uri]$DohTemplate
        $port = if ($uri.Port -gt 0) { $uri.Port } else { 443 }
        $tmpIn = Join-Path ([System.IO.Path]::GetTempPath()) ("doh_in_" + [Guid]::NewGuid().ToString('N') + ".bin")
        $tmpOut = Join-Path ([System.IO.Path]::GetTempPath()) ("doh_out_" + [Guid]::NewGuid().ToString('N') + ".bin")
        try {
            $curlArgs = New-Object System.Collections.Generic.List[string]
            $curlArgs.Add('-sS')
            $curlArgs.Add('--max-time')
            $curlArgs.Add([string]$TimeoutSec)
            if (-not [string]::IsNullOrWhiteSpace($ServerIp)) {
                $curlArgs.Add('--resolve')
                $curlArgs.Add("$($uri.Host):${port}:$ServerIp")
            }
            $curlArgs.Add('-H')
            $curlArgs.Add('Accept: application/dns-message')

            $targetUrl = $DohTemplate
            if ($Method -eq 'GET') {
                $sep = if ([string]::IsNullOrEmpty($uri.Query)) { '?' } else { '&' }
                $targetUrl = $DohTemplate + $sep + 'dns=' + (ConvertTo-Base64Url -Bytes $WireBytes)
            } else {
                [System.IO.File]::WriteAllBytes($tmpIn, $WireBytes)
                $curlArgs.Add('-X')
                $curlArgs.Add('POST')
                $curlArgs.Add('-H')
                $curlArgs.Add('Content-Type: application/dns-message')
                $curlArgs.Add('--data-binary')
                $curlArgs.Add("@$tmpIn")
            }

            $curlArgs.Add('-o')
            $curlArgs.Add($tmpOut)
            $curlArgs.Add('-w')
            $curlArgs.Add('%{http_code}|%{http_version}|%{time_total}')
            $curlArgs.Add($targetUrl)

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $metaRaw = @(& $curlCmd.Source @curlArgs 2>&1)
            $exitCode = $LASTEXITCODE
            $sw.Stop()

            $metaStr = ($metaRaw | ForEach-Object { [string]$_ }) -join ' '
            if ($exitCode -ne 0) {
                return [pscustomobject]@{
                    StatusCode    = 0
                    HttpVersion   = ''
                    RttMs         = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
                    ResponseBytes = [byte[]]@()
                    Error         = "curl.exe exit ${exitCode}: $metaStr"
                    Transport     = 'CurlFallback'
                }
            }

            $parts = ($metaStr.Trim() -split '\|')
            $sc = if ($parts.Count -ge 1 -and $parts[0] -match '^\d+$') { [int]$parts[0] } else { 0 }
            $hv = if ($parts.Count -ge 2) { $parts[1] } else { '' }
            $rtt = if ($parts.Count -ge 3 -and $parts[2] -match '^[0-9.,]+$') {
                [math]::Round(([double]($parts[2].Replace(',', '.'))) * 1000.0, 2)
            } else {
                [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
            }
            $respBytes = if (Test-Path -LiteralPath $tmpOut) { [System.IO.File]::ReadAllBytes($tmpOut) } else { [byte[]]@() }

            return [pscustomobject]@{
                StatusCode    = $sc
                HttpVersion   = $hv
                RttMs         = $rtt
                ResponseBytes = $respBytes
                Error         = if ($sc -ne 200) { "HTTP $sc from curl fallback" } else { '' }
                Transport     = 'CurlFallback'
            }
        } finally {
            if (Test-Path -LiteralPath $tmpIn) { Remove-Item -LiteralPath $tmpIn -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $tmpOut) { Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue }
        }
    }

    # Final fallback: .NET Framework HttpClient (note: does not pin ServerIp without curl/pwsh)
    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    } catch {
        # Already loaded or core assembly.
    }
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    try {
        $targetUrl = $DohTemplate
        $httpMethod = [System.Net.Http.HttpMethod]::Post
        if ($Method -eq 'GET') {
            $httpMethod = [System.Net.Http.HttpMethod]::Get
            $uri = [Uri]$DohTemplate
            $sep = if ([string]::IsNullOrEmpty($uri.Query)) { '?' } else { '&' }
            $targetUrl = $DohTemplate + $sep + 'dns=' + (ConvertTo-Base64Url -Bytes $WireBytes)
        }
        $req = New-Object System.Net.Http.HttpRequestMessage($httpMethod, $targetUrl)
        [void]$req.Headers.Accept.TryParseAdd('application/dns-message')
        if ($Method -eq 'POST') {
            $content = New-Object System.Net.Http.ByteArrayContent(,$WireBytes)
            $content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue('application/dns-message')
            $req.Content = $content
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $sw.Stop()
        return [pscustomobject]@{
            StatusCode    = [int]$resp.StatusCode
            HttpVersion   = $resp.Version.ToString()
            RttMs         = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
            ResponseBytes = $bytes
            Error         = if ([int]$resp.StatusCode -ne 200) { "HTTP $([int]$resp.StatusCode)" } else { '' }
            Transport     = 'DotNetFallback'
        }
    } catch {
        return [pscustomobject]@{
            StatusCode    = 0
            HttpVersion   = ''
            RttMs         = 0.0
            ResponseBytes = [byte[]]@()
            Error         = $_.Exception.GetBaseException().Message
            Transport     = 'DotNetFallback'
        }
    } finally {
        $client.Dispose()
    }
}

function Invoke-DohQuery {
    <#
    .SYNOPSIS
        Performs an RFC 8484 DoH query with optional IPv4 pinning and HTTP/2 support across PS 5.1 and PS 7+.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [Parameter(Mandatory = $true)][string]$DohTemplate,
        [string]$ServerIp,
        [int]$RecordType = 1,
        [int]$TimeoutSec = 5,
        [ValidateSet('POST', 'GET')][string]$Method = 'POST',
        [switch]$RequireHttp2
    )

    $wireQuery = New-DnsWireQuery -Domain $Domain -RecordType $RecordType
    $timeoutMs = [math]::Max(500, $TimeoutSec * 1000)

    $rawResult = $null
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        Ensure-DohClientType
        $sc = 0
        $hv = ''
        $err = ''
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $respBytes = [DnsSwitcherNet.DohClient]::Query($DohTemplate, [string]$ServerIp, $wireQuery, $timeoutMs, $Method, [bool]$RequireHttp2, [ref]$sc, [ref]$hv, [ref]$err)
        $sw.Stop()
        $rawResult = [pscustomobject]@{
            StatusCode    = $sc
            HttpVersion   = $hv
            RttMs         = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
            ResponseBytes = $respBytes
            Error         = $err
            Transport     = 'SocketsHttpHandler'
        }
    } else {
        $pwshPath = Find-PwshExecutablePath
        if (-not [string]::IsNullOrWhiteSpace($pwshPath)) {
            $rawResult = Invoke-DohViaPwshBridge -PwshPath $pwshPath -DohTemplate $DohTemplate -ServerIp $ServerIp -WireBytes $wireQuery -TimeoutMs $timeoutMs -Method $Method -RequireHttp2 ([bool]$RequireHttp2)
        } else {
            $rawResult = Invoke-DohViaCurlOrDotNet -DohTemplate $DohTemplate -ServerIp $ServerIp -WireBytes $wireQuery -TimeoutSec $TimeoutSec -Method $Method
        }
    }

    $parsedDns = $null
    $parseErr = ''
    if ($rawResult.StatusCode -eq 200 -and $null -ne $rawResult.ResponseBytes -and $rawResult.ResponseBytes.Length -ge 12) {
        try {
            $parsedDns = Read-DnsWireResponse -Bytes $rawResult.ResponseBytes
        } catch {
            $parseErr = "DNS wire parse error: $($_.Exception.Message)"
        }
    }

    $finalErr = $rawResult.Error
    if ([string]::IsNullOrWhiteSpace($finalErr) -and -not [string]::IsNullOrWhiteSpace($parseErr)) {
        $finalErr = $parseErr
    } elseif ([string]::IsNullOrWhiteSpace($finalErr) -and $rawResult.StatusCode -ne 200) {
        $finalErr = "DoH returned HTTP $($rawResult.StatusCode)."
    }

    $dnsSuccess = ($rawResult.StatusCode -eq 200 -and $null -ne $parsedDns -and $parsedDns.Success)
    if ($rawResult.StatusCode -eq 200 -and $null -ne $parsedDns -and -not $parsedDns.Success -and [string]::IsNullOrWhiteSpace($finalErr)) {
        $finalErr = "DNS RCODE $($parsedDns.RCode) ($($parsedDns.RCodeName))"
    }

    return [pscustomobject]@{
        Success     = $dnsSuccess
        Domain      = $Domain
        RecordType  = $RecordType
        DohTemplate = $DohTemplate
        ServerIp    = $ServerIp
        Method      = $Method
        Transport   = $rawResult.Transport
        HttpStatus  = $rawResult.StatusCode
        HttpVersion = $rawResult.HttpVersion
        RttMs       = $rawResult.RttMs
        RCode       = if ($null -ne $parsedDns) { $parsedDns.RCode } else { $null }
        RCodeName   = if ($null -ne $parsedDns) { $parsedDns.RCodeName } else { $null }
        ARecords    = if ($null -ne $parsedDns) { @($parsedDns.ARecords) } else { @() }
        AAAARecords = if ($null -ne $parsedDns) { @($parsedDns.AAAARecords) } else { @() }
        CNames      = if ($null -ne $parsedDns) { @($parsedDns.CNames) } else { @() }
        Records     = if ($null -ne $parsedDns) { @($parsedDns.Records) } else { @() }
        MinTtl      = if ($null -ne $parsedDns) { $parsedDns.MinTtl } else { $null }
        Error       = $finalErr
    }
}

function Test-TlsEndpoint {
    <#
    .SYNOPSIS
        Tests strict TCP + TLS handshake against a specific IP address using SNI and full certificate chain validation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Hostname,
        [Parameter(Mandatory = $true)][string]$IpAddress,
        [int]$Port = 443,
        [int]$TimeoutSec = 5
    )

    $tcpClient = New-Object System.Net.Sockets.TcpClient
    $sslStream = $null
    $tcpMs = $null
    $tlsMs = $null
    $totalSw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $timeoutMs = [math]::Max(500, $TimeoutSec * 1000)
        $parsedIp = [System.Net.IPAddress]::Parse($IpAddress)
        $tcpSw = [System.Diagnostics.Stopwatch]::StartNew()
        $connectTask = $tcpClient.ConnectAsync($parsedIp, $Port)
        if (-not $connectTask.Wait($timeoutMs)) {
            throw "TCP connect to ${IpAddress}:${Port} timed out after ${TimeoutSec}s."
        }
        $tcpSw.Stop()
        $tcpMs = [math]::Round($tcpSw.Elapsed.TotalMilliseconds, 2)

        $tcpClient.ReceiveTimeout = $timeoutMs
        $tcpClient.SendTimeout = $timeoutMs
        $netStream = $tcpClient.GetStream()
        $sslStream = New-Object System.Net.Security.SslStream($netStream, $false)

        $tlsSw = [System.Diagnostics.Stopwatch]::StartNew()
        $authTask = $sslStream.AuthenticateAsClientAsync($Hostname)
        if (-not $authTask.Wait($timeoutMs)) {
            throw "TLS handshake for '$Hostname' at ${IpAddress}:${Port} timed out after ${TimeoutSec}s."
        }
        $tlsSw.Stop()
        $tlsMs = [math]::Round($tlsSw.Elapsed.TotalMilliseconds, 2)
        $totalSw.Stop()

        $cert2 = $null
        if ($null -ne $sslStream.RemoteCertificate) {
            $cert2 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($sslStream.RemoteCertificate)
        }

        return [pscustomobject]@{
            Success     = $true
            Hostname    = $Hostname
            IpAddress   = $IpAddress
            Port        = $Port
            TcpRttMs    = $tcpMs
            TlsRttMs    = $tlsMs
            TotalMs     = [math]::Round($totalSw.Elapsed.TotalMilliseconds, 2)
            SslProtocol = [string]$sslStream.SslProtocol
            CertSubject = if ($null -ne $cert2) { $cert2.Subject } else { $null }
            CertIssuer  = if ($null -ne $cert2) { $cert2.Issuer } else { $null }
            CertNotAfter = if ($null -ne $cert2) { $cert2.NotAfter.ToString('o') } else { $null }
            Error       = ''
        }
    } catch {
        $totalSw.Stop()
        return [pscustomobject]@{
            Success     = $false
            Hostname    = $Hostname
            IpAddress   = $IpAddress
            Port        = $Port
            TcpRttMs    = $tcpMs
            TlsRttMs    = $tlsMs
            TotalMs     = [math]::Round($totalSw.Elapsed.TotalMilliseconds, 2)
            SslProtocol = $null
            CertSubject = $null
            CertIssuer  = $null
            CertNotAfter = $null
            Error       = $_.Exception.GetBaseException().Message
        }
    } finally {
        if ($null -ne $sslStream) { $sslStream.Dispose() }
        $tcpClient.Close()
        $tcpClient.Dispose()
    }
}

function Get-ProbeDefaultDomains {
    [CmdletBinding()]
    param([string]$ConfigPath)

    try {
        $cfg = Get-DnsProfilesConfig -ConfigPath $ConfigPath -ErrorAction Stop
        $list = New-Object System.Collections.Generic.List[string]
        foreach ($group in @('antigravity_core', 'google_auth', 'ai_inference', 'ecosystem')) {
            foreach ($d in @($cfg.test_domains.$group)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$d) -and -not $list.Contains([string]$d)) {
                    $list.Add([string]$d)
                }
            }
        }
        if ($list.Count -gt 0) {
            return $list.ToArray()
        }
    } catch {
        # Fall back to built-in Antigravity/Google domain set.
    }

    return @(
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
        'edgedl.me.gvt1.com'
    )
}

function Get-DomainAnswerClassification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$DohResult,
        [Parameter(Mandatory = $true)]$Profile
    )

    if (-not $DohResult.Success) {
        return 'ERROR'
    }

    $ips = @($DohResult.ARecords | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($ips.Count -eq 0) {
        return 'NO_A_RECORD'
    }

    foreach ($ip in $ips) {
        if ($ip -eq '0.0.0.0' -or $ip -eq '127.0.0.1' -or $ip -eq '::' -or $ip -eq '::1') {
            return 'BLOCKED'
        }
    }

    $proxyDomains = @()
    if ($null -ne $Profile.PSObject.Properties['smart_proxy_domains']) {
        $proxyDomains = @($Profile.smart_proxy_domains | ForEach-Object { ([string]$_).ToLowerInvariant() })
    }
    if ($proxyDomains -contains ($DohResult.Domain.ToLowerInvariant())) {
        return 'SMART_PROXY'
    }

    foreach ($cn in @($DohResult.CNames)) {
        if ($cn -match '(?i)(comss\.one|geohide|malw|dns-ai|xbox-dns)') {
            return 'SMART_PROXY'
        }
    }

    return 'CLEAN_GOOGLE'
}

function Get-NumericStats {
    [CmdletBinding()]
    param([double[]]$Values)

    if ($null -eq $Values -or $Values.Count -eq 0) {
        return [pscustomobject]@{ Min = $null; Median = $null; Max = $null }
    }
    $sorted = @($Values | Sort-Object)
    $count = $sorted.Count
    $median = if (($count % 2) -eq 1) {
        $sorted[[int][math]::Floor($count / 2)]
    } else {
        [math]::Round(($sorted[($count / 2) - 1] + $sorted[$count / 2]) / 2.0, 2)
    }
    return [pscustomobject]@{
        Min    = [math]::Round($sorted[0], 2)
        Median = [math]::Round($median, 2)
        Max    = [math]::Round($sorted[$count - 1], 2)
    }
}

function Test-ProfileHealth {
    <#
    .SYNOPSIS
        Runs a multi-domain DoH health check (3 latency samples + critical domains + optional strict-TLS verification) for a DNS profile.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [string[]]$Domains,
        [int]$TimeoutSec = 5,
        [int]$Samples = 3,
        [switch]$CheckTls,
        [string]$ServerIp,
        [string]$ConfigPath
    )

    $resolvedProfile = if ($Profile -is [string]) {
        Get-DnsProfileById -Id $Profile -ConfigPath $ConfigPath
    } else {
        $Profile
    }

    if ($null -eq $Domains -or $Domains.Count -eq 0) {
        $Domains = Get-ProbeDefaultDomains -ConfigPath $ConfigPath
    }

    $targetIp = $ServerIp
    if ([string]::IsNullOrWhiteSpace($targetIp)) {
        $dohIps = @($resolvedProfile.doh_ips | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($dohIps.Count -gt 0) {
            $targetIp = [string]$dohIps[0]
        } else {
            $targetIp = [string]@($resolvedProfile.ipv4)[0]
        }
    }

    $requiresH2 = [bool]$resolvedProfile.requires_http2
    $template = [string]$resolvedProfile.doh_template
    $latencySamples = New-Object System.Collections.Generic.List[double]
    $sampleSuccess = 0

    for ($s = 0; $s -lt [math]::Max(1, $Samples); $s++) {
        $r = Invoke-DohQuery -Domain 'cloudcode-pa.googleapis.com' -DohTemplate $template -ServerIp $targetIp -TimeoutSec $TimeoutSec -RequireHttp2:$requiresH2
        if ($r.Success) {
            $sampleSuccess++
            $latencySamples.Add([double]$r.RttMs)
        }
    }
    $latStats = Get-NumericStats -Values $latencySamples.ToArray()

    $domainResults = New-Object System.Collections.Generic.List[object]
    $passedCount = 0
    $blockedCount = 0
    $errorCount = 0
    $proxiedCount = 0

    foreach ($domain in $Domains) {
        $res = Invoke-DohQuery -Domain $domain -DohTemplate $template -ServerIp $targetIp -TimeoutSec $TimeoutSec -RequireHttp2:$requiresH2
        $cls = Get-DomainAnswerClassification -DohResult $res -Profile $resolvedProfile

        if ($cls -eq 'CLEAN_GOOGLE' -or $cls -eq 'SMART_PROXY') {
            $passedCount++
            if ($cls -eq 'SMART_PROXY') { $proxiedCount++ }
        } elseif ($cls -eq 'BLOCKED') {
            $blockedCount++
        } else {
            $errorCount++
        }

        $domainResults.Add([pscustomobject]@{
            Domain         = $domain
            Classification = $cls
            Success        = $res.Success
            HttpStatus     = $res.HttpStatus
            HttpVersion    = $res.HttpVersion
            RttMs          = $res.RttMs
            ARecords       = @($res.ARecords)
            CNames         = @($res.CNames)
            Error          = $res.Error
        })
    }

    $tlsResults = New-Object System.Collections.Generic.List[object]
    $tlsAllPassed = $null
    if ($CheckTls) {
        $tlsTargets = @('cloudcode-pa.googleapis.com', 'daily-cloudcode-pa.googleapis.com', 'generativelanguage.googleapis.com', 'antigravity.google', 'accounts.google.com')
        $tlsOk = $true
        $tlsChecked = 0
        $maxTlsIpsPerDomain = 4
        foreach ($dr in $domainResults) {
            if ($tlsTargets -contains $dr.Domain -and ($dr.Classification -eq 'CLEAN_GOOGLE' -or $dr.Classification -eq 'SMART_PROXY') -and @($dr.ARecords).Count -gt 0) {
                $candidateIps = New-Object System.Collections.Generic.List[string]
                foreach ($rawIp in @($dr.ARecords)) {
                    $ipStr = [string]$rawIp
                    if (-not [string]::IsNullOrWhiteSpace($ipStr) -and -not $candidateIps.Contains($ipStr)) {
                        $candidateIps.Add($ipStr)
                        if ($candidateIps.Count -ge $maxTlsIpsPerDomain) { break }
                    }
                }
                if ($candidateIps.Count -eq 0) { continue }

                $failedNotes = New-Object System.Collections.Generic.List[string]
                $passingCheck = $null
                $lastCheck = $null
                foreach ($candIp in $candidateIps) {
                    $attempt = Test-TlsEndpoint -Hostname $dr.Domain -IpAddress $candIp -TimeoutSec $TimeoutSec
                    $lastCheck = $attempt
                    if ($attempt.Success) {
                        $passingCheck = $attempt
                        break
                    }
                    $failedNotes.Add(("{0}: {1}" -f $candIp, $attempt.Error))
                }

                $tlsChecked++
                $chosen = if ($null -ne $passingCheck) { $passingCheck } else { $lastCheck }
                if ($null -eq $passingCheck) {
                    $tlsOk = $false
                }
                $combinedErr = if ($null -ne $passingCheck) {
                    ''
                } elseif ($failedNotes.Count -gt 1) {
                    "All $($failedNotes.Count) tested IPs failed: $($failedNotes -join '; ')"
                } else {
                    $chosen.Error
                }

                $tlsResults.Add([pscustomobject]@{
                    Success            = [bool]$chosen.Success
                    Hostname           = $chosen.Hostname
                    IpAddress          = $chosen.IpAddress
                    Port               = $chosen.Port
                    TcpRttMs           = $chosen.TcpRttMs
                    TlsRttMs           = $chosen.TlsRttMs
                    TotalMs            = $chosen.TotalMs
                    SslProtocol        = $chosen.SslProtocol
                    CertSubject        = $chosen.CertSubject
                    CertIssuer         = $chosen.CertIssuer
                    CertNotAfter       = $chosen.CertNotAfter
                    Error              = $combinedErr
                    AttemptedIps       = $candidateIps.ToArray()
                    FailedAttemptCount = $failedNotes.Count
                    FailedAttempts     = $failedNotes.ToArray()
                })
            }
        }
        $tlsAllPassed = if ($tlsChecked -gt 0) { $tlsOk } else { $false }
    }

    $totalDomains = $Domains.Count
    $status = 'HEALTHY'
    if ($sampleSuccess -eq 0 -or $passedCount -eq 0 -or ($errorCount + $blockedCount) -ge ($totalDomains / 2.0)) {
        $status = 'UNHEALTHY'
    } elseif ($blockedCount -gt 0 -or $errorCount -gt 0 -or ($CheckTls -and $tlsAllPassed -eq $false)) {
        $status = 'DEGRADED'
    }

    return [pscustomobject]@{
        ProfileId       = [string]$resolvedProfile.id
        ProfileName     = [string]$resolvedProfile.name
        Category        = [string]$resolvedProfile.category
        TestedIp        = $targetIp
        DohTemplate     = $template
        RequiresHttp2   = $requiresH2
        Status          = $status
        SampleSuccess   = $sampleSuccess
        SampleCount     = [math]::Max(1, $Samples)
        PassedCount     = $passedCount
        TotalDomains    = $totalDomains
        BlockedCount    = $blockedCount
        ErrorCount      = $errorCount
        ProxiedCount    = $proxiedCount
        LatencyMinMs    = $latStats.Min
        LatencyMedianMs = $latStats.Median
        LatencyMaxMs    = $latStats.Max
        TlsAllPassed    = $tlsAllPassed
        DomainResults   = $domainResults.ToArray()
        TlsResults      = $tlsResults.ToArray()
        Timestamp       = (Get-Date).ToString('o')
    }
}

function Invoke-ProfileBenchmark {
    <#
    .SYNOPSIS
        Benchmarks multiple DNS profiles and returns comparison objects sorted by health and latency.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Profiles,
        [string[]]$Domains,
        [int]$TimeoutSec = 5,
        [int]$Samples = 3,
        [switch]$CheckTls,
        [string]$ConfigPath
    )

    $rawReports = New-Object System.Collections.Generic.List[object]
    foreach ($p in $Profiles) {
        $report = Test-ProfileHealth -Profile $p -Domains $Domains -TimeoutSec $TimeoutSec -Samples $Samples -CheckTls:$CheckTls -ConfigPath $ConfigPath
        $rawReports.Add($report)
    }

    $sorted = @($rawReports.ToArray() | Sort-Object -Property @(
        @{ Expression = { switch ($_.Status) { 'HEALTHY' { 0 } 'DEGRADED' { 1 } default { 2 } } }; Ascending = $true },
        @{ Expression = { $_.BlockedCount }; Ascending = $true },
        @{ Expression = { $_.ErrorCount }; Ascending = $true },
        @{ Expression = { $_.PassedCount }; Descending = $true },
        @{ Expression = { if ($null -eq $_.LatencyMedianMs) { [double]::MaxValue } else { [double]$_.LatencyMedianMs } }; Ascending = $true }
    ))

    $ranked = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        $r = $sorted[$i]
        $ranked.Add([pscustomobject]@{
            Rank            = ($i + 1)
            ProfileId       = $r.ProfileId
            ProfileName     = $r.ProfileName
            Category        = $r.Category
            Status          = $r.Status
            TestedIp        = $r.TestedIp
            Passed          = "$($r.PassedCount)/$($r.TotalDomains)"
            PassedCount     = $r.PassedCount
            TotalDomains    = $r.TotalDomains
            BlockedCount    = $r.BlockedCount
            ErrorCount      = $r.ErrorCount
            ProxiedCount    = $r.ProxiedCount
            LatencyMinMs    = $r.LatencyMinMs
            LatencyMedianMs = $r.LatencyMedianMs
            LatencyMaxMs    = $r.LatencyMaxMs
            TlsAllPassed    = $r.TlsAllPassed
            Details         = $r
        })
    }

    return $ranked.ToArray()
}

$script:DohBatchCSharpSource = @'
using System;
using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Threading.Tasks;

namespace DnsSwitcherNet {
    public class DohBatchItem {
        public int Index { get; set; }
        public int StatusCode { get; set; }
        public string HttpVersion { get; set; }
        public double RttMs { get; set; }
        public byte[] ResponseBytes { get; set; }
        public string Error { get; set; }
    }

    public static class DohBatchProbe {
        private static async Task<DohBatchItem> QueryOneAsync(
            int index,
            string dohUrl,
            string serverIp,
            byte[] dnsWireQuery,
            bool requireHttp2,
            int timeoutMs)
        {
            var item = new DohBatchItem {
                Index = index,
                StatusCode = 0,
                HttpVersion = "",
                RttMs = 0.0,
                ResponseBytes = Array.Empty<byte>(),
                Error = ""
            };
            var sw = Stopwatch.StartNew();
            try {
                var uri = new Uri(dohUrl);
                IPAddress pinnedIp = null;
                if (!string.IsNullOrEmpty(serverIp)) {
                    pinnedIp = IPAddress.Parse(serverIp);
                }

                using (var handler = new SocketsHttpHandler()) {
                    handler.PooledConnectionLifetime = TimeSpan.FromSeconds(1);
                    handler.AllowAutoRedirect = false;
                    if (pinnedIp != null) {
                        handler.ConnectCallback = async (context, cancellationToken) => {
                            var socket = new Socket(pinnedIp.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
                            socket.NoDelay = true;
                            try {
                                await socket.ConnectAsync(new IPEndPoint(pinnedIp, context.DnsEndPoint.Port), cancellationToken).ConfigureAwait(false);
                                return new NetworkStream(socket, true);
                            } catch {
                                socket.Dispose();
                                throw;
                            }
                        };
                    }

                    using (var client = new HttpClient(handler)) {
                        client.Timeout = TimeSpan.FromMilliseconds(timeoutMs);
                        using (var req = new HttpRequestMessage(HttpMethod.Post, uri)) {
                            req.Version = new Version(2, 0);
                            req.VersionPolicy = requireHttp2 ? HttpVersionPolicy.RequestVersionExact : HttpVersionPolicy.RequestVersionOrLower;
                            req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/dns-message"));
                            var content = new ByteArrayContent(dnsWireQuery);
                            content.Headers.ContentType = new MediaTypeHeaderValue("application/dns-message");
                            req.Content = content;

                            using (var resp = await client.SendAsync(req).ConfigureAwait(false)) {
                                item.StatusCode = (int)resp.StatusCode;
                                item.HttpVersion = resp.Version.ToString();
                                item.ResponseBytes = await resp.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
                            }
                        }
                    }
                }
                sw.Stop();
                item.RttMs = Math.Round(sw.Elapsed.TotalMilliseconds, 2);
            } catch (Exception ex) {
                sw.Stop();
                item.RttMs = Math.Round(sw.Elapsed.TotalMilliseconds, 2);
                item.Error = ex.GetBaseException().Message;
            }
            return item;
        }

        public static DohBatchItem[] RunBatch(
            string[] dohUrls,
            string[] serverIps,
            byte[][] wireQueries,
            bool[] requireHttp2Flags,
            int timeoutMs)
        {
            int count = dohUrls.Length;
            var tasks = new Task<DohBatchItem>[count];
            for (int i = 0; i < count; i++) {
                tasks[i] = QueryOneAsync(i, dohUrls[i], serverIps[i], wireQueries[i], requireHttp2Flags[i], timeoutMs);
            }
            return Task.WhenAll(tasks).GetAwaiter().GetResult();
        }
    }
}
'@

function Ensure-DohBatchType {
    [CmdletBinding()]
    param()
    if (-not ('DnsSwitcherNet.DohBatchProbe' -as [type])) {
        Add-Type -TypeDefinition $script:DohBatchCSharpSource -Language CSharp -ErrorAction Stop
    }
}

function Invoke-DohBatchProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Tasks,
        [int]$TimeoutSec = 3
    )

    $count = $Tasks.Count
    if ($count -eq 0) {
        return @()
    }

    $timeoutMs = [math]::Max(500, $TimeoutSec * 1000)

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        Ensure-DohBatchType
        $urls = New-Object string[] $count
        $ips = New-Object string[] $count
        $wires = New-Object 'byte[][]' $count
        $h2Flags = New-Object bool[] $count
        for ($i = 0; $i -lt $count; $i++) {
            $urls[$i] = [string]$Tasks[$i].DohTemplate
            $ips[$i] = [string]$Tasks[$i].ServerIp
            $wires[$i] = [byte[]]$Tasks[$i].WireBytes
            $h2Flags[$i] = [bool]$Tasks[$i].RequireHttp2
        }
        $rawItems = [DnsSwitcherNet.DohBatchProbe]::RunBatch($urls, $ips, $wires, $h2Flags, $timeoutMs)
        $out = New-Object object[] $count
        foreach ($it in $rawItems) {
            $out[$it.Index] = [pscustomobject]@{
                Index         = $it.Index
                StatusCode    = $it.StatusCode
                HttpVersion   = $it.HttpVersion
                RttMs         = $it.RttMs
                ResponseBytes = $it.ResponseBytes
                Error         = $it.Error
            }
        }
        return $out
    }

    $pwshPath = Find-PwshExecutablePath
    if (-not [string]::IsNullOrWhiteSpace($pwshPath)) {
        $tmpPayload = Join-Path ([System.IO.Path]::GetTempPath()) ("doh_batch_" + [Guid]::NewGuid().ToString('N') + ".json")
        try {
            $payloadItems = New-Object System.Collections.Generic.List[object]
            for ($i = 0; $i -lt $count; $i++) {
                $payloadItems.Add([pscustomobject]@{
                    url  = [string]$Tasks[$i].DohTemplate
                    ip   = [string]$Tasks[$i].ServerIp
                    qB64 = [Convert]::ToBase64String([byte[]]$Tasks[$i].WireBytes)
                    h2   = [bool]$Tasks[$i].RequireHttp2
                })
            }
            $payloadObj = [pscustomobject]@{
                timeoutMs = $timeoutMs
                items     = $payloadItems.ToArray()
            }
            [System.IO.File]::WriteAllText($tmpPayload, ($payloadObj | ConvertTo-Json -Depth 4 -Compress), [System.Text.Encoding]::UTF8)

            $csLiteral = $script:DohBatchCSharpSource.Replace("'", "''")
            $escPath = $tmpPayload.Replace("'", "''")
            $bridgeScript = @"
`$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition '$csLiteral' -Language CSharp
`$raw = [System.IO.File]::ReadAllText('$escPath', [System.Text.Encoding]::UTF8) | ConvertFrom-Json
`$items = @(`$raw.items)
`$n = `$items.Count
`$urls = New-Object string[] `$n
`$ips = New-Object string[] `$n
`$wires = New-Object 'byte[][]' `$n
`$h2s = New-Object bool[] `$n
for (`$i = 0; `$i -lt `$n; `$i++) {
    `$urls[`$i] = [string]`$items[`$i].url
    `$ips[`$i] = [string]`$items[`$i].ip
    `$wires[`$i] = [Convert]::FromBase64String([string]`$items[`$i].qB64)
    `$h2s[`$i] = [bool]`$items[`$i].h2
}
`$res = [DnsSwitcherNet.DohBatchProbe]::RunBatch(`$urls, `$ips, `$wires, `$h2s, [int]`$raw.timeoutMs)
`$out = foreach (`$r in `$res) {
    [pscustomobject]@{
        index       = `$r.Index
        statusCode  = `$r.StatusCode
        httpVersion = `$r.HttpVersion
        rttMs       = `$r.RttMs
        bodyB64     = if (`$r.ResponseBytes -and `$r.ResponseBytes.Length -gt 0) { [Convert]::ToBase64String(`$r.ResponseBytes) } else { '' }
        error       = `$r.Error
    }
}
Write-Output ('__BATCHOUT__' + (@{ items = @(`$out) } | ConvertTo-Json -Depth 4 -Compress))
"@
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($bridgeScript))
            $stdoutLines = @(& $pwshPath -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1)
            $marker = $stdoutLines | Where-Object { [string]$_ -like '__BATCHOUT__*' } | Select-Object -Last 1
            if ($null -ne $marker) {
                $parsedObj = ([string]$marker).Substring(12) | ConvertFrom-Json
                $parsed = @($parsedObj.items)
                $out = New-Object object[] $count
                foreach ($pItem in $parsed) {
                    $idx = [int]$pItem.index
                    $respBytes = if (-not [string]::IsNullOrWhiteSpace([string]$pItem.bodyB64)) {
                        [Convert]::FromBase64String([string]$pItem.bodyB64)
                    } else {
                        [byte[]]@()
                    }
                    $out[$idx] = [pscustomobject]@{
                        Index         = $idx
                        StatusCode    = [int]$pItem.statusCode
                        HttpVersion   = [string]$pItem.httpVersion
                        RttMs         = [double]$pItem.rttMs
                        ResponseBytes = $respBytes
                        Error         = [string]$pItem.error
                    }
                }
                return $out
            }
        } finally {
            if (Test-Path -LiteralPath $tmpPayload) { Remove-Item -LiteralPath $tmpPayload -Force -ErrorAction SilentlyContinue }
        }
    }

    # Fallback for PS 5.1 without pwsh.exe: parallel RunspacePool using curl.exe / HttpClient
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, [math]::Min(12, $count))
    $pool.Open()
    $handles = New-Object System.Collections.Generic.List[object]
    $modulePath = $PSCommandPath
    try {
        for ($i = 0; $i -lt $count; $i++) {
            $t = $Tasks[$i]
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript({
                param($modPath, $idx, $url, $ip, $wire, $tSec)
                Import-Module $modPath -ErrorAction Stop
                $r = Invoke-DohViaCurlOrDotNet -DohTemplate $url -ServerIp $ip -WireBytes $wire -TimeoutSec $tSec -Method 'POST'
                return [pscustomobject]@{
                    Index         = $idx
                    StatusCode    = $r.StatusCode
                    HttpVersion   = $r.HttpVersion
                    RttMs         = $r.RttMs
                    ResponseBytes = $r.ResponseBytes
                    Error         = $r.Error
                }
            }).AddArgument($modulePath).AddArgument($i).AddArgument([string]$t.DohTemplate).AddArgument([string]$t.ServerIp).AddArgument([byte[]]$t.WireBytes).AddArgument($TimeoutSec)
            $handles.Add([pscustomobject]@{ Pipe = $ps; Async = $ps.BeginInvoke() })
        }

        $out = New-Object object[] $count
        foreach ($h in $handles) {
            try {
                $res = $h.Pipe.EndInvoke($h.Async) | Select-Object -First 1
                if ($null -ne $res) {
                    $out[[int]$res.Index] = $res
                }
            } finally {
                $h.Pipe.Dispose()
            }
        }
        return $out
    } finally {
        $pool.Close()
        $pool.Dispose()
    }
}

function Get-LiveDnsAvailability {
    <#
    .SYNOPSIS
        Probes all configured DNS profiles in parallel against key Antigravity/Google domains and ranks top 3 recommendations.
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [int]$TimeoutSec = 3
    )

    $totalSw = [System.Diagnostics.Stopwatch]::StartNew()
    $vpnState = Get-VpnTunnelState
    $vpnActive = [bool]$vpnState.IsActive
    $config = Get-DnsProfilesConfig -ConfigPath $ConfigPath
    $profiles = @($config.profiles)

    $keyDomains = @('cloudcode-pa.googleapis.com', 'daily-cloudcode-pa.googleapis.com', 'antigravity.google')
    $wireMap = @{}
    foreach ($kd in $keyDomains) {
        $wireMap[$kd] = New-DnsWireQuery -Domain $kd -RecordType 1
    }

    $tasks = New-Object System.Collections.Generic.List[object]
    for ($pIdx = 0; $pIdx -lt $profiles.Count; $pIdx++) {
        $prof = $profiles[$pIdx]
        $dohIps = @($prof.doh_ips | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $targetIp = if ($dohIps.Count -gt 0) { [string]$dohIps[0] } else { [string]@($prof.ipv4)[0] }
        $reqH2 = [bool]$prof.requires_http2
        $tmpl = [string]$prof.doh_template
        foreach ($kd in $keyDomains) {
            $tasks.Add([pscustomobject]@{
                ProfileIndex = $pIdx
                Domain       = $kd
                DohTemplate  = $tmpl
                ServerIp     = $targetIp
                WireBytes    = [byte[]]$wireMap[$kd]
                RequireHttp2 = $reqH2
            })
        }
    }

    $rawBatch = @(Invoke-DohBatchProbe -Tasks $tasks.ToArray() -TimeoutSec $TimeoutSec)

    $perProfileItems = @{}
    for ($pIdx = 0; $pIdx -lt $profiles.Count; $pIdx++) {
        $perProfileItems[$pIdx] = New-Object System.Collections.Generic.List[object]
    }
    for ($tIdx = 0; $tIdx -lt $tasks.Count; $tIdx++) {
        $task = $tasks[$tIdx]
        $raw = $rawBatch[$tIdx]
        $perProfileItems[$task.ProfileIndex].Add([pscustomobject]@{
            Domain = $task.Domain
            Raw    = $raw
        })
    }

    $records = New-Object System.Collections.Generic.List[object]
    for ($pIdx = 0; $pIdx -lt $profiles.Count; $pIdx++) {
        $prof = $profiles[$pIdx]
        $items = $perProfileItems[$pIdx]
        $passedCount = 0
        $proxiedCount = 0
        $antigravityOk = $false
        $rtts = New-Object System.Collections.Generic.List[double]
        $errs = New-Object System.Collections.Generic.List[string]

        foreach ($entry in $items) {
            $dom = [string]$entry.Domain
            $raw = $entry.Raw
            $parsedDns = $null
            $parseErr = ''
            if ($null -ne $raw -and $raw.StatusCode -eq 200 -and $null -ne $raw.ResponseBytes -and $raw.ResponseBytes.Length -ge 12) {
                try {
                    $parsedDns = Read-DnsWireResponse -Bytes $raw.ResponseBytes
                } catch {
                    $parseErr = "DNS wire parse error: $($_.Exception.Message)"
                }
            }

            $finalErr = if ($null -eq $raw) { 'No response' } else { [string]$raw.Error }
            if ([string]::IsNullOrWhiteSpace($finalErr) -and -not [string]::IsNullOrWhiteSpace($parseErr)) {
                $finalErr = $parseErr
            } elseif ([string]::IsNullOrWhiteSpace($finalErr) -and $null -ne $raw -and $raw.StatusCode -ne 200) {
                $finalErr = "DoH returned HTTP $($raw.StatusCode)."
            }

            $dnsSuccess = ($null -ne $raw -and $raw.StatusCode -eq 200 -and $null -ne $parsedDns -and $parsedDns.Success)
            if ($null -ne $raw -and $raw.StatusCode -eq 200 -and $null -ne $parsedDns -and -not $parsedDns.Success -and [string]::IsNullOrWhiteSpace($finalErr)) {
                $finalErr = "DNS RCODE $($parsedDns.RCode) ($($parsedDns.RCodeName))"
            }

            $dohRes = [pscustomobject]@{
                Success  = $dnsSuccess
                Domain   = $dom
                ARecords = if ($null -ne $parsedDns) { @($parsedDns.ARecords) } else { @() }
                CNames   = if ($null -ne $parsedDns) { @($parsedDns.CNames) } else { @() }
                Error    = $finalErr
            }
            $cls = Get-DomainAnswerClassification -DohResult $dohRes -Profile $prof
            $ok = ($cls -eq 'CLEAN_GOOGLE' -or $cls -eq 'SMART_PROXY')
            if ($ok) {
                $passedCount++
                if ($cls -eq 'SMART_PROXY') { $proxiedCount++ }
                if ($dom -eq 'antigravity.google') { $antigravityOk = $true }
                if ($null -ne $raw) { $rtts.Add([double]$raw.RttMs) }
            } else {
                $errMsg = if (-not [string]::IsNullOrWhiteSpace($finalErr)) { $finalErr } else { $cls }
                $errs.Add(("{0}: {1}" -f $dom, $errMsg))
            }
        }

        $totalDomains = $keyDomains.Count
        $status = if ($passedCount -eq $totalDomains) {
            'ONLINE'
        } elseif ($passedCount -gt 0) {
            'DEGRADED'
        } else {
            'OFFLINE'
        }
        $available = ($passedCount -gt 0)
        $latStats = Get-NumericStats -Values $rtts.ToArray()
        $smartDomains = @($prof.smart_proxy_domains | ForEach-Object { ([string]$_).ToLowerInvariant() })
        $trustMode = if ([string]$prof.category -eq 'rf-smart' -or $smartDomains.Count -gt 0) { 'sni-proxy' } else { 'pure' }

        # Priority tier for current VPN state (used to pick RecommendedIds)
        $cat = [string]$prof.category
        $stateTier = if ($vpnActive) {
            switch ($cat) {
                'vpn-clean' { 0 }
                'rf-clean'  { 1 }
                default     { 2 }
            }
        } else {
            if ($cat -eq 'rf-smart') {
                $hasDaily = ($smartDomains -contains 'daily-cloudcode-pa.googleapis.com')
                $hasAg = ($smartDomains -contains 'antigravity.google')
                if ($hasDaily -and $hasAg) { 0 } elseif ($hasDaily -or $hasAg) { 1 } else { 2 }
            } elseif ($cat -eq 'rf-clean') {
                3
            } else {
                4
            }
        }

        $records.Add([pscustomobject]@{
            ProfileId     = [string]$prof.id
            Name          = [string]$prof.name
            Category      = $cat
            IPv4          = @($prof.ipv4 | ForEach-Object { [string]$_ })
            DohTemplate   = [string]$prof.doh_template
            RequiresHttp2 = [bool]$prof.requires_http2
            Available     = $available
            Status        = $status
            LatencyMs     = $latStats.Median
            PassedDomains = [int]$passedCount
            TotalDomains  = [int]$totalDomains
            AntigravityOk = $antigravityOk
            ProxiedCount  = [int]$proxiedCount
            TrustMode     = $trustMode
            StateTier     = [int]$stateTier
            Error         = ($errs.ToArray() -join '; ')
        })
    }

    $availableSorted = @($records.ToArray() | Where-Object { $_.Available } | Sort-Object -Property @(
        @{ Expression = { if ($_.Status -eq 'ONLINE') { 0 } else { 1 } }; Ascending = $true },
        @{ Expression = { $_.StateTier }; Ascending = $true },
        @{ Expression = { $_.PassedDomains }; Descending = $true },
        @{ Expression = { if ($null -eq $_.LatencyMs) { [double]::MaxValue } else { [double]$_.LatencyMs } }; Ascending = $true }
    ))

    $recMap = @{}
    $recIds = New-Object System.Collections.Generic.List[string]
    $maxRec = [math]::Min(3, $availableSorted.Count)
    for ($r = 0; $r -lt $maxRec; $r++) {
        $pidStr = [string]$availableSorted[$r].ProfileId
        $recMap[$pidStr] = ($r + 1)
        $recIds.Add($pidStr)
    }

    $finalUnsorted = New-Object System.Collections.Generic.List[object]
    foreach ($rec in $records) {
        $rank = if ($recMap.ContainsKey($rec.ProfileId)) { [int]$recMap[$rec.ProfileId] } else { 0 }
        $finalUnsorted.Add([pscustomobject]@{
            ProfileId     = $rec.ProfileId
            Name          = $rec.Name
            Category      = $rec.Category
            IPv4          = $rec.IPv4
            DohTemplate   = $rec.DohTemplate
            RequiresHttp2 = $rec.RequiresHttp2
            Available     = $rec.Available
            Status        = $rec.Status
            LatencyMs     = $rec.LatencyMs
            PassedDomains = $rec.PassedDomains
            TotalDomains  = $rec.TotalDomains
            AntigravityOk = $rec.AntigravityOk
            ProxiedCount  = $rec.ProxiedCount
            TrustMode     = $rec.TrustMode
            IsRecommended = ($rank -gt 0)
            RecommendRank = $rank
            Error         = $rec.Error
            _SortTier     = $rec.StateTier
        })
    }

    $finalSorted = @($finalUnsorted.ToArray() | Sort-Object -Property @(
        @{ Expression = { if ($_.Available) { 0 } else { 1 } }; Ascending = $true },
        @{ Expression = { if ($_.Status -eq 'ONLINE') { 0 } elseif ($_.Status -eq 'DEGRADED') { 1 } else { 2 } }; Ascending = $true },
        @{ Expression = { if ($_.RecommendRank -gt 0) { $_.RecommendRank } else { 999 } }; Ascending = $true },
        @{ Expression = { $_._SortTier }; Ascending = $true },
        @{ Expression = { if ($null -eq $_.LatencyMs) { [double]::MaxValue } else { [double]$_.LatencyMs } }; Ascending = $true }
    ) | ForEach-Object {
        [pscustomobject]@{
            ProfileId     = $_.ProfileId
            Name          = $_.Name
            Category      = $_.Category
            IPv4          = $_.IPv4
            DohTemplate   = $_.DohTemplate
            RequiresHttp2 = $_.RequiresHttp2
            Available     = $_.Available
            Status        = $_.Status
            LatencyMs     = $_.LatencyMs
            PassedDomains = $_.PassedDomains
            TotalDomains  = $_.TotalDomains
            AntigravityOk = $_.AntigravityOk
            ProxiedCount  = $_.ProxiedCount
            TrustMode     = $_.TrustMode
            IsRecommended = $_.IsRecommended
            RecommendRank = $_.RecommendRank
            Error         = $_.Error
        }
    })

    $totalSw.Stop()

    return [pscustomobject]@{
        CheckedAt      = (Get-Date).ToString('o')
        VpnActive      = $vpnActive
        DurationMs     = [math]::Round($totalSw.Elapsed.TotalMilliseconds, 2)
        RecommendedIds = [string[]]$recIds.ToArray()
        Results        = $finalSorted
    }
}

Export-ModuleMember -Function @(
    'New-DnsWireQuery',
    'Read-DnsWireResponse',
    'Invoke-DohQuery',
    'Test-TlsEndpoint',
    'Test-ProfileHealth',
    'Invoke-ProfileBenchmark',
    'Get-LiveDnsAvailability'
)
