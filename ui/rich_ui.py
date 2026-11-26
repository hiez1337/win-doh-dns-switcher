#!/usr/bin/env python3
"""Rich-based Russian console UI renderer for dns_switcher."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from rich import box
from rich.columns import Columns
from rich.console import Console, Group
from rich.panel import Panel
from rich.table import Table
from rich.text import Text


DEFAULT_PROFILES_FALLBACK: list[dict[str, Any]] = [
    {"id": "cloudflare", "name": "Cloudflare Unfiltered", "category": "vpn-clean", "recommended_for": ["vpn-on"], "ipv4": ["1.1.1.1", "1.0.0.1"], "requires_http2": False, "smart_proxy_domains": []},
    {"id": "google", "name": "Google Public DNS", "category": "vpn-clean", "recommended_for": ["vpn-on"], "ipv4": ["8.8.8.8", "8.8.4.4"], "requires_http2": False, "smart_proxy_domains": []},
    {"id": "controld-p0", "name": "Control D Free Unfiltered (p0)", "category": "vpn-clean", "recommended_for": ["vpn-on"], "ipv4": ["76.76.2.0", "76.76.10.0"], "requires_http2": False, "smart_proxy_domains": []},
    {"id": "controld-p2", "name": "Control D Free Adblock (p2)", "category": "vpn-clean", "recommended_for": ["vpn-on"], "ipv4": ["76.76.2.2", "76.76.10.2"], "requires_http2": False, "smart_proxy_domains": []},
    {"id": "quad9", "name": "Quad9 Secured", "category": "vpn-clean", "recommended_for": ["vpn-on"], "ipv4": ["9.9.9.9", "149.112.112.112"], "requires_http2": True, "smart_proxy_domains": []},
    {"id": "adguard-unfiltered", "name": "AdGuard DNS Unfiltered", "category": "vpn-clean", "recommended_for": ["vpn-on"], "ipv4": ["94.140.14.140", "94.140.14.141"], "requires_http2": False, "smart_proxy_domains": []},
    {"id": "dns-sb", "name": "DNS.SB", "category": "vpn-clean", "recommended_for": ["vpn-on"], "ipv4": ["185.222.222.222", "45.11.45.11"], "requires_http2": False, "smart_proxy_domains": []},
    {"id": "geohide", "name": "GeoHide Smart-DNS", "category": "rf-smart", "recommended_for": ["vpn-off"], "ipv4": ["37.230.192.51", "193.233.112.88"], "requires_http2": False, "smart_proxy_domains": ["antigravity.google", "antigravity-pa.googleapis.com", "antigravity.googleapis.com", "daily-cloudcode-pa.googleapis.com", "antigravity-unleash.goog", "generativelanguage.googleapis.com", "gemini.google.com", "aistudio.google.com"]},
    {"id": "dns-ai", "name": "DNS-AI Smart-DNS", "category": "rf-smart", "recommended_for": ["vpn-off"], "ipv4": ["194.87.196.13", "45.151.102.219"], "requires_http2": True, "smart_proxy_domains": ["cloudcode-pa.googleapis.com", "daily-cloudcode-pa.googleapis.com", "generativelanguage.googleapis.com", "gemini.google.com", "aistudio.google.com"]},
    {"id": "comss", "name": "Comss.one DNS", "category": "rf-smart", "recommended_for": ["vpn-off"], "ipv4": ["141.133.184.24", "155.212.172.101", "141.133.183.77"], "requires_http2": False, "smart_proxy_domains": ["generativelanguage.googleapis.com", "gemini.google.com", "aistudio.google.com"]},
    {"id": "malw", "name": "Malw Smart-DNS", "category": "rf-smart", "recommended_for": ["vpn-off"], "ipv4": ["179.254.166.171", "164.5.224.81"], "requires_http2": True, "smart_proxy_domains": ["antigravity.google", "daily-cloudcode-pa.googleapis.com", "antigravity-unleash.goog", "generativelanguage.googleapis.com", "gemini.google.com", "aistudio.google.com"]},
    {"id": "yandex", "name": "Yandex.DNS Basic", "category": "rf-clean", "recommended_for": ["vpn-off"], "ipv4": ["77.88.8.1", "77.88.8.8"], "requires_http2": True, "smart_proxy_domains": []},
]

PROFILE_WHY_RU: dict[str, str] = {
    "cloudflare": "Самый быстрый чистый DoH поверх VPN",
    "google": "Надёжный чистый DoH от Google поверх VPN",
    "controld-p0": "Чистый быстрый DoH без логов поверх VPN",
    "controld-p2": "Чистый DoH поверх VPN с блокировкой рекламы и трекеров",
    "quad9": "Швейцарский DoH поверх VPN с защитой от фишинга и вредоносных сайтов",
    "adguard-unfiltered": "Запасной чистый DoH без фильтрации поверх VPN",
    "dns-sb": "Резервный зарубежный чистый DoH поверх VPN",
    "geohide": "Открывает Antigravity, Gemini и AI Studio без VPN через умный SNI-прокси",
    "dns-ai": "Открывает cloudcode-pa и Gemini без VPN",
    "comss": "Открывает Gemini и AI Studio без VPN + блокировка рекламы (через CNAME-пул)",
    "malw": "Запасной умный SNI-прокси для Antigravity и Gemini без VPN (выше задержка)",
    "yandex": "Чистый быстрый DNS в РФ без сторонних прокси",
}

PROFILE_ROLE_RU: dict[str, str] = {
    "cloudflare": "Поверх VPN: максимум скорости, все сервисы Google/Antigravity",
    "google": "Поверх VPN: эталонная совместимость с Google и OAuth",
    "controld-p0": "Поверх VPN: без фильтрации и логирования",
    "controld-p2": "Поверх VPN: Google/AI + блокировка рекламы",
    "quad9": "Поверх VPN: с проверкой угроз (HTTP/2)",
    "adguard-unfiltered": "Поверх VPN: чистый резерв без фильтров",
    "dns-sb": "Поверх VPN: дополнительный чистый резерв",
    "geohide": "Без VPN (РФ): Antigravity, Gemini, AI Studio (8 доменов)",
    "dns-ai": "Без VPN (РФ): cloudcode-pa, Gemini, AI Studio (5 доменов)",
    "comss": "Без VPN (РФ): Gemini, AI Studio + AdBlock (3 домена)",
    "malw": "Без VPN (РФ): резерв для Antigravity/Gemini (6 доменов)",
    "yandex": "Без VPN (РФ): чистый РФ-DNS (без обхода геоблока AI)",
}

PROFILE_TRUST_RU: dict[str, str] = {
    "comss": "[yellow]CNAME-пул + AdBlock[/]",
}

STATIC_RECOMMENDED_VPN_ON = ["cloudflare", "google", "controld-p0"]
STATIC_RECOMMENDED_VPN_OFF = ["geohide", "dns-ai", "yandex"]


def configure_stdio() -> None:
    """Reconfigure stdout/stdin to UTF-8 with safe error replacement."""
    for stream in (sys.stdout, sys.stdin):
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except Exception:
                pass


def build_console(width: int | None = None, no_color: bool = False) -> Console:
    """Create a Rich Console configured for Windows UTF-8 output."""
    kwargs: dict[str, Any] = {"highlight": False}
    if width is not None and width > 0:
        kwargs["width"] = width
    if no_color:
        kwargs["no_color"] = True
    return Console(**kwargs)


def as_dict(value: Any) -> dict[str, Any]:
    """Return value if it is a dict, otherwise an empty dict."""
    return value if isinstance(value, dict) else {}


def as_list(value: Any) -> list[Any]:
    """Return value as a list (wrapping single non-empty non-list items if needed)."""
    if isinstance(value, list):
        return value
    if value is None:
        return []
    return [value]


def get_ci(mapping: Any, *keys: str, default: Any = None) -> Any:
    """Case-insensitive dict lookup across multiple candidate keys."""
    if not isinstance(mapping, dict):
        return default
    for key in keys:
        if key in mapping and mapping[key] is not None:
            return mapping[key]
    lower_map = {str(k).lower(): v for k, v in mapping.items()}
    for key in keys:
        lk = key.lower()
        if lk in lower_map and lower_map[lk] is not None:
            return lower_map[lk]
    return default


def safe_str(value: Any, default: str = "—") -> str:
    """Convert scalar value to display string or default if empty/None."""
    if value is None:
        return default
    text = str(value).strip()
    return text if text else default


def safe_bool(value: Any, default: bool = False) -> bool:
    """Safely interpret bool-like values."""
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        low = value.strip().lower()
        if low in ("true", "1", "yes", "да"):
            return True
        if low in ("false", "0", "no", "нет"):
            return False
    return default


def fmt_ms(value: Any) -> str:
    """Format millisecond latency nicely in Russian."""
    if value is None or isinstance(value, bool):
        return "—"
    try:
        num = float(value)
    except (TypeError, ValueError):
        return "—"
    if num <= 0:
        return "—"
    if num < 100:
        return f"{num:.0f} мс"
    return f"{num:.0f} мс"


def latency_style(value: Any) -> str:
    """Pick a Rich color style for a millisecond latency value."""
    try:
        num = float(value)
    except (TypeError, ValueError):
        return "dim"
    if num <= 0:
        return "dim"
    if num < 120:
        return "green"
    if num < 400:
        return "cyan"
    return "yellow"


def bool_ru(value: Any, yes: str = "Да", no: str = "Нет") -> str:
    """Render bool-like value as styled Russian Да/Нет."""
    if value is None:
        return "[dim]—[/]"
    return f"[green]{yes}[/]" if safe_bool(value) else f"[red]{no}[/]"


def join_list(value: Any, empty: str = "—") -> str:
    """Join a list of scalars with commas."""
    items = [str(x).strip() for x in as_list(value) if x is not None and str(x).strip()]
    return ", ".join(items) if items else empty


def load_payload(input_path: str | None) -> dict[str, Any]:
    """Read UTF-8 JSON payload from file or stdin, returning {} on empty/invalid input."""
    raw = ""
    if input_path:
        path = Path(input_path)
        raw = path.read_text(encoding="utf-8-sig", errors="replace")
    else:
        if not sys.stdin.isatty():
            raw = sys.stdin.read()
    raw = raw.lstrip("\ufeff").strip()
    if not raw:
        return {}
    parsed = json.loads(raw)
    if isinstance(parsed, dict):
        return parsed
    return {"Extra": parsed}


def get_profiles(payload: dict[str, Any]) -> list[dict[str, Any]]:
    """Extract normalized profile list from payload or fallback."""
    raw = get_ci(payload, "Profiles", "profiles")
    profiles = [p for p in as_list(raw) if isinstance(p, dict)]
    return profiles if profiles else list(DEFAULT_PROFILES_FALLBACK)


def get_availability_map(availability: dict[str, Any] | None) -> dict[str, dict[str, Any]]:
    """Index Availability.Results by lowercase profile ID."""
    avail_map: dict[str, dict[str, Any]] = {}
    if not isinstance(availability, dict):
        return avail_map
    for item in as_list(get_ci(availability, "Results", "results")):
        if not isinstance(item, dict):
            continue
        pid = safe_str(get_ci(item, "ProfileId", "id"), default="").lower()
        if pid:
            avail_map[pid] = item
    return avail_map


def status_badge(avail_entry: dict[str, Any] | None) -> str:
    """Render live profile availability badge."""
    if not avail_entry:
        return "[dim]○ Не проверен[/]"
    raw_status = safe_str(get_ci(avail_entry, "Status", "status"), default="").upper()
    available = get_ci(avail_entry, "Available", "available")
    if raw_status in ("ONLINE", "HEALTHY") or (raw_status == "" and available is True):
        return "[green]● Работает[/]"
    if raw_status in ("DEGRADED", "PARTIAL"):
        return "[yellow]▲ Частично[/]"
    if raw_status in ("OFFLINE", "UNHEALTHY") or available is False:
        return "[red]✕ Недоступен[/]"
    return "[dim]○ Не проверен[/]"


def trust_badge(profile: dict[str, Any]) -> str:
    """Render plain-Russian trust / proxy type badge for a profile."""
    pid = safe_str(get_ci(profile, "id", "ProfileId"), default="").lower()
    cat = safe_str(get_ci(profile, "category", "Category"), default="").lower()
    if pid in PROFILE_TRUST_RU:
        return PROFILE_TRUST_RU[pid]
    if cat == "rf-smart":
        return "[yellow]SNI-прокси (сторонний)[/]"
    if cat == "rf-clean":
        return "[cyan]Чистый РФ DoH[/]"
    if pid == "controld-p2":
        return "[green]Чистый DoH + AdBlock[/]"
    if pid == "quad9":
        return "[green]Чистый DoH + защита[/]"
    return "[green]Чистый DoH (без прокси)[/]"


def get_vpn_state(status_report: dict[str, Any]) -> dict[str, Any]:
    """Read VPN state from StatusReport.VpnState, falling back to legacy VPN state key if present."""
    return as_dict(get_ci(status_report, "VpnState", "QuatroVpn"))


def get_vpn_active(
    container: dict[str, Any] | None,
    status_report: dict[str, Any] | None = None,
) -> bool:
    """Read VPN active flag from VpnActive (with legacy key fallback), or StatusReport."""
    if isinstance(container, dict):
        val = get_ci(container, "VpnActive", "QuatroVpnActive")
        if val is not None:
            return safe_bool(val, default=False)
    if isinstance(status_report, dict):
        vpn = get_vpn_state(status_report)
        return safe_bool(get_ci(vpn, "IsActive"), default=False)
    return False


def format_vpn_adapter_label(vpn: dict[str, Any]) -> str:
    """Format '<AdapterName> · <InterfaceDescription>' or fallback label for an active VPN."""
    adapter_name = safe_str(get_ci(vpn, "AdapterName"), default="")
    iface_desc = safe_str(get_ci(vpn, "InterfaceDescription"), default="")
    if adapter_name and iface_desc:
        return f"{adapter_name} · {iface_desc}"
    if adapter_name:
        return adapter_name
    if iface_desc:
        return iface_desc
    ras = join_list(get_ci(vpn, "RasConnections"), empty="")
    if ras:
        return ras
    return "туннель активен"


def format_detected_adapters(vpn: dict[str, Any]) -> str:
    """Format DetectedAdapters entries (strings or dicts) as comma-separated names."""
    names: list[str] = []
    for item in as_list(get_ci(vpn, "DetectedAdapters")):
        if isinstance(item, dict):
            name = safe_str(get_ci(item, "AdapterName", "Name"), default="")
        else:
            name = safe_str(item, default="")
        if name and name not in names:
            names.append(name)
    return ", ".join(names)


def format_active_dns_line(status_report: dict[str, Any]) -> Text:
    """Build a clear Russian summary line for Active DNS & DoH status."""
    guess = as_dict(get_ci(status_report, "ActiveProfileGuess"))
    doh = as_dict(get_ci(status_report, "DohSummary"))
    pid = safe_str(get_ci(guess, "ProfileId"), default="")
    pname = safe_str(get_ci(guess, "ProfileName"), default="")
    adapter = safe_str(get_ci(guess, "AdapterName"), default="")
    doh_cfg = safe_bool(get_ci(guess, "DohConfigured"), default=False)
    ipv4_doh_count = int(get_ci(doh, "IPv4Count", default=0) or 0)

    line = Text()
    if pid == "vpn-default":
        line.append("Доступен ", style="bold green")
        summary = safe_str(get_ci(guess, "Summary"), default="")
        if adapter:
            line.append(f"(стандартный DNS VPN на {adapter}; DoH: ", style="white")
        elif summary and summary != "—":
            line.append(f"({summary}; DoH: ", style="white")
        else:
            line.append("(стандартный DNS VPN; DoH: ", style="white")
        line.append("Нужна настройка", style="bold yellow")
        line.append(")", style="white")
    elif pid == "dhcp":
        line.append("Авто от провайдера (DHCP) ", style="yellow")
        if adapter:
            line.append(f"на {adapter} ", style="dim")
        line.append("· DoH: Нужна настройка", style="bold yellow")
    elif pid in ("", "custom") and not pname:
        line.append("Нужна настройка ", style="bold yellow")
        summary = safe_str(get_ci(guess, "Summary"), default="")
        if summary and summary != "—":
            line.append(f"({summary})", style="dim")
    elif doh_cfg or ipv4_doh_count > 0:
        label = f"{pname} ({pid})" if pname and pid and pid != "custom" else (pname or pid or "Настроен")
        line.append("Включён ", style="bold green")
        line.append(f"— {label} ", style="white")
        line.append("[DoH активен]", style="green")
    else:
        label = f"{pname} ({pid})" if pname and pid else (pname or pid or "Статический DNS")
        line.append("Доступен ", style="cyan")
        line.append(f"— {label} · ", style="white")
        line.append("DoH: Нужна настройка", style="bold yellow")
    return line


def render_header_panel(console: Console, status_report: dict[str, Any], dry_run: bool) -> None:
    """Render the main header dashboard panel in Russian."""
    vpn = get_vpn_state(status_report)
    nrpt = as_dict(get_ci(status_report, "NrptSummary"))
    vpn_active = safe_bool(get_ci(vpn, "IsActive"), default=False)
    hijack_expected = safe_bool(get_ci(vpn, "HijackDnsExpected"), default=vpn_active)
    flagged = int(get_ci(nrpt, "FlaggedCount", default=0) or 0)
    total_nrpt = int(get_ci(nrpt, "TotalRules", default=0) or 0)
    is_admin = safe_bool(get_ci(status_report, "IsAdministrator"), default=False)

    grid = Table.grid(padding=(0, 2))
    grid.add_column(style="bold cyan", no_wrap=True)
    grid.add_column()

    vpn_text = Text()
    if vpn_active:
        vpn_text.append(f"ВКЛЮЧЁН ({format_vpn_adapter_label(vpn)})", style="bold green")
        if hijack_expected:
            vpn_text.append(" · TUN может перехватывать порт 53 (DoH TCP:443 обходит)", style="dim")
    else:
        vpn_text.append("Не активен / Не обнаружен (прямое подключение)", style="bold yellow")
    grid.add_row("VPN:", vpn_text)

    grid.add_row("DNS и DoH:", format_active_dns_line(status_report))

    nrpt_text = Text()
    if flagged > 0:
        nrpt_text.append(f"Найдено {flagged} старых правил, тормозящих Google AI", style="bold yellow")
        nrpt_text.append(" (нажмите [N] для очистки)", style="dim")
    else:
        nrpt_text.append("Чисто", style="bold green")
        if total_nrpt > 0:
            nrpt_text.append(f" (всего правил: {total_nrpt}, конфликтов нет)", style="dim")
    grid.add_row("Правила NRPT:", nrpt_text)

    priv_text = Text()
    if is_admin:
        priv_text.append("Администратор (изменения применяются сразу)", style="green")
    else:
        priv_text.append("Обычный пользователь (UAC запросится при смене DNS)", style="dim")
    grid.add_row("Права:", priv_text)

    if dry_run:
        dry_banner = Text(" РЕЖИМ ПРЕДПРОСМОТРА (Dry-Run) — настройки системы НЕ изменяются ", style="bold black on yellow")
        body: Any = Group(dry_banner, Text(""), grid)
    else:
        body = grid

    border = "yellow" if dry_run else "bright_cyan"
    console.print(
        Panel(
            body,
            title="[bold white]Мастер DNS для Antigravity и Google[/]",
            subtitle="[dim]Безопасная настройка DoH для Windows 11[/]",
            border_style=border,
            box=box.ROUNDED,
            padding=(0, 1),
        )
    )


def render_recommendations_panel(
    console: Console,
    profiles: list[dict[str, Any]],
    status_report: dict[str, Any],
    availability: dict[str, Any] | None,
) -> None:
    """Render top-3 'Рекомендуем прямо сейчас' panel."""
    vpn_active = get_vpn_active(availability, status_report)

    avail_map = get_availability_map(availability)
    index_by_id: dict[str, tuple[int, dict[str, Any]]] = {}
    for idx, prof in enumerate(profiles, start=1):
        pid = safe_str(get_ci(prof, "id", "ProfileId"), default="").lower()
        if pid:
            index_by_id[pid] = (idx, prof)

    rec_ids: list[str] = []
    if isinstance(availability, dict):
        for rid in as_list(get_ci(availability, "RecommendedIds", "recommendedIds")):
            s = safe_str(rid, default="").lower()
            if s and s in index_by_id and s not in rec_ids:
                rec_ids.append(s)

    if not rec_ids:
        fallback = STATIC_RECOMMENDED_VPN_ON if vpn_active else STATIC_RECOMMENDED_VPN_OFF
        rec_ids = [pid for pid in fallback if pid in index_by_id]

    rec_ids = rec_ids[:3]

    rec_table = Table(box=None, show_header=False, expand=True, padding=(0, 1))
    rec_table.add_column("Choice", no_wrap=True)
    rec_table.add_column("Latency", justify="right", no_wrap=True)
    rec_table.add_column("Why", overflow="fold")

    for rank, pid in enumerate(rec_ids, start=1):
        num, prof = index_by_id[pid]
        pname = safe_str(get_ci(prof, "name", "ProfileName"), default=pid)
        avail_entry = avail_map.get(pid)
        lat_val = get_ci(avail_entry, "LatencyMs", "latencyMs") if avail_entry else None
        lat_str = fmt_ms(lat_val)
        lat_col = latency_style(lat_val)
        if lat_str == "—":
            lat_display = "[dim]не проверено[/]"
        else:
            lat_display = f"[{lat_col}]{lat_str}[/]"

        medal = "★" if rank == 1 else "•"
        why = PROFILE_WHY_RU.get(pid, safe_str(get_ci(prof, "notes"), default="Рекомендованный профиль"))
        cat = safe_str(get_ci(prof, "category"), default="")
        if cat == "rf-smart":
            why_cell = f"{why} [yellow](SNI-прокси)[/]"
        else:
            why_cell = why

        rec_table.add_row(
            f"[bold green]{medal} [{num}][/] [bold white]{pname}[/] [dim]({pid})[/]",
            lat_display,
            why_cell,
        )

    subtitle_parts: list[str] = []
    if isinstance(availability, dict):
        checked_at = safe_str(get_ci(availability, "CheckedAt"), default="")
        dur_ms = get_ci(availability, "DurationMs")
        if checked_at:
            short_ts = checked_at.replace("T", " ")[:19]
            subtitle_parts.append(f"проверено {short_ts}")
        if dur_ms is not None:
            try:
                subtitle_parts.append(f"за {float(dur_ms) / 1000.0:.1f} с")
            except (TypeError, ValueError):
                pass
    else:
        subtitle_parts.append("предварительный выбор · нажмите [C] для живой проверки")

    vpn_hint = "режим с VPN" if vpn_active else "режим без VPN (прямое подключение)"
    subtitle_text = f"[dim]{vpn_hint} · {' · '.join(subtitle_parts)}[/]"

    console.print(
        Panel(
            rec_table,
            title="[bold green]Рекомендуем прямо сейчас[/]",
            subtitle=subtitle_text,
            border_style="green",
            box=box.ROUNDED,
            padding=(0, 1),
        )
    )


def render_profiles_table(
    console: Console,
    profiles: list[dict[str, Any]],
    status_report: dict[str, Any],
    availability: dict[str, Any] | None,
) -> None:
    """Render the table of all 12 DNS profiles in Russian."""
    avail_map = get_availability_map(availability)
    guess = as_dict(get_ci(status_report, "ActiveProfileGuess"))
    active_pid = safe_str(get_ci(guess, "ProfileId"), default="").lower()
    compact = console.width < 100

    table = Table(
        title="[bold white]Все 12 профилей DNS[/]",
        box=box.ROUNDED,
        expand=True,
        show_lines=False,
        header_style="bold cyan",
        border_style="blue",
    )
    table.add_column("№", justify="right", style="bold", width=3, no_wrap=True)
    table.add_column("Профиль", ratio=2, overflow="fold")
    table.add_column("Статус сейчас", width=14 if not compact else 13, no_wrap=True)
    table.add_column("Скорость", justify="right", width=8, no_wrap=True)
    if not compact:
        table.add_column("Для чего подходит", ratio=3, overflow="fold")
    table.add_column("Доверие / Тип", ratio=2, overflow="fold")

    for idx, prof in enumerate(profiles, start=1):
        pid = safe_str(get_ci(prof, "id", "ProfileId"), default=f"p{idx}").lower()
        pname = safe_str(get_ci(prof, "name", "ProfileName"), default=pid)
        avail_entry = avail_map.get(pid)

        is_current = pid == active_pid and active_pid != ""
        num_str = f"[bold cyan]{idx}[/]" if is_current else str(idx)
        prof_label = f"[bold white]{pname}[/]\n[dim]{pid}[/]" if compact else f"[bold white]{pname}[/] [dim]({pid})[/]"
        if is_current:
            prof_label += " [bold cyan]★ тек.[/]"

        badge = status_badge(avail_entry)
        lat_val = get_ci(avail_entry, "LatencyMs", "latencyMs") if avail_entry else None
        lat_str = fmt_ms(lat_val)
        lat_cell = f"[{latency_style(lat_val)}]{lat_str}[/]" if lat_str != "—" else "[dim]—[/]"

        role = PROFILE_ROLE_RU.get(pid, safe_str(get_ci(prof, "notes"), default="Публичный DoH-профиль"))
        if safe_bool(get_ci(prof, "requires_http2"), default=False) and "HTTP/2" not in role:
            role += " [dim](HTTP/2)[/]"
        trust = trust_badge(prof)

        if compact:
            table.add_row(num_str, prof_label, badge, lat_cell, trust)
        else:
            table.add_row(num_str, prof_label, badge, lat_cell, role, trust)

    console.print(table)
    console.print(
        "[dim]Примечание: профили «SNI-прокси (сторонний)» направляют часть AI-доменов через сторонний ретранслятор "
        "(TLS до Google сохраняется, но владелец прокси видит SNI и IP). Чистые профили работают напрямую без прокси.[/]"
    )


def render_actions_footer(console: Console, dry_run: bool) -> None:
    """Render clear Russian action shortcuts panel."""
    dry_state = "[yellow]ВКЛ[/]" if dry_run else "[dim]выкл[/]"
    controls = Text.from_markup(
        "[bold cyan]1-12[/] выбрать и применить DNS  ·  "
        "[bold green]\\[C][/] проверить доступность DNS сейчас  ·  "
        "[bold cyan]\\[P][/] подробная диагностика одного DNS  ·  "
        "[bold yellow]\\[N][/] старые правила Windows (NRPT)  ·  "
        "[bold cyan]\\[R][/] сброс / откат DNS  ·  "
        "[bold cyan]\\[B][/] резервные копии  ·  "
        f"[bold yellow]\\[D][/] предпросмотр (Dry-Run: {dry_state}[bold yellow])[/]  ·  "
        "[bold cyan]\\[S][/] обновить  ·  "
        "[bold red]\\[Q][/] выход"
    )
    console.print(
        Panel(
            controls,
            title="[bold white]Действия[/]",
            border_style="cyan",
            box=box.ROUNDED,
            padding=(0, 1),
        )
    )


def render_menu_view(console: Console, payload: dict[str, Any]) -> None:
    """Render the complete interactive dashboard."""
    status_report = as_dict(get_ci(payload, "StatusReport"))
    if not status_report and any(k in payload for k in ("VpnState", "QuatroVpn", "Adapters", "DohSummary", "NrptSummary")):
        status_report = payload
    profiles = get_profiles(payload)
    availability = get_ci(payload, "Availability")
    if not isinstance(availability, dict):
        availability = None
    dry_run = safe_bool(get_ci(payload, "DryRun"), default=False)

    render_header_panel(console, status_report, dry_run)
    render_recommendations_panel(console, profiles, status_report, availability)
    render_profiles_table(console, profiles, status_report, availability)
    render_actions_footer(console, dry_run)


def render_status_view(console: Console, payload: dict[str, Any]) -> None:
    """Render detailed Russian status cards."""
    report = as_dict(get_ci(payload, "StatusReport"))
    if not report:
        extra = as_dict(get_ci(payload, "Extra"))
        report = extra if extra else payload

    dry_run = safe_bool(get_ci(payload, "DryRun"), default=False)
    render_header_panel(console, report, dry_run)

    vpn = get_vpn_state(report)
    nrpt = as_dict(get_ci(report, "NrptSummary"))
    doh = as_dict(get_ci(report, "DohSummary"))
    guess = as_dict(get_ci(report, "ActiveProfileGuess"))

    vpn_active = safe_bool(get_ci(vpn, "IsActive"), default=False)
    hijack_expected = safe_bool(get_ci(vpn, "HijackDnsExpected"), default=vpn_active)
    detected_adapters = format_detected_adapters(vpn)
    ras_conns = join_list(get_ci(vpn, "RasConnections"), empty="")
    svc_name = safe_str(get_ci(vpn, "ServiceName"), default="")
    iface_desc = safe_str(get_ci(vpn, "InterfaceDescription"), default="")

    vpn_lines: list[str] = []
    if vpn_active:
        vpn_lines.append(f"Состояние: [bold green]ВКЛЮЧЁН[/] ([white]{format_vpn_adapter_label(vpn)}[/])")
        ad_line = f"Адаптер: [white]{safe_str(get_ci(vpn, 'AdapterName'))}[/] ({safe_str(get_ci(vpn, 'AdapterStatus'))})"
        if detected_adapters:
            ad_line += f" · Обнаружены: [white]{detected_adapters}[/]"
        vpn_lines.append(ad_line)
        if iface_desc:
            vpn_lines.append(f"Описание: [white]{iface_desc}[/]")
    else:
        vpn_lines.append("Состояние: [bold yellow]Не активен / Не обнаружен (прямое подключение)[/]")
        vpn_lines.append(f"Адаптер: [white]{safe_str(get_ci(vpn, 'AdapterName'))}[/] ({safe_str(get_ci(vpn, 'AdapterStatus'), 'Не обнаружен')})")

    vpn_lines.append(
        f"Индекс / Метрика: [white]{safe_str(get_ci(vpn, 'InterfaceIndex'))} / {safe_str(get_ci(vpn, 'InterfaceMetric'))}[/] · "
        f"Маршруты IPv4: [white]{safe_str(get_ci(vpn, 'IPv4RouteCount'))}[/]"
    )
    if ras_conns:
        vpn_lines.append(f"RAS VPN: [white]{ras_conns}[/]")
    elif svc_name:
        vpn_lines.append(f"Служба: [white]{svc_name} ({safe_str(get_ci(vpn, 'ServiceStatus'))})[/]")

    if vpn_active and hijack_expected:
        vpn_lines.append("[dim]TUN-адаптер может перехватывать порт 53; DoH (TCP:443) обходит перехват.[/]")
    elif not vpn_active:
        vpn_lines.append("[dim]Активный VPN не обнаружен; DoH применяется к физическим адаптерам.[/]")

    vpn_card = Panel(
        Text.from_markup("\n".join(vpn_lines)),
        title="[bold cyan]VPN / Туннель[/]",
        border_style="green" if vpn_active else "yellow",
        box=box.ROUNDED,
    )

    nrpt_flagged = int(get_ci(nrpt, "FlaggedCount", default=0) or 0)
    nrpt_card = Panel(
        Text.from_markup(
            f"Всего правил: [white]{safe_str(get_ci(nrpt, 'TotalRules'), '0')}[/] · "
            f"Конфликтных: [{'bold yellow' if nrpt_flagged > 0 else 'bold green'}]{nrpt_flagged}[/]\n"
            f"Мёртвых 127.0.0.53: [white]{safe_str(get_ci(nrpt, 'DeadLocalCount'), '0')}[/] · "
            f"Xbox DNS: [white]{safe_str(get_ci(nrpt, 'XboxDnsCount'), '0')}[/]\n"
            f"Перехват Google/Antigravity: [white]{safe_str(get_ci(nrpt, 'GoogleOverrideCount'), '0')}[/]\n"
            f"Профиль DNS: [white]{safe_str(get_ci(guess, 'Summary'))}[/]"
        ),
        title="[bold cyan]NRPT и текущий DNS[/]",
        border_style="yellow" if nrpt_flagged > 0 else "green",
        box=box.ROUNDED,
    )

    if console.width >= 95:
        console.print(Columns([vpn_card, nrpt_card], equal=True, expand=True))
    else:
        console.print(vpn_card)
        console.print(nrpt_card)

    adapters = [a for a in as_list(get_ci(report, "Adapters")) if isinstance(a, dict)]
    ad_table = Table(title="[bold white]Сетевые адаптеры (IPv4)[/]", box=box.ROUNDED, expand=True, header_style="bold cyan")
    ad_table.add_column("Адаптер", overflow="fold")
    ad_table.add_column("Статус", no_wrap=True)
    ad_table.add_column("ifIdx", justify="right", no_wrap=True)
    ad_table.add_column("DNS-серверы IPv4", overflow="fold")
    ad_table.add_column("Режим", no_wrap=True)
    ad_table.add_column("ifDoH", justify="right", no_wrap=True)

    if not adapters:
        ad_table.add_row("[dim]Нет данных об адаптерах[/]", "—", "—", "—", "—", "—")
    else:
        for ad in adapters:
            st = safe_str(get_ci(ad, "Status"))
            st_badge = f"[green]{st}[/]" if st.lower() == "up" else f"[dim]{st}[/]"
            is_dhcp = safe_bool(get_ci(ad, "IsDhcpDns"), default=False)
            per_if = len(as_list(get_ci(ad, "PerInterfaceDohSettings")))
            ad_table.add_row(
                safe_str(get_ci(ad, "Name")),
                st_badge,
                safe_str(get_ci(ad, "InterfaceIndex")),
                join_list(get_ci(ad, "IPv4DnsServers"), "(нет)"),
                "DHCP" if is_dhcp else "Статический",
                str(per_if),
            )
    console.print(ad_table)

    doh_servers = [d for d in as_list(get_ci(doh, "IPv4Servers")) if isinstance(d, dict)]
    doh_table = Table(
        title=f"[bold white]Шаблоны Windows DoH (источник: {safe_str(get_ci(doh, 'Source'), 'н/д')}, IPv4={safe_str(get_ci(doh, 'IPv4Count'), '0')}, IPv6={safe_str(get_ci(doh, 'IPv6Count'), '0')})[/]",
        box=box.ROUNDED,
        expand=True,
        header_style="bold cyan",
    )
    doh_table.add_column("IP-адрес", no_wrap=True)
    doh_table.add_column("Шаблон DoH", overflow="fold")
    doh_table.add_column("AutoUpgrade", no_wrap=True)
    doh_table.add_column("UDP Fallback", no_wrap=True)
    if not doh_servers:
        doh_table.add_row("[dim]Нет настроенных IPv4 DoH-шаблонов[/]", "—", "—", "—")
    else:
        for ds in doh_servers:
            doh_table.add_row(
                safe_str(get_ci(ds, "ServerAddress")),
                safe_str(get_ci(ds, "DohTemplate")),
                bool_ru(get_ci(ds, "AutoUpgrade")),
                bool_ru(get_ci(ds, "AllowFallbackToUdp"), yes="Разрешён", no="Отключён"),
            )
    console.print(doh_table)

    rec_msg = (
        "Рекомендуем с включённым VPN: [bold green]cloudflare[/], [bold green]google[/] или [bold green]controld-p0[/] (чистый DoH поверх VPN)."
        if vpn_active
        else "Рекомендуем без VPN (прямое подключение): [bold yellow]geohide[/] или [bold yellow]dns-ai[/] (умный SNI-прокси для AI), либо [bold cyan]yandex[/] (чистый РФ DNS)."
    )
    console.print(Panel(Text.from_markup(rec_msg), title="[bold green]Совет[/]", border_style="green", box=box.ROUNDED))


def _extract_probe_results(payload: dict[str, Any]) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Normalize probe JSON from Extra or root."""
    extra = as_dict(get_ci(payload, "Extra"))
    src = extra if extra else payload
    results = [r for r in as_list(get_ci(src, "Results")) if isinstance(r, dict)]
    if not results and get_ci(src, "ProfileId") is not None:
        results = [src]
    return src, results


def _classification_badge(cls_name: str) -> str:
    cls_u = cls_name.upper()
    if cls_u == "CLEAN_GOOGLE":
        return "[green]Чистый Google[/]"
    if cls_u == "SMART_PROXY":
        return "[yellow]SNI-прокси[/]"
    if cls_u == "BLOCKED":
        return "[red]Заблокирован[/]"
    return f"[red]{cls_name or 'Ошибка'}[/]"


def render_probe_view(console: Console, payload: dict[str, Any]) -> None:
    """Render benchmark table + per-domain resolution & strict-TLS tables."""
    src, results = _extract_probe_results(payload)
    scope = safe_str(get_ci(src, "Scope"), default="выбранные профили")
    quick = safe_bool(get_ci(src, "Quick"), default=False)
    status_report = as_dict(get_ci(payload, "StatusReport"))
    vpn_active = get_vpn_active(src, status_report)

    mode_txt = "Быстрая проверка (5 ключевых доменов)" if quick else "Полная проверка"
    vpn_txt = "[green]VPN: ВКЛЮЧЁН[/]" if vpn_active else "[yellow]VPN: Не активен[/]"
    console.print(
        Panel(
            Text.from_markup(f"Режим: [bold white]{mode_txt}[/] · Область: [cyan]{scope}[/] · {vpn_txt}"),
            title="[bold white]Диагностика DNS (DoH + Strict TLS)[/]",
            border_style="bright_cyan",
            box=box.ROUNDED,
        )
    )

    bench = Table(title="[bold white]Сводка тестирования[/]", box=box.ROUNDED, expand=True, header_style="bold cyan")
    bench.add_column("№", justify="right", width=3, no_wrap=True)
    bench.add_column("Профиль", min_width=16, overflow="fold")
    bench.add_column("Статус", no_wrap=True)
    bench.add_column("Домены", justify="center", no_wrap=True)
    bench.add_column("Прокси", justify="right", no_wrap=True)
    bench.add_column("Задержка (мед / мин-макс)", justify="right", no_wrap=True)
    bench.add_column("Strict TLS", justify="center", no_wrap=True)
    bench.add_column("IP сервера", no_wrap=True)

    if not results:
        bench.add_row("—", "[dim]Нет результатов проверки[/]", "—", "—", "—", "—", "—", "—")
    else:
        for idx, r in enumerate(results, start=1):
            rank = safe_str(get_ci(r, "Rank"), default=str(idx))
            pid = safe_str(get_ci(r, "ProfileId"), default="?")
            pname = safe_str(get_ci(r, "ProfileName"), default=pid)
            st_raw = safe_str(get_ci(r, "Status"), default="").upper()
            if st_raw == "HEALTHY":
                st_cell = "[green]● Работает[/]"
            elif st_raw == "DEGRADED":
                st_cell = "[yellow]▲ Частично[/]"
            else:
                st_cell = "[red]✕ Ошибка[/]"

            passed_str = safe_str(get_ci(r, "Passed"), default="")
            if not passed_str:
                pc = get_ci(r, "PassedCount")
                td = get_ci(r, "TotalDomains")
                passed_str = f"{pc}/{td}" if pc is not None and td is not None else "—"

            med = get_ci(r, "LatencyMedianMs")
            mn = get_ci(r, "LatencyMinMs")
            mx = get_ci(r, "LatencyMaxMs")
            if med is not None:
                lat_txt = f"[{latency_style(med)}]{float(med):.0f} мс[/] [dim]({float(mn or med):.0f}-{float(mx or med):.0f})[/]"
            else:
                lat_txt = "[dim]—[/]"

            tls_all = get_ci(r, "TlsAllPassed")
            tls_cell = "[green]PASS[/]" if tls_all is True else ("[red]FAIL[/]" if tls_all is False else "[dim]N/A[/]")

            bench.add_row(
                rank,
                f"[bold white]{pname}[/] [dim]({pid})[/]",
                st_cell,
                passed_str,
                safe_str(get_ci(r, "ProxiedCount"), "0"),
                lat_txt,
                tls_cell,
                safe_str(get_ci(r, "TestedIp")),
            )
    console.print(bench)

    # Render detailed per-domain and strict-TLS tables when 1 profile is detailed (or first item has Details)
    details_source = None
    if len(results) == 1:
        details_source = as_dict(get_ci(results[0], "Details")) or results[0]
    elif len(results) > 1:
        issues = [r for r in results if safe_str(get_ci(r, "Status"), "").upper() != "HEALTHY"]
        if issues:
            issue_lines = []
            for iss in issues:
                det = as_dict(get_ci(iss, "Details")) or iss
                bad = [
                    f"{safe_str(get_ci(d, 'Domain'))}={safe_str(get_ci(d, 'Classification'))}"
                    for d in as_list(get_ci(det, "DomainResults"))
                    if isinstance(d, dict) and safe_str(get_ci(d, "Classification"), "").upper() not in ("CLEAN_GOOGLE", "SMART_PROXY")
                ]
                issue_lines.append(f"• [bold]{safe_str(get_ci(iss, 'ProfileId'))}[/]: {', '.join(bad) if bad else 'ошибка TLS или таймаут'}")
            console.print(Panel(Text.from_markup("\n".join(issue_lines)), title="[bold yellow]Проблемные профили[/]", border_style="yellow", box=box.ROUNDED))

    if isinstance(details_source, dict):
        domain_rows = [d for d in as_list(get_ci(details_source, "DomainResults")) if isinstance(d, dict)]
        if domain_rows:
            dt = Table(
                title=f"[bold white]Разрешение доменов ({safe_str(get_ci(details_source, 'ProfileId'))})[/]",
                box=box.ROUNDED,
                expand=True,
                header_style="bold cyan",
            )
            dt.add_column("Домен", overflow="fold")
            dt.add_column("Классификация", no_wrap=True)
            dt.add_column("HTTP", justify="center", no_wrap=True)
            dt.add_column("Задержка", justify="right", no_wrap=True)
            dt.add_column("IP-адреса / Примечание", overflow="fold")

            for dr in domain_rows:
                cls_badge = _classification_badge(safe_str(get_ci(dr, "Classification"), ""))
                a_ips = join_list(get_ci(dr, "ARecords"), "(нет)")
                cnames = join_list(get_ci(dr, "CNames"), "")
                err = safe_str(get_ci(dr, "Error"), "")
                note = a_ips
                if cnames:
                    note += f" [dim](CNAME: {cnames})[/]"
                if err:
                    note += f" [red]Ошибка: {err}[/]"
                rtt = get_ci(dr, "RttMs")
                dt.add_row(
                    safe_str(get_ci(dr, "Domain")),
                    cls_badge,
                    f"H{safe_str(get_ci(dr, 'HttpVersion'), '?')}",
                    f"[{latency_style(rtt)}]{fmt_ms(rtt)}[/]",
                    note,
                )
            console.print(dt)

        tls_rows = [t for t in as_list(get_ci(details_source, "TlsResults")) if isinstance(t, dict)]
        if tls_rows:
            tt = Table(
                title="[bold white]Проверка подлинности TLS-сертификатов (TCP:443)[/]",
                box=box.ROUNDED,
                expand=True,
                header_style="bold cyan",
            )
            tt.add_column("Домен", overflow="fold")
            tt.add_column("IP-адрес", no_wrap=True)
            tt.add_column("Статус", no_wrap=True)
            tt.add_column("Протокол", no_wrap=True)
            tt.add_column("TCP / TLS", justify="right", no_wrap=True)
            tt.add_column("Сертификат / Ошибка", overflow="fold")

            for tr in tls_rows:
                ok = safe_bool(get_ci(tr, "Success"), default=False)
                st_badge = "[green]PASS[/]" if ok else "[red]FAIL[/]"
                tcp_ms = get_ci(tr, "TcpRttMs")
                tls_ms = get_ci(tr, "TlsRttMs")
                rtt_pair = f"{fmt_ms(tcp_ms)} / {fmt_ms(tls_ms)}"
                info = safe_str(get_ci(tr, "CertSubject")) if ok else f"[red]{safe_str(get_ci(tr, 'Error'), 'Ошибка TLS')}[/]"
                failed_cnt = int(get_ci(tr, "FailedAttemptCount", default=0) or 0)
                if ok and failed_cnt > 0:
                    info += f" [dim](резервный IP после {failed_cnt} неудач)[/]"
                tt.add_row(
                    safe_str(get_ci(tr, "Hostname")),
                    safe_str(get_ci(tr, "IpAddress")),
                    st_badge,
                    safe_str(get_ci(tr, "SslProtocol")),
                    rtt_pair,
                    info,
                )
            console.print(tt)


def render_switch_view(console: Console, payload: dict[str, Any]) -> None:
    """Render switch result card in Russian."""
    extra = as_dict(get_ci(payload, "Extra"))
    res = extra if extra else payload
    profiles = get_profiles(payload)
    prof_by_id = {safe_str(get_ci(p, "id"), "").lower(): p for p in profiles}

    dry_run = safe_bool(get_ci(res, "DryRun"), default=safe_bool(get_ci(payload, "DryRun"), default=False))
    applied = safe_bool(get_ci(res, "Applied"), default=not dry_run)
    success = safe_bool(get_ci(res, "Success"), default=False)
    pid = safe_str(get_ci(res, "ProfileId"), default="?")
    prof_obj = as_dict(get_ci(res, "Profile")) or prof_by_id.get(pid.lower(), {})
    pname = safe_str(get_ci(res, "ProfileName"), default=safe_str(get_ci(prof_obj, "name"), pid))
    category = safe_str(get_ci(res, "Category"), default=safe_str(get_ci(prof_obj, "category"), "—"))

    if dry_run:
        title_badge = "[bold cyan][ПРЕДПРОСМОТР Dry-Run][/]"
        border = "cyan"
    elif not applied:
        title_badge = "[bold yellow][ПРОПУЩЕНО][/]"
        border = "yellow"
    elif success:
        title_badge = "[bold green][УСПЕШНО ПРИМЕНЕНО][/]"
        border = "green"
    else:
        title_badge = "[bold yellow][ПРИМЕНЕНО С ПРЕДУПРЕЖДЕНИЯМИ][/]"
        border = "yellow"

    summary_lines = [
        f"{title_badge} Профиль: [bold white]{pname}[/] [dim]({pid}, категория: {category})[/]",
        f"Режим адаптеров: [white]{safe_str(get_ci(res, 'TargetMode'))}[/] · "
        f"AutoUpgrade DoH: {bool_ru(get_ci(res, 'AutoUpgrade'))} · "
        f"UDP Fallback: {bool_ru(get_ci(res, 'AllowFallbackToUdp'), yes='Разрешён', no='Отключён')}",
    ]
    backup_path = safe_str(get_ci(res, "BackupPath"), "")
    if backup_path:
        summary_lines.append(f"Резервная копия: [cyan]{backup_path}[/]")
    msg = safe_str(get_ci(res, "Message"), "")
    if msg:
        summary_lines.append(f"Сообщение: [white]{msg}[/]")

    console.print(Panel(Text.from_markup("\n".join(summary_lines)), title="[bold white]Переключение DNS и DoH[/]", border_style=border, box=box.ROUNDED))

    if category.lower() == "rf-smart":
        trust_note = safe_str(
            get_ci(prof_obj, "trust_note"),
            "Умный DNS использует сторонний SNI/CNAME-прокси для части AI-доменов. Данные внутри TLS защищены сертификатом Google, но оператор прокси видит имена доменов (SNI) и ваш IP.",
        )
        console.print(Panel(Text(trust_note), title="[bold yellow]Напоминание о доверии (rf-smart)[/]", border_style="yellow", box=box.ROUNDED))

    # Preflight section
    pf_skipped = get_ci(res, "PreflightSkipped")
    if pf_skipped is not None:
        if safe_bool(pf_skipped):
            console.print("[yellow]Предварительная проверка DoH пропущена (-SkipPreflight).[/]")
        else:
            pf_passed = safe_bool(get_ci(res, "PreflightPassed"), default=False)
            pf_rows = [p for p in as_list(get_ci(res, "PreflightResults")) if isinstance(p, dict)]
            pf_table = Table(
                title=f"[bold white]Предпроверка DoH перед применением: {'[green]ПРОЙДЕНА[/]' if pf_passed else '[red]ОШИБКА[/]'}[/]",
                box=box.ROUNDED,
                expand=True,
                header_style="bold cyan",
            )
            pf_table.add_column("Домен", overflow="fold")
            pf_table.add_column("Статус", no_wrap=True)
            pf_table.add_column("HTTP", no_wrap=True)
            pf_table.add_column("Задержка", justify="right", no_wrap=True)
            pf_table.add_column("IP-адреса / Ошибка", overflow="fold")
            for pf in pf_rows:
                ok = safe_bool(get_ci(pf, "Success"))
                err = safe_str(get_ci(pf, "Error"), "")
                ips = join_list(get_ci(pf, "ARecords"), "(нет)")
                if err:
                    ips += f" [red]{err}[/]"
                pf_table.add_row(
                    safe_str(get_ci(pf, "Domain")),
                    "[green]OK[/]" if ok else "[red]FAIL[/]",
                    f"HTTP {safe_str(get_ci(pf, 'HttpStatus'), '?')} (v{safe_str(get_ci(pf, 'HttpVersion'), '?')})",
                    fmt_ms(get_ci(pf, "RttMs")),
                    ips,
                )
            if pf_rows:
                console.print(pf_table)

    # Adapters (DryRun vs Applied)
    if dry_run:
        target_dns = join_list(get_ci(res, "TargetIPv4Dns") or get_ci(prof_obj, "ipv4"))
        ad_rows = [a for a in as_list(get_ci(res, "TargetAdapters")) if isinstance(a, dict)]
        ad_table = Table(title="[bold white]Планируемые изменения адаптеров[/]", box=box.ROUNDED, expand=True, header_style="bold cyan")
        ad_table.add_column("Адаптер")
        ad_table.add_column("Было (IPv4)")
        ad_table.add_column("Станет (IPv4)")
        for ta in ad_rows:
            ad_table.add_row(
                f"{safe_str(get_ci(ta, 'Name'))} (if={safe_str(get_ci(ta, 'InterfaceIndex'))})",
                join_list(get_ci(ta, "CurrentIPv4Dns"), "(нет)"),
                f"[cyan]{target_dns}[/]",
            )
        if ad_rows:
            console.print(ad_table)

        doh_rows = [d for d in as_list(get_ci(res, "PlannedDoh")) if isinstance(d, dict)]
        if doh_rows:
            dt = Table(title="[bold white]Планируемые шаблоны Windows DoH[/]", box=box.ROUNDED, expand=True, header_style="bold cyan")
            dt.add_column("Действие", no_wrap=True)
            dt.add_column("IP-адрес", no_wrap=True)
            dt.add_column("Шаблон DoH", overflow="fold")
            for pd in doh_rows:
                dt.add_row(safe_str(get_ci(pd, "Action")), safe_str(get_ci(pd, "ServerAddress")), safe_str(get_ci(pd, "DohTemplate")))
            console.print(dt)

        planned_nrpt = as_dict(get_ci(res, "PlannedNrptCleanup"))
        if planned_nrpt:
            console.print(f"[cyan]План очистки NRPT:[/] будет создано резервное сохранение и удалено правил: {safe_str(get_ci(planned_nrpt, 'TargetCount'), '0')}.")
        elif get_ci(res, "NrptFlaggedBefore") is not None:
            console.print(f"[dim]Аудит NRPT: найдено конфликтных правил: {safe_str(get_ci(res, 'NrptFlaggedBefore'), '0')} (добавьте -CleanNrpt для очистки).[/]")
    elif applied:
        ad_updates = [a for a in as_list(get_ci(res, "AdapterUpdates")) if isinstance(a, dict)]
        if ad_updates:
            ad_table = Table(title="[bold white]Обновлённые адаптеры[/]", box=box.ROUNDED, expand=True, header_style="bold cyan")
            ad_table.add_column("Адаптер")
            ad_table.add_column("Было (IPv4)")
            ad_table.add_column("Стало (IPv4)")
            for au in ad_updates:
                ad_table.add_row(
                    f"{safe_str(get_ci(au, 'Name'))} (if={safe_str(get_ci(au, 'InterfaceIndex'))})",
                    join_list(get_ci(au, "PreviousDns"), "(нет)"),
                    f"[green]{join_list(get_ci(au, 'AppliedDns'))}[/]",
                )
            console.print(ad_table)

        doh_regs = [d for d in as_list(get_ci(res, "DohRegistrations")) if isinstance(d, dict)]
        if doh_regs:
            dt = Table(title="[bold white]Регистрация Windows DoH[/]", box=box.ROUNDED, expand=True, header_style="bold cyan")
            dt.add_column("Действие", no_wrap=True)
            dt.add_column("IP-адрес", no_wrap=True)
            dt.add_column("Метод", no_wrap=True)
            dt.add_column("Шаблон DoH", overflow="fold")
            for dr in doh_regs:
                dt.add_row(
                    safe_str(get_ci(dr, "Action")),
                    safe_str(get_ci(dr, "ServerAddress")),
                    safe_str(get_ci(dr, "Method")),
                    safe_str(get_ci(dr, "DohTemplate")),
                )
            console.print(dt)

        nrpt_res = as_dict(get_ci(res, "NrptResult"))
        if nrpt_res:
            removed = int(get_ci(nrpt_res, "RemovedCount", default=0) or 0)
            target_c = int(get_ci(nrpt_res, "TargetCount", default=0) or 0)
            rem_flagged = get_ci(nrpt_res, "RemainingFlagged")
            console.print(f"[cyan]Очистка NRPT:[/] удалено {removed}/{target_c}, осталось конфликтных: {safe_str(rem_flagged, '0')}.")

        pv = as_dict(get_ci(res, "PostVerification"))
        cf = as_dict(get_ci(res, "CacheFlush"))
        if pv or cf:
            pv_lines = []
            if cf:
                pv_lines.append(f"Сброс кэша DNS ({safe_str(get_ci(cf, 'Method'))}): [white]{safe_str(get_ci(cf, 'Message'))}[/]")
            if pv:
                pv_lines.append(
                    f"Адаптеры: {bool_ru(get_ci(pv, 'AdaptersVerified'))} · "
                    f"Шаблоны DoH: {bool_ru(get_ci(pv, 'DohTemplatesVerified'))} · "
                    f"VPN не затронут: {bool_ru(get_ci(pv, 'VpnPreserved', 'QuatroVpnPreserved'))}"
                )
                pv_lines.append("[dim]Ваш VPN-адаптер и маршруты не затрагиваются.[/]")
                sys_ips = join_list(get_ci(pv, "SystemResolveIPv4"), "(нет)")
                pv_lines.append(
                    f"Системное разрешение cloudcode-pa: {bool_ru(get_ci(pv, 'SystemResolveOk'))} "
                    f"({fmt_ms(get_ci(pv, 'SystemResolveRttMs'))}, IP: {sys_ips})"
                )
            console.print(Panel(Text.from_markup("\n".join(pv_lines)), title="[bold green]Проверка после переключения[/]", border_style="green", box=box.ROUNDED))

    warnings = [str(w) for w in as_list(get_ci(res, "Warnings")) if w]
    if warnings:
        console.print(Panel(Text("\n".join(f"• {w}" for w in warnings)), title="[bold yellow]Предупреждения[/]", border_style="yellow", box=box.ROUNDED))


def render_reset_view(console: Console, payload: dict[str, Any]) -> None:
    """Render DNS reset / rollback result card."""
    extra = as_dict(get_ci(payload, "Extra"))
    res = extra if extra else payload
    dry_run = safe_bool(get_ci(res, "DryRun"), default=safe_bool(get_ci(payload, "DryRun"), default=False))
    applied = safe_bool(get_ci(res, "Applied"), default=not dry_run)
    target_mode = safe_str(get_ci(res, "TargetMode"))

    if dry_run:
        badge = "[bold cyan][ПРЕДПРОСМОТР Dry-Run][/] План сброса DNS"
        border = "cyan"
    elif not applied:
        badge = f"[bold yellow][ПРОПУЩЕНО][/] {safe_str(get_ci(res, 'Message'), 'Сброс отменён.')}"
        border = "yellow"
    else:
        badge = "[bold green][УСПЕШНО][/] DNS адаптеров сброшен к стандартным настройкам"
        border = "green"

    vpn_preserved = get_ci(res, "VpnPreserved", "QuatroVpnPreserved")
    lines = [
        badge,
        f"Режим адаптеров: [white]{target_mode}[/] · VPN сохранён: {bool_ru(vpn_preserved) if not dry_run else '[dim]проверка в бою[/]'}",
        "[dim]Ваш VPN-адаптер и маршруты не затрагиваются; при повторном подключении VPN восстановит свои настройки DNS.[/]",
    ]
    bpath = safe_str(get_ci(res, "BackupPath"), "")
    if bpath:
        lines.append(f"Резервная копия: [cyan]{bpath}[/]")
    cf = as_dict(get_ci(res, "CacheFlush"))
    if cf:
        lines.append(f"Сброс кэша ({safe_str(get_ci(cf, 'Method'))}): [white]{safe_str(get_ci(cf, 'Message'))}[/]")

    console.print(Panel(Text.from_markup("\n".join(lines)), title="[bold white]Сброс / откат DNS[/]", border_style=border, box=box.ROUNDED))

    actions = [a for a in as_list(get_ci(res, "PlannedActions" if dry_run else "Actions")) if isinstance(a, dict)]
    if actions:
        at = Table(title="[bold white]Действия по адаптерам[/]", box=box.ROUNDED, expand=True, header_style="bold cyan")
        at.add_column("Адаптер")
        at.add_column("Было (IPv4)")
        at.add_column("Станет")
        at.add_column("Операция", no_wrap=True)
        for act in actions:
            t_dns = join_list(get_ci(act, "TargetDns"), "DHCP (автоматически)")
            at.add_row(
                f"{safe_str(get_ci(act, 'Name'))} (if={safe_str(get_ci(act, 'InterfaceIndex'))})",
                join_list(get_ci(act, "PreviousDns"), "(нет)"),
                t_dns,
                safe_str(get_ci(act, "Action")),
            )
        console.print(at)

    warnings = [str(w) for w in as_list(get_ci(res, "Warnings")) if w]
    if warnings:
        console.print(Panel(Text("\n".join(f"• {w}" for w in warnings)), title="[bold yellow]Предупреждения[/]", border_style="yellow", box=box.ROUNDED))


def render_nrpt_view(console: Console, payload: dict[str, Any]) -> None:
    """Render NRPT audit, clean, or restore result."""
    extra = as_dict(get_ci(payload, "Extra"))
    src = extra if extra else payload
    audit = as_dict(get_ci(src, "Audit"))
    if not audit and get_ci(src, "Rules") is not None:
        audit = src

    if audit:
        total = int(get_ci(audit, "TotalRules", default=0) or 0)
        flagged = int(get_ci(audit, "FlaggedCount", default=0) or 0)
        clean = int(get_ci(audit, "CleanCount", default=max(0, total - flagged)) or 0)
        summary = (
            f"Всего правил: [white]{total}[/] · "
            f"Конфликтных: [{'bold yellow' if flagged > 0 else 'bold green'}]{flagged}[/] · "
            f"Чистых: [green]{clean}[/]\n"
            f"127.0.0.53 (мёртвый): [white]{safe_str(get_ci(audit, 'DeadLocalCount'), '0')}[/] · "
            f"Xbox DNS: [white]{safe_str(get_ci(audit, 'XboxDnsCount'), '0')}[/] · "
            f"Перехват Google/Antigravity: [white]{safe_str(get_ci(audit, 'GoogleOverrideCount'), '0')}[/]"
        )
        console.print(Panel(Text.from_markup(summary), title="[bold white]Аудит правил Windows NRPT[/]", border_style="yellow" if flagged > 0 else "green", box=box.ROUNDED))

        rules = [r for r in as_list(get_ci(audit, "Rules")) if isinstance(r, dict)]
        rt = Table(title="[bold white]Правила NRPT[/]", box=box.ROUNDED, expand=True, header_style="bold cyan")
        rt.add_column("Статус", no_wrap=True)
        rt.add_column("Правило", overflow="fold")
        rt.add_column("Домены (Namespace)", overflow="fold")
        rt.add_column("Серверы DNS", overflow="fold")
        rt.add_column("Причина / Описание", overflow="fold")
        if not rules:
            rt.add_row("[green]Чисто[/]", "[dim]Правила NRPT отсутствуют[/]", "—", "—", "—")
        else:
            for r in rules:
                is_f = safe_bool(get_ci(r, "IsFlagged"))
                rt.add_row(
                    "[yellow]КОНФЛИКТ[/]" if is_f else "[green]ЧИСТО[/]",
                    safe_str(get_ci(r, "Name")),
                    join_list(get_ci(r, "Namespace")),
                    join_list(get_ci(r, "NameServers")),
                    join_list(get_ci(r, "Reasons"), safe_str(get_ci(r, "DisplayName"), "—")),
                )
        console.print(rt)
        return

    # Clean or restore output
    dry_run = safe_bool(get_ci(src, "DryRun"), default=safe_bool(get_ci(payload, "DryRun"), default=False))
    is_restore = get_ci(src, "BackupRuleCount", "AddedCount", "WouldAddCount") is not None
    if is_restore:
        title = "[bold white]Восстановление правил NRPT[/]"
        text = (
            f"{'[cyan][Dry-Run][/] ' if dry_run else '[green][OK][/] '}Файл: [cyan]{safe_str(get_ci(src, 'BackupPath'))}[/]\n"
            f"Правил в копии: {safe_str(get_ci(src, 'BackupRuleCount'), '0')} · "
            f"Добавлено/будет: {safe_str(get_ci(src, 'WouldAddCount' if dry_run else 'AddedCount'), '0')} · "
            f"Удалено/будет: {safe_str(get_ci(src, 'WouldRemoveCount' if dry_run else 'RemovedCount'), '0')} · "
            f"Пропущено: {safe_str(get_ci(src, 'WouldSkipCount' if dry_run else 'SkippedCount'), '0')}"
        )
        console.print(Panel(Text.from_markup(text), title=title, border_style="cyan" if dry_run else "green", box=box.ROUNDED))
    else:
        target_cnt = int(get_ci(src, "TargetCount", default=0) or 0)
        removed_cnt = int(get_ci(src, "RemovedCount", default=0) or 0)
        rem_flagged = get_ci(src, "RemainingFlagged")
        if dry_run:
            header = f"[cyan][Dry-Run][/] К удалению помечено правил: [bold]{target_cnt}[/] из {safe_str(get_ci(src, 'TotalRules', 'TotalBefore'), '0')}"
            border = "cyan"
        elif target_cnt == 0:
            header = "[green][OK][/] Устаревших или конфликтующих правил NRPT не найдено."
            border = "green"
        else:
            header = f"[green][OK][/] Удалено правил NRPT: [bold]{removed_cnt}/{target_cnt}[/]. Осталось конфликтных: {safe_str(rem_flagged, '0')}"
            border = "green"
        bpath = safe_str(get_ci(src, "BackupPath"), "")
        if bpath:
            header += f"\nРезервная копия: [cyan]{bpath}[/]"
        console.print(Panel(Text.from_markup(header), title="[bold white]Очистка правил NRPT[/]", border_style=border, box=box.ROUNDED))

        rule_list = [r for r in as_list(get_ci(src, "PlannedRules" if dry_run else "RemovedRules")) if isinstance(r, dict)]
        if rule_list:
            rt = Table(box=box.ROUNDED, expand=True, header_style="bold cyan")
            rt.add_column("Правило", overflow="fold")
            rt.add_column("Домены", overflow="fold")
            rt.add_column("Серверы DNS", overflow="fold")
            if dry_run:
                rt.add_column("Причина", overflow="fold")
            for rr in rule_list:
                ns = join_list(get_ci(rr, "Namespace")) if isinstance(get_ci(rr, "Namespace"), list) else safe_str(get_ci(rr, "Namespace"))
                srv = join_list(get_ci(rr, "NameServers")) if isinstance(get_ci(rr, "NameServers"), list) else safe_str(get_ci(rr, "NameServers"))
                if dry_run:
                    rt.add_row(safe_str(get_ci(rr, "Name")), ns, srv, safe_str(get_ci(rr, "Reasons")))
                else:
                    rt.add_row(safe_str(get_ci(rr, "Name")), ns, srv)
            console.print(rt)

    errs = [str(e) for e in as_list(get_ci(src, "Errors")) if e]
    if errs:
        console.print(Panel(Text("\n".join(f"• {e}" for e in errs)), title="[bold red]Ошибки[/]", border_style="red", box=box.ROUNDED))


def render_backups_view(console: Console, payload: dict[str, Any]) -> None:
    """Render backups list, save, or restore result."""
    extra = as_dict(get_ci(payload, "Extra"))
    src = extra if extra else payload

    if get_ci(src, "Backups") is not None:
        items = [b for b in as_list(get_ci(src, "Backups")) if isinstance(b, dict)]
        bdir = safe_str(get_ci(src, "BackupDir"), "backups\\")
        bt = Table(
            title=f"[bold white]Резервные копии DNS ({bdir}, всего: {len(items)})[/]",
            box=box.ROUNDED,
            expand=True,
            header_style="bold cyan",
        )
        bt.add_column("№", justify="right", width=3, no_wrap=True)
        bt.add_column("Статус", no_wrap=True)
        bt.add_column("Файл", overflow="fold")
        bt.add_column("Метка", overflow="fold")
        bt.add_column("Содержимое", no_wrap=True)
        bt.add_column("Создана", no_wrap=True)

        if not items:
            bt.add_row("—", "[dim]Пусто[/]", "[dim]Резервных копий пока нет[/]", "—", "—", "—")
        else:
            for idx, b in enumerate(items, start=1):
                valid = safe_bool(get_ci(b, "IsValid"), default=True)
                content = f"Адаптеры:{safe_str(get_ci(b, 'AdapterCount'), '0')} DoH:{safe_str(get_ci(b, 'DohServerCount'), '0')} NRPT:{safe_str(get_ci(b, 'NrptRuleCount'), '0')}"
                bt.add_row(
                    str(idx),
                    "[green]VALID[/]" if valid else "[red]INVALID[/]",
                    safe_str(get_ci(b, "FileName", "FullName")),
                    safe_str(get_ci(b, "Label")),
                    content,
                    safe_str(get_ci(b, "CreatedAt")),
                )
        console.print(bt)
        return

    if get_ci(src, "Backup") is not None or get_ci(src, "AdapterCount") is not None:
        bobj = as_dict(get_ci(src, "Backup")) or src
        dry_run = safe_bool(get_ci(src, "DryRun"), default=safe_bool(get_ci(payload, "DryRun"), default=False))
        prefix = "[cyan][Dry-Run][/] Будет создана копия" if dry_run else "[green][OK][/] Резервная копия сохранена"
        info = (
            f"{prefix}\n"
            f"Путь: [cyan]{safe_str(get_ci(bobj, 'BackupPath', 'BackupDir'))}[/]\n"
            f"Метка: [white]{safe_str(get_ci(bobj, 'Label'))}[/] · "
            f"Адаптеры: {safe_str(get_ci(bobj, 'AdapterCount'), '0')} · "
            f"DoH: {safe_str(get_ci(bobj, 'DohServerCount'), '0')} · "
            f"NRPT: {safe_str(get_ci(bobj, 'NrptRuleCount'), '0')}"
        )
        console.print(Panel(Text.from_markup(info), title="[bold white]Создание резервной копии[/]", border_style="cyan" if dry_run else "green", box=box.ROUNDED))
        return

    # Restore result
    dry_run = safe_bool(get_ci(src, "DryRun"), default=safe_bool(get_ci(payload, "DryRun"), default=False))
    executed = safe_bool(get_ci(src, "Executed"), default=False)
    bpath = safe_str(get_ci(src, "BackupPath"))
    if dry_run:
        head = f"[cyan][Dry-Run][/] Предпросмотр восстановления из: [cyan]{bpath}[/]"
        border = "cyan"
    elif executed:
        head = f"[green][OK][/] Состояние DNS восстановлено из: [cyan]{bpath}[/]"
        border = "green"
    else:
        head = f"[yellow][ПРЕДУПРЕЖДЕНИЕ][/] Восстановление из [cyan]{bpath}[/] завершилось с ошибками"
        border = "yellow"
    console.print(Panel(Text.from_markup(head), title="[bold white]Восстановление из резервной копии[/]", border_style=border, box=box.ROUNDED))

    ad_list = [a for a in as_list(get_ci(src, "AdapterActions" if dry_run else "AdapterResults")) if isinstance(a, dict)]
    if ad_list:
        at = Table(title="[bold white]Адаптеры[/]", box=box.ROUNDED, expand=True, header_style="bold cyan")
        at.add_column("Адаптер")
        at.add_column("Действие")
        at.add_column("DNS (IPv4)")
        for aa in ad_list:
            at.add_row(
                safe_str(get_ci(aa, "AdapterName", "Name")),
                safe_str(get_ci(aa, "Action", "Status")),
                join_list(get_ci(aa, "TargetDns", "AppliedDns"), "DHCP"),
            )
        console.print(at)

    errs = [str(e) for e in as_list(get_ci(src, "Errors")) if e]
    if errs:
        console.print(Panel(Text("\n".join(f"• {e}" for e in errs)), title="[bold red]Ошибки[/]", border_style="red", box=box.ROUNDED))


def render_help_view(console: Console, payload: dict[str, Any]) -> None:
    """Render Russian help guide with CLI commands and safety guarantees."""
    console.print(
        Panel(
            Text.from_markup(
                "[bold white]Мастер DNS и нативного DoH для Windows 11 (Antigravity / Google AI + любой VPN)[/]\n"
                "[dim]Подбирает и применяет проверенный DNS-over-HTTPS (TCP:443) как с VPN, так и при прямом подключении.[/]\n"
                "[dim]Ваш VPN-адаптер и маршруты не затрагиваются; DoH (TCP:443) обходит перехват порта 53 на TUN-адаптерах.[/]"
            ),
            title="[bold white]Справка[/]",
            border_style="bright_cyan",
            box=box.ROUNDED,
        )
    )

    cmd_table = Table(title="[bold white]Команды CLI[/]", box=box.ROUNDED, expand=True, header_style="bold cyan")
    cmd_table.add_column("Команда", style="bold white", overflow="fold")
    cmd_table.add_column("Описание", overflow="fold")
    commands = [
        ("dns-switch.ps1", "Запустить интерактивное меню с живой проверкой"),
        ("dns-switch.ps1 status [-Json]", "Показать статус VPN, адаптеров, DoH и NRPT"),
        ("dns-switch.ps1 list [-Category <cat>]", "Список профилей (all | vpn-clean | rf-smart | rf-clean)"),
        ("dns-switch.ps1 probe [-Target <id>] [-All] [-Quick]", "Проверить доступность DoH и сертификаты TLS (только чтение)"),
        ("dns-switch.ps1 switch <id> [-CleanNrpt] [-DryRun]", "Включить выбранный DNS + нативный Windows DoH"),
        ("dns-switch.ps1 reset [-DryRun]", "Сбросить DNS адаптеров на DHCP / настройки VPN по умолчанию"),
        ("dns-switch.ps1 nrpt <status|clean|restore>", "Проверить, очистить или восстановить правила NRPT"),
        ("dns-switch.ps1 backups <list|save|restore>", "Управление JSON-копиями настроек DNS/DoH/NRPT"),
    ]
    for cmd, desc in commands:
        cmd_table.add_row(cmd, desc)
    console.print(cmd_table)

    safety = (
        "• Ваш VPN-адаптер и маршруты не затрагиваются: инструмент никогда не отключает и не перезапускает VPN.\n"
        "• Перед любым изменением автоматически сохраняется полная резервная копия в папку backups\\.\n"
        "• Перед переключением выполняется живая проверка DoH (Preflight), чтобы не применить нерабочий сервер.\n"
        "• В режиме [D] (или с флагом -DryRun) показывается полный предпросмотр без прав администратора и без записи."
    )
    console.print(Panel(Text(safety), title="[bold green]Гарантии безопасности[/]", border_style="green", box=box.ROUNDED))


VIEW_RENDERERS = {
    "menu": render_menu_view,
    "status": render_status_view,
    "probe": render_probe_view,
    "switch": render_switch_view,
    "reset": render_reset_view,
    "nrpt": render_nrpt_view,
    "backups": render_backups_view,
    "help": render_help_view,
}


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Rich Russian console renderer for dns_switcher.")
    parser.add_argument(
        "--view",
        choices=sorted(VIEW_RENDERERS.keys()),
        default="menu",
        help="Target view to render.",
    )
    parser.add_argument("--input", dest="input_path", default=None, help="Optional path to UTF-8 JSON payload.")
    parser.add_argument("--width", type=int, default=None, help="Optional console width override.")
    parser.add_argument("--no-color", action="store_true", help="Disable ANSI colors.")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    configure_stdio()
    args = parse_args(argv)
    console = build_console(width=args.width, no_color=args.no_color)
    try:
        payload = load_payload(args.input_path)
    except Exception as exc:
        console.print(
            Panel(
                Text(f"Не удалось прочитать входной JSON: {exc}"),
                title="[bold red]Ошибка UI[/]",
                border_style="red",
                box=box.ROUNDED,
            )
        )
        return 1

    renderer = VIEW_RENDERERS[args.view]
    renderer(console, payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
