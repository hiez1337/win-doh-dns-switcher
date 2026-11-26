Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'TestHarness.ps1')

$projectRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $projectRoot 'config\profiles.json'
$schemaPath = Join-Path $projectRoot 'config\profiles.schema.json'

$state = New-TestSuiteState -SuiteName 'unit-config'
Write-Host ("Running {0} on PowerShell {1}..." -f $state.SuiteName, $PSVersionTable.PSVersion.ToString())

$ipv4Regex = '^((25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(25[0-5]|2[0-4]\d|[01]?\d\d?)$'
$domainRegex = '^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$'
$requiredRetiredIps = @(
    '111.88.96.54',
    '194.242.2.2',
    '92.38.153.185',
    '83.220.169.155',
    '127.0.0.53',
    '159.194.200.33'
)

$script:ParsedConfig = $null

Invoke-TestCase -State $state -Name 'Config and schema files exist and are pure ASCII' {
    Assert-True (Test-Path -LiteralPath $configPath -PathType Leaf) "Missing $configPath"
    Assert-True (Test-Path -LiteralPath $schemaPath -PathType Leaf) "Missing $schemaPath"

    $cfgAscii = Test-FilePureAscii -Path $configPath
    Assert-True $cfgAscii.IsPureAscii "profiles.json contains non-ASCII byte $($cfgAscii.FirstBadByteValue) at offset $($cfgAscii.FirstBadByteOffset)"

    $schAscii = Test-FilePureAscii -Path $schemaPath
    Assert-True $schAscii.IsPureAscii "profiles.schema.json contains non-ASCII byte $($schAscii.FirstBadByteValue) at offset $($schAscii.FirstBadByteOffset)"
}

Invoke-TestCase -State $state -Name 'profiles.json and profiles.schema.json parse cleanly as JSON' {
    $rawCfg = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
    $script:ParsedConfig = $rawCfg | ConvertFrom-Json -ErrorAction Stop
    Assert-NotNull $script:ParsedConfig 'Parsed profiles.json is null'

    $rawSch = [System.IO.File]::ReadAllText($schemaPath, [System.Text.Encoding]::UTF8)
    $sch = $rawSch | ConvertFrom-Json -ErrorAction Stop
    Assert-NotNull $sch 'Parsed profiles.schema.json is null'
    Assert-Equal 'http://json-schema.org/draft-07/schema#' ([string]$sch.'$schema') 'Expected Draft-07 $schema'
}

Invoke-TestCase -State $state -Name 'Top-level structure and metadata match schema' {
    $cfg = $script:ParsedConfig
    $expectedTop = @('schema_version', 'generated_at', 'environment_notes', 'deprecated_or_blocked', 'test_domains', 'profiles')
    $actualTop = @($cfg.PSObject.Properties | ForEach-Object { $_.Name })

    foreach ($k in $expectedTop) {
        Assert-Contains $actualTop $k "Missing top-level key '$k'"
    }
    foreach ($k in $actualTop) {
        Assert-Contains $expectedTop $k "Unexpected extra top-level key '$k'"
    }

    Assert-True ([int]$cfg.schema_version -ge 1) 'schema_version must be >= 1'
    Assert-Match '^\d{4}-\d{2}-\d{2}$' ([string]$cfg.generated_at) 'generated_at must match YYYY-MM-DD'
    Assert-False ([string]::IsNullOrWhiteSpace([string]$cfg.environment_notes)) 'environment_notes must be non-empty'
}

Invoke-TestCase -State $state -Name 'test_domains contains all 4 required domain groups and 16 valid domains' {
    $td = $script:ParsedConfig.test_domains
    $expectedGroups = @('antigravity_core', 'google_auth', 'ai_inference', 'ecosystem')
    $actualGroups = @($td.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($g in $expectedGroups) {
        Assert-Contains $actualGroups $g "Missing test_domains group '$g'"
    }
    foreach ($g in $actualGroups) {
        Assert-Contains $expectedGroups $g "Unexpected test_domains group '$g'"
    }

    $allDomains = New-Object System.Collections.Generic.List[string]
    foreach ($g in $expectedGroups) {
        $items = @($td.$g)
        Assert-GreaterThan $items.Count 0 "Group '$g' must not be empty"
        foreach ($d in $items) {
            $ds = [string]$d
            Assert-Match $domainRegex $ds "Invalid test domain '$ds'"
            Assert-NotContains $allDomains.ToArray() $ds "Duplicate test domain '$ds'"
            $allDomains.Add($ds)
        }
    }

    Assert-Equal 16 $allDomains.Count 'Expected 16 unique test_domains'
    Assert-Contains $allDomains.ToArray() 'cloudcode-pa.googleapis.com'
    Assert-Contains $allDomains.ToArray() 'accounts.google.com'
    Assert-Contains $allDomains.ToArray() 'generativelanguage.googleapis.com'
    Assert-Contains $allDomains.ToArray() 'antigravity.google'
}

Invoke-TestCase -State $state -Name 'deprecated_or_blocked is populated and covers all retired/blocked IPs' {
    $dep = @($script:ParsedConfig.deprecated_or_blocked)
    Assert-GreaterThan $dep.Count 10 'deprecated_or_blocked should list known retired/blocked resolvers'

    $depIps = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $dep) {
        $props = @($entry.PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($req in @('ip', 'provider', 'reason')) {
            Assert-Contains $props $req "deprecated_or_blocked entry missing '$req'"
        }
        foreach ($p in $props) {
            Assert-Contains @('ip', 'provider', 'reason') $p "Unexpected field '$p' in deprecated_or_blocked"
        }
        $ip = [string]$entry.ip
        Assert-Match $ipv4Regex $ip "Invalid IPv4 '$ip' in deprecated_or_blocked"
        Assert-False ([string]::IsNullOrWhiteSpace([string]$entry.provider)) "Empty provider for $ip"
        Assert-False ([string]::IsNullOrWhiteSpace([string]$entry.reason)) "Empty reason for $ip"
        $depIps.Add($ip)
    }

    foreach ($reqIp in $requiredRetiredIps) {
        Assert-Contains $depIps.ToArray() $reqIp "deprecated_or_blocked missing required retired/blocked IP '$reqIp'"
    }
}

Invoke-TestCase -State $state -Name 'All 12 profiles exist with expected IDs and categories' {
    $profiles = @($script:ParsedConfig.profiles)
    Assert-Equal 12 $profiles.Count 'Expected exactly 12 profiles in profiles.json'

    $ids = @($profiles | ForEach-Object { [string]$_.id })
    $uniqueIds = @($ids | Select-Object -Unique)
    Assert-Equal $profiles.Count $uniqueIds.Count 'Duplicate profile IDs found'

    $expectedVpnClean = @('cloudflare', 'google', 'controld-p0', 'controld-p2', 'quad9', 'adguard-unfiltered', 'dns-sb')
    $expectedRfSmart = @('geohide', 'dns-ai', 'comss', 'malw')
    $expectedRfClean = @('yandex')

    foreach ($id in $expectedVpnClean) {
        $p = $profiles | Where-Object { $_.id -eq $id } | Select-Object -First 1
        Assert-NotNull $p "Missing vpn-clean profile '$id'"
        Assert-Equal 'vpn-clean' ([string]$p.category) "Profile '$id' category mismatch"
    }
    foreach ($id in $expectedRfSmart) {
        $p = $profiles | Where-Object { $_.id -eq $id } | Select-Object -First 1
        Assert-NotNull $p "Missing rf-smart profile '$id'"
        Assert-Equal 'rf-smart' ([string]$p.category) "Profile '$id' category mismatch"
    }
    foreach ($id in $expectedRfClean) {
        $p = $profiles | Where-Object { $_.id -eq $id } | Select-Object -First 1
        Assert-NotNull $p "Missing rf-clean profile '$id'"
        Assert-Equal 'rf-clean' ([string]$p.category) "Profile '$id' category mismatch"
    }
}

Invoke-TestCase -State $state -Name 'Every profile satisfies required fields, types, IPv4, and HTTPS DoH URL checks' {
    $requiredFields = @(
        'id', 'name', 'category', 'recommended_for', 'ipv4', 'doh_template',
        'doh_ips', 'dot_host', 'requires_http2', 'default_allow_udp_fallback',
        'auto_upgrade_doh', 'smart_proxy_domains', 'trust_note', 'notes'
    )

    foreach ($p in @($script:ParsedConfig.profiles)) {
        $pidStr = [string]$p.id
        $actualFields = @($p.PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($rf in $requiredFields) {
            Assert-Contains $actualFields $rf "Profile '$pidStr' missing required field '$rf'"
        }
        foreach ($af in $actualFields) {
            Assert-Contains $requiredFields $af "Profile '$pidStr' has unexpected extra field '$af'"
        }

        Assert-Match '^[a-z0-9-]+$' $pidStr "Invalid profile id '$pidStr'"
        Assert-False ([string]::IsNullOrWhiteSpace([string]$p.name)) "Profile '$pidStr' empty name"
        Assert-Contains @('vpn-clean', 'rf-smart', 'rf-clean') ([string]$p.category) "Profile '$pidStr' invalid category"

        $recFor = @($p.recommended_for)
        Assert-GreaterThan $recFor.Count 0 "Profile '$pidStr' recommended_for empty"
        foreach ($tag in $recFor) {
            Assert-Contains @('vpn-on', 'vpn-off') ([string]$tag) "Profile '$pidStr' invalid recommended_for '$tag'"
        }

        $ipv4 = @($p.ipv4)
        Assert-GreaterThan $ipv4.Count 0 "Profile '$pidStr' ipv4 empty"
        Assert-Equal $ipv4.Count (@($ipv4 | Select-Object -Unique)).Count "Profile '$pidStr' duplicate ipv4 entries"
        foreach ($ip in $ipv4) {
            Assert-Match $ipv4Regex ([string]$ip) "Profile '$pidStr' invalid IPv4 '$ip'"
        }

        $dohIps = @($p.doh_ips)
        Assert-GreaterThan $dohIps.Count 0 "Profile '$pidStr' doh_ips empty"
        Assert-Equal $dohIps.Count (@($dohIps | Select-Object -Unique)).Count "Profile '$pidStr' duplicate doh_ips entries"
        foreach ($ip in $dohIps) {
            Assert-Match $ipv4Regex ([string]$ip) "Profile '$pidStr' invalid doh_ip '$ip'"
        }

        $dohUrl = [string]$p.doh_template
        Assert-Match '^https://[^\s/]+/.*' $dohUrl "Profile '$pidStr' invalid doh_template '$dohUrl'"
        $parsedUri = $null
        Assert-True ([System.Uri]::TryCreate($dohUrl, [System.UriKind]::Absolute, [ref]$parsedUri)) "Profile '$pidStr' URI parse failed"
        Assert-Equal 'https' $parsedUri.Scheme "Profile '$pidStr' DoH scheme must be https"
        Assert-False ([string]::IsNullOrWhiteSpace($parsedUri.Host)) "Profile '$pidStr' DoH URI missing host"

        Assert-Match $domainRegex ([string]$p.dot_host) "Profile '$pidStr' invalid dot_host '$($p.dot_host)'"

        foreach ($bf in @('requires_http2', 'default_allow_udp_fallback', 'auto_upgrade_doh')) {
            Assert-True ($p.$bf -is [bool]) "Profile '$pidStr' field '$bf' must be boolean"
        }

        $smart = @($p.smart_proxy_domains)
        if ([string]$p.category -eq 'rf-smart') {
            Assert-GreaterThan $smart.Count 0 "rf-smart profile '$pidStr' must list smart_proxy_domains"
            foreach ($sd in $smart) {
                Assert-Match $domainRegex ([string]$sd) "Profile '$pidStr' invalid smart_proxy_domain '$sd'"
            }
        } else {
            Assert-Equal 0 $smart.Count "Non-rf-smart profile '$pidStr' must have empty smart_proxy_domains"
        }

        Assert-False ([string]::IsNullOrWhiteSpace([string]$p.trust_note)) "Profile '$pidStr' empty trust_note"
        Assert-False ([string]::IsNullOrWhiteSpace([string]$p.notes)) "Profile '$pidStr' empty notes"
    }
}

Invoke-TestCase -State $state -Name 'requires_http2 flags set on quad9, malw, yandex, dns-ai and Yandex DoH URL verified' {
    $profilesById = @{}
    foreach ($p in @($script:ParsedConfig.profiles)) {
        $profilesById[[string]$p.id] = $p
    }

    foreach ($h2Id in @('quad9', 'malw', 'yandex', 'dns-ai')) {
        Assert-True ($profilesById.ContainsKey($h2Id)) "Missing profile '$h2Id'"
        Assert-True ([bool]$profilesById[$h2Id].requires_http2) "Expected requires_http2 = true on '$h2Id'"
    }

    Assert-Equal 'https://common.dot.dns.yandex.net/dns-query' ([string]$profilesById['yandex'].doh_template) 'Yandex doh_template must be common.dot.dns.yandex.net'
}

Invoke-TestCase -State $state -Name 'Zero retired/blocked IPs present in active profile ipv4 or doh_ips' {
    $allDeprecated = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ip in $requiredRetiredIps) {
        [void]$allDeprecated.Add($ip)
    }
    foreach ($entry in @($script:ParsedConfig.deprecated_or_blocked)) {
        [void]$allDeprecated.Add([string]$entry.ip)
    }

    foreach ($p in @($script:ParsedConfig.profiles)) {
        $pidStr = [string]$p.id
        foreach ($ip in @($p.ipv4)) {
            Assert-False ($allDeprecated.Contains([string]$ip)) "Profile '$pidStr' ipv4 contains deprecated/blocked IP '$ip'"
        }
        foreach ($ip in @($p.doh_ips)) {
            Assert-False ($allDeprecated.Contains([string]$ip)) "Profile '$pidStr' doh_ips contains deprecated/blocked IP '$ip'"
        }
    }
}

$exitCode = Complete-TestSuite -State $state
exit $exitCode
