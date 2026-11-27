**English** | [Русский](README.ru.md) · [Releases](https://github.com/hiez1337/win-doh-dns-switcher/releases)

# Windows 11 DNS & Native DoH Switcher (`dns_switcher`)

[![GitHub Release](https://img.shields.io/github/v/release/hiez1337/win-doh-dns-switcher)](https://github.com/hiez1337/win-doh-dns-switcher/releases/latest)
[![Platform: Windows 11](https://img.shields.io/badge/Platform-Windows%2011-0078D4?logo=windows11&logoColor=white)](https://www.microsoft.com/windows/windows-11)
[![PowerShell: 5.1 & 7+](https://img.shields.io/badge/PowerShell-5.1%20%26%207%2B-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![UI: Python Rich TUI](https://img.shields.io/badge/UI-Python%20Rich%20TUI-3776AB?logo=python&logoColor=white)](ui/rich_ui.py)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A zero-daemon PowerShell + Windows 11 native DNS-over-HTTPS (DoH) switcher and live resolver diagnostic toolkit designed for reliable access to Antigravity, Google AI (`gemini.google.com`, `aistudio.google.com`, `generativelanguage.googleapis.com`), and Google Auth — both **over any VPN** and **directly without a VPN**.

---

## Why This Tool Exists

- **Native Windows 11 IPv4 DoH (`dnscache` over HTTP/2)**: Configures OS-level IPv4 DoH templates via `DnsClient` (`Add-DnsClientDohServerAddress` / `Set-DnsClientDohServerAddress` with `netsh dns` fallback) without running third-party DNS forwarders or background services. Windows 11 `dnscache` speaks **HTTP/2**, which is required by resolvers such as `Quad9`, `DNS-AI`, `Malw`, and `Yandex.DNS` (they reject HTTP/1.1 with HTTP 505 or connection drops).
- **Live Availability Benchmarking Across 12 Curated Resolvers**: Runs parallel live DoH checks across `cloudcode-pa.googleapis.com`, `daily-cloudcode-pa.googleapis.com`, and `antigravity.google` (plus full 16-domain + strict TLS certificate validation in `probe`) and ranks the best resolvers for your current network state:
  - **`vpn-clean`** (7 profiles): Unfiltered public DoH resolvers for use over VPN or clean networks.
  - **`rf-smart`** (4 profiles): RF Smart-DNS resolvers for direct AI/Antigravity access without VPN.
  - **`rf-clean`** (1 profile): RF-domestic clean DoH (`Yandex.DNS Basic`) resistant to ISP throttling.
- **Automatic NRPT Conflict Cleanup**: Audits and safely removes stale Windows Name Resolution Policy Table (NRPT) rules — such as dead `127.0.0.53` forwarders (which add ~189–991 ms timeout delays), blocked Xbox DNS (`111.88.96.54–57`), or leftover overrides from prior DNS tools — while backing them up first.

---

## Universal VPN & Direct Support

- **Automatic VPN / Tunnel Detection**: Automatically detects active VPN/TUN/TAP adapters (`sing-tun`, `wintun`, `WireGuard`, `OpenVPN`, `TAP-Windows`, `utun`, `Amnezia`, `NekoRay`/`NekoBox`, `Hiddify`, `v2ray`/`xray`, `Clash`/`Mihomo`, `Outline`, `WARP`, `Proton`, `Tailscale`, `NordLynx`, `IKEv2`/`SSTP`/`L2TP`) as well as Windows RAS VPN connections (`Get-VpnConnection`).
- **Non-Intrusive by Design**: Never stops, disconnects, restarts, or modifies VPN services or routing tables.
- **Bypassing TUN Port-53 Hijacking**: Many TUN-based VPN clients intercept UDP/TCP port 53 (`hijack-dns`). Because native Windows DoH uses **TCP:443 (HTTPS)**, DNS queries bypass local port-53 hijacking and ISP DNS tampering cleanly.
- **Direct Mode (No VPN Installed or Active)**: When no VPN tunnel is active, `dns_switcher` targets your active Ethernet/Wi-Fi adapters cleanly with zero VPN warnings and prioritizes `rf-smart` / `rf-clean` profiles.

---

## Verified DNS Profiles

All 12 profiles, 16 benchmark domains, and 17 excluded IPs are stored declaratively in [config/profiles.json](config/profiles.json) and validated against [config/profiles.schema.json](config/profiles.schema.json).

### 1. `vpn-clean` — Unfiltered Public DoH (`AllowFallbackToUdp=false`)

Pure public resolvers without third-party AI SNI-proxy relays. Recommended when a VPN is active or on unrestricted networks.

| ID | Name | IPv4 | DoH Template | Notes |
| :--- | :--- | :--- | :--- | :--- |
| `cloudflare` | Cloudflare Unfiltered | `1.1.1.1`, `1.0.0.1` | `https://cloudflare-dns.com/dns-query` | **#1 for VPN ON**, 16/16 `CLEAN_GOOGLE` |
| `google` | Google Public DNS | `8.8.8.8`, `8.8.4.4` | `https://dns.google/dns-query` | **#2 for VPN ON**, 16/16 `CLEAN_GOOGLE` |
| `controld-p0` | Control D Free Unfiltered (p0) | `76.76.2.0`, `76.76.10.0` | `https://freedns.controld.com/p0` | **#3 for VPN ON**, no-logs, unfiltered |
| `controld-p2` | Control D Free Adblock (p2) | `76.76.2.2`, `76.76.10.2` | `https://freedns.controld.com/p2` | Ad & tracker blocking, 16/16 `CLEAN_GOOGLE` |
| `quad9` | Quad9 Secured | `9.9.9.9`, `149.112.112.112` | `https://dns.quad9.net/dns-query` | Malware blocking + DNSSEC; **requires HTTP/2** |
| `adguard-unfiltered` | AdGuard DNS Unfiltered | `94.140.14.140`, `94.140.14.141` | `https://unfiltered.adguard-dns.com/dns-query` | Privacy-focused, unfiltered backup |
| `dns-sb` | DNS.SB | `185.222.222.222`, `45.11.45.11` | `https://doh.dns.sb/dns-query` | Unfiltered overseas backup |

### 2. `rf-smart` — Smart-DNS for Direct AI Access Without VPN (`AllowFallbackToUdp=true`)

> [!IMPORTANT]
> **Third-Party SNI / CNAME-Proxy Privacy Caveat**: Smart-DNS resolvers return relay IP addresses (or CNAME pools) for selected AI/Antigravity domains and forward TLS traffic via SNI proxy. End-to-end TLS still validates authentic Google certificates (preventing payload MITM), **but the Smart-DNS operator observes your client IP and SNI hostnames and controls relay availability.** Use `vpn-clean` resolvers when privacy or zero-proxy routing is required.

| ID | Name | IPv4 | DoH Template | Proxied Domains (out of 16) & Notes |
| :--- | :--- | :--- | :--- | :--- |
| `geohide` | GeoHide Smart-DNS | `37.230.192.51`, `193.233.112.88` | `https://dns.geohide.ru/dns-query` | **8/16** (`antigravity.google`, `antigravity-pa`, `antigravity.googleapis.com`, `daily-cloudcode-pa`, `antigravity-unleash.goog`, `generativelanguage`, `gemini`, `aistudio`). *Do not add `159.194.200.33` as a DNS server — it is an SNI relay target only.* |
| `dns-ai` | DNS-AI Smart-DNS | `194.87.196.13`, `45.151.102.219` | `https://dns-ai.ru/dns-query` | **5/16** (`cloudcode-pa`, `daily-cloudcode-pa`, `generativelanguage`, `gemini`, `aistudio`). **Requires HTTP/2**. |
| `comss` | Comss.one DNS | `141.133.184.24`, `155.212.172.101`, `141.133.183.77` | `https://dns.comss.one/dns-query` | **3/16** via CNAME pools (`generativelanguage`, `gemini`, `aistudio`) + AdGuard/AdAway adblocking. Does not proxy `antigravity.google` or `cloudcode-pa`. |
| `malw` | Malw Smart-DNS | `179.254.166.171`, `164.5.224.81` | `https://dns.malw.link/dns-query` | **6/16** (`antigravity.google`, `daily-cloudcode-pa`, `antigravity-unleash.goog`, `generativelanguage`, `gemini`, `aistudio`). **Requires HTTP/2**; higher latency (~899 ms). |

### 3. `rf-clean` — Domestic Clean DoH (`AllowFallbackToUdp=true`)

| ID | Name | IPv4 | DoH Template | Notes |
| :--- | :--- | :--- | :--- | :--- |
| `yandex` | Yandex.DNS Basic | `77.88.8.1`, `77.88.8.8` | `https://common.dot.dns.yandex.net/dns-query` | Zero SNI-proxy relaying, high ISP resilience; **requires HTTP/2** (`common.doh.dns.yandex.net` returns `NXDOMAIN`, so `common.dot.dns.yandex.net` is used). Does not bypass AI geo-restrictions without VPN. |

### Why `Xbox DNS` and Retired IPs Are Excluded (`deprecated_or_blocked`)

- **Xbox DNS (`111.88.96.54–57`)**: Actively returns `0.0.0.0` (`BLOCKED`) for `generativelanguage.googleapis.com`, `gemini.google.com`, and `aistudio.google.com` (`111.88.96.54` also fails DoT with `SSLEOFError`).
- **Retired / Broken Legacy Comss.one IPs**: `92.38.153.185` (expired `joy-jet.com` TLS cert), `91.230.211.67` (mismatched `dash.hmax.name` cert), `83.220.169.155` (self-signed `for.test` cert), plus dead/timed-out IPs `92.223.109.31`, `212.109.195.93`, `109.73.193.146`, `93.115.24.204`.
- **Other Unusable Addresses**: `127.0.0.53` (dead local DNS forwarder), `45.155.204.190` (legacy dead NRPT IP), `AstraCAT` (`135.106.217.200`, `144.31.151.64` — dead/TLS EOF), `Mullvad DNS` (`194.242.2.2` — service discontinued Nov 2, 2026), and `159.194.200.33` (GeoHide SNI proxy target, not a DNS resolver).

---

## Quick Start & Rich Interactive Menu

### Prerequisites

- **OS**: Windows 11 (native IPv4 DoH support).
- **Shell**: Windows PowerShell 5.1 (built-in) or PowerShell 7+ (`pwsh.exe`).
- **Optional Rich TUI**: Python 3 with the `rich` package (`pip install rich`). Automatically enables Win32 Virtual Terminal processing (`ENABLE_VIRTUAL_TERMINAL_PROCESSING`) and `--force-color` so full ANSI colors render cleanly in Windows Terminal and `conhost.exe` on both PowerShell 5.1 and 7+. Disable colors via `NO_COLOR=1`, or pass `-NoRich` (or omit `rich`) to fall back to clean native PowerShell console output.

### Launch

Double-click [dns-switch.cmd](dns-switch.cmd) or run from any terminal:

```bat
.\dns-switch.cmd
```

Or directly via PowerShell:

```powershell
.\dns-switch.ps1
# Force plain PowerShell text output (skip Python Rich UI):
.\dns-switch.ps1 -NoRich
```

### Interactive Menu Workflow

When launched without arguments, `.\dns-switch.ps1` opens the interactive dashboard (rendered in Russian via [ui/rich_ui.py](ui/rich_ui.py)):

1. **Automatic Live Availability Check**: On startup, runs `Get-LiveDnsAvailability` in parallel across all 12 profiles against `cloudcode-pa.googleapis.com`, `daily-cloudcode-pa.googleapis.com`, and `antigravity.google` (3 s timeout, cached for the menu session).
2. **"Recommended Right Now" Panel**: Displays the top 3 reachable profiles tailored to your current VPN status (live `RecommendedIds` with latency in ms, falling back to static recommendations if offline).
3. **All 12 Profiles Table (Single-Line Layout)**: Uses a minimal horizontal-rule table (`box.SIMPLE_HEAD`) with a `Without VPN (RF)` (`── Без VPN (РФ) ──`) group divider between `vpn-clean` and `rf-smart`/`rf-clean`, a combined **Status** cell (`● OK · 56 мс`, `▲ Частично · 95 мс`, `✕ Офлайн`, `○ Не проверен`), role summary, and trust badge (`Чистый DoH`, `DoH + защита`, `DoH + AdBlock`, `SNI-прокси`, `CNAME/AdBlock`, `РФ · Чистый`).
4. **Responsive Terminal Width & Preserved ANSI Colors**: Automatically reads the host console width (`72..140` columns) and adapts cleanly — hiding the role column and recommendation `({id})` tags below `95` columns, stacking top `status` cards below `100` columns, and collapsing the aligned 3×3 action grid into 2 columns below `80` columns. Win32 VT processing (`ENABLE_VIRTUAL_TERMINAL_PROCESSING`) and `--force-color` preserve ANSI colors across PowerShell pipes in Windows Terminal and `conhost.exe` (disable with `-NoRich` or `NO_COLOR=1`).
5. **Aligned 3×3 Menu Shortcuts**:
   - `1–12` — Select and apply a DNS profile + Windows 11 native IPv4 DoH.
   - `[C]` — Re-run live parallel availability check across all 12 profiles.
   - `[P]` — Detailed `probe` diagnostics with strict TLS certificate validation.
   - `[N]` — Audit, clean up, or restore Windows NRPT rules.
   - `[R]` — Reset DNS to adapter defaults (DHCP / VPN defaults) or restore from backup.
   - `[B]` — List or save manual DNS/DoH/NRPT backups.
   - `[D]` — Toggle `Dry-Run` preview mode without discarding the cached availability results.
   - `[S]` — Refresh adapter/VPN/NRPT status without re-probing.
   - `[Q]` — Quit (submenus also support instant `[B]` / `Enter` return).

---

## CLI Reference & Examples

### Commands

| Command | Description & Key Flags |
| :--- | :--- |
| `status [-Json] [-NoRich]` | Show detected VPN/tunnel adapters, active DNS servers, IPv4/IPv6 DoH templates, and NRPT audit summary. |
| `list [-Category <all\|vpn-clean\|rf-smart\|rf-clean>] [-Json]` | List profiles with IPv4 addresses, DoH templates, HTTP/2 requirement, and trust notes. |
| `check [-Json] [-NoRich]` *(alias: `availability`)* | Run fast parallel live check across all 12 profiles and compute top-3 recommendations for current VPN state. |
| `probe [-Target <id>] [-Category <cat>] [-All] [-Quick] [-Availability] [-Json] [-NoRich]` | Live read-only DoH benchmark + strict TLS check (`-Quick`: 5 core domains, 1 iteration; `-Availability`: runs the `check` matrix). |
| `switch <profileId> [flags]` | Apply DNS servers + native IPv4 DoH. Flags: `-TargetMode <auto\|vpn\|ethernet\|both\|custom>`, `-AdapterNames <names>`, `-AllowUdpFallback <auto\|true\|false>`, `-CleanNrpt`, `-SkipPreflight`, `-DryRun`, `-NoElevate`, `-Json`, `-NoRich`. |
| `reset [flags]` | Reset adapter DNS to defaults (DHCP on physical NICs; default DNS on active VPN adapters without touching VPN routes). Flags: `-TargetMode`, `-AdapterNames`, `-DryRun`, `-NoElevate`, `-Json`, `-NoRich`. |
| `nrpt [<status\|clean\|restore>] [-BackupPath <path>] [-ReplaceExisting] [-DryRun] [-NoElevate] [-Json] [-NoRich]` | Audit NRPT rules, back up and remove flagged/stale rules (`127.0.0.53`, Xbox DNS, deprecated IPs), or restore from backup. |
| `backups [<list\|save\|restore>] [-BackupPath <path>] [-Label <text>] [-SkipNrpt] [-SkipDohTemplates] [-DryRun] [-NoElevate] [-Json] [-NoRich]` | List, save, or restore full atomic snapshots (adapter DNS + DoH templates + NRPT rules) in `backups\`. |
| `help [-Json] [-NoRich]` | Show CLI usage and safety guarantees. |

### Examples

```powershell
# Live parallel availability check across all 12 profiles
.\dns-switch.ps1 check
.\dns-switch.ps1 probe -Availability

# Inspect current VPN, DNS, DoH, and NRPT state (with or without Rich UI)
.\dns-switch.ps1 status
.\dns-switch.ps1 status -NoRich
.\dns-switch.ps1 nrpt status -Json

# Quick read-only DoH + strict TLS probe for Cloudflare
.\dns-switch.ps1 probe -Target cloudflare -Quick

# Preview switching DNS + cleaning stale NRPT rules (no UAC, no system changes)
.\dns-switch.ps1 switch cloudflare -CleanNrpt -DryRun

# Apply Cloudflare DoH and clean stale NRPT rules (auto-prompts UAC if needed)
.\dns-switch.ps1 switch cloudflare -CleanNrpt

# Switch to GeoHide Smart-DNS on physical Ethernet/Wi-Fi only (no VPN)
.\dns-switch.ps1 switch geohide -TargetMode ethernet

# Preview reset or restore from a saved JSON backup
.\dns-switch.ps1 reset -DryRun
.\dns-switch.ps1 backups list
.\dns-switch.ps1 backups restore -BackupPath .\backups\dns-backup-20261126-000000-manual.json -DryRun
```

---

## Safety & Privacy Guarantees

- **Pre-Flight Live DoH Verification**: Before `switch` modifies any adapter or DoH template, it verifies the target resolver's live DoH availability (unless `-SkipPreflight` is explicitly passed) so you never apply a dead DNS server.
- **Atomic Local Backups (`backups/`)**: Every mutating operation (`switch`, `reset`, `nrpt clean`) automatically writes a timestamped UTF-8 JSON snapshot of adapter DNS, DoH templates, and NRPT rules into `backups/` (gitignored via [.gitignore](.gitignore)) before making changes.
- **Non-Destructive `-DryRun` & `-WhatIf`**: All mutating commands (`switch`, `reset`, `nrpt clean`, `nrpt restore`, `backups save`, `backups restore`) support `-DryRun` without requiring Administrator privileges or writing to the registry/network stack.
- **Auto-UAC with Output & Error Relay (`-ElevationLogPath`)**: Read-only commands and `-DryRun` run unprivileged. Mutating commands automatically request UAC elevation when needed (disable with `-NoElevate`) and relay the child process's full log, error details, or JSON payload back to the caller console so elevated errors are never lost.
- **Zero Telemetry**: All probing goes directly from your machine to the configured DNS/DoH endpoints. No analytics, crash reporting, or external tracking.

---

## Project Layout & Running Tests

```text
dns_switcher/
├── .github/workflows/ci.yml       # CI: pure ASCII, PS 5.1 & 7 AST, JSON schema, py_compile, unit tests
├── .gitignore                     # Ignores backups/, __pycache__/, logs, temp files
├── LICENSE                        # MIT License
├── README.md                      # English documentation (primary)
├── README.ru.md                   # Russian documentation
├── dns-switch.cmd                 # Launcher (auto-selects pwsh.exe 7+ or powershell.exe 5.1)
├── dns-switch.ps1                 # Main CLI & interactive menu entrypoint
├── config/
│   ├── profiles.json              # 12 curated profiles, 16 test domains, 17 deprecated/blocked IPs
│   └── profiles.schema.json       # JSON Schema for profiles.json validation
├── lib/
│   ├── DnsCommon.psm1             # Universal VPN/TUN/RAS detection, adapter snapshots, UAC elevation
│   ├── DnsBackupAndNrpt.psm1      # Atomic JSON backups and NRPT audit/cleanup/restore
│   ├── DnsProbe.psm1              # Live DoH probing, strict TLS checks, parallel availability matrix
│   └── DnsSwitcher.psm1           # Adapter targeting, Windows 11 DoH registration, switch & reset
├── ui/
│   └── rich_ui.py                 # Optional Python Rich TUI (8 --view modes, --width, --force-color, --color-system, --no-color)
├── backups/                       # Local JSON state snapshots (created at runtime, gitignored)
└── tests/
    ├── run-tests.ps1              # Unified test runner (all | unit | integration)
    ├── TestHarness.ps1            # Shared test assertions & process helpers
    ├── unit-config.ps1            # Config & JSON schema unit tests (9 tests)
    ├── unit-lib.ps1               # Module unit tests for lib\*.psm1 (20 tests)
    └── integration-cli.ps1        # Read-only & DryRun CLI integration tests (33 tests)
```

### Running Tests

Run the full 62-test suite (`9` config + `20` lib + `33` CLI integration) on either PowerShell 7+ (`pwsh`) or Windows PowerShell 5.1 (`powershell`):

```powershell
.\tests\run-tests.ps1
# Or run a specific suite:
.\tests\run-tests.ps1 -Suite unit
.\tests\run-tests.ps1 -Suite integration
```

GitHub Actions CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) automatically verifies pure-ASCII encoding on `.ps1`/`.psm1`/`config/*.json`, PowerShell AST parsing on both `pwsh` 7 and `powershell` 5.1, JSON Schema validation, `python -X utf8 -m py_compile ui/rich_ui.py`, and `.\tests\unit-config.ps1`.

---

## Changelog

- **v1.0.1** — Decluttered Rich TUI layout & preserved terminal colors/width:
  - Redesigned `ui/rich_ui.py` into single-line rows across all 12 profiles with combined status + latency, `Without VPN (RF)` (`── Без VPN (РФ) ──`) group divider, aligned 3×3 action grid, and responsive `< 95` / `< 80` / `< 100` width breakpoints.
  - Added `--force-color`, `--color-system`, `FORCE_COLOR` support, `72..140` column width clamping, and Win32 `ENABLE_VIRTUAL_TERMINAL_PROCESSING` (`Enable-ConsoleVirtualTerminal`) in `dns-switch.ps1` so ANSI colors render cleanly across Windows Terminal, `conhost.exe`, PowerShell 5.1, and PowerShell 7+.
- **v1.0.0** — Initial release:
  - Windows 11 native IPv4 DoH switcher (`dns-switch.ps1` / `dns-switch.cmd`), 12 curated profiles (`vpn-clean`, `rf-smart`, `rf-clean`), universal VPN/TUN/RAS detection, parallel live checks, strict TLS `probe`, NRPT audit/cleanup, atomic JSON backups, auto-UAC log/JSON relay, optional Rich TUI, and 62 dual-runtime tests.

---

## License

Released under the [MIT License](LICENSE).
