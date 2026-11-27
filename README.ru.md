[English](README.md) | **Русский** · [Релизы](https://github.com/hiez1337/win-doh-dns-switcher/releases)

# Мастер DNS и нативного DoH для Windows 11 (`dns_switcher`)

[![GitHub Release](https://img.shields.io/github/v/release/hiez1337/win-doh-dns-switcher)](https://github.com/hiez1337/win-doh-dns-switcher/releases/latest)
[![Platform: Windows 11](https://img.shields.io/badge/Platform-Windows%2011-0078D4?logo=windows11&logoColor=white)](https://www.microsoft.com/windows/windows-11)
[![PowerShell: 5.1 & 7+](https://img.shields.io/badge/PowerShell-5.1%20%26%207%2B-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![UI: Python Rich TUI](https://img.shields.io/badge/UI-Python%20Rich%20TUI-3776AB?logo=python&logoColor=white)](ui/rich_ui.py)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Утилита для быстрого и безопасного переключения DNS и нативного DNS-over-HTTPS (DoH) в Windows 11 без фоновых прокси-демонов. Обеспечивает стабильную работу Antigravity, Google AI (`gemini.google.com`, `aistudio.google.com`, `generativelanguage.googleapis.com`) и авторизации Google — как **поверх любого VPN**, так и **напрямую без VPN**.

---

## Зачем нужен этот инструмент

- **Нативный IPv4 DoH в Windows 11 (`dnscache` поверх HTTP/2)**: Настраивает системные шаблоны IPv4 DoH средствами ОС (`Add-DnsClientDohServerAddress` / `Set-DnsClientDohServerAddress` с fallback на `netsh dns`) без установки сторонних фоновых DNS-форвардеров. Служба `dnscache` в Windows 11 поддерживает **HTTP/2**, что критично для резолверов `Quad9`, `DNS-AI`, `Malw` и `Yandex.DNS`, которые отклоняют HTTP/1.1 (HTTP 505 или сброс соединения).
- **Живой бенчмарк доступности 12 проверенных резолверов**: Параллельно проверяет DoH-доступность по ключевым доменам `cloudcode-pa.googleapis.com`, `daily-cloudcode-pa.googleapis.com` и `antigravity.google` (а в режиме `probe` — по всем 16 доменам со строгой проверкой TLS-сертификатов) и формирует топ-3 рекомендаций под текущую сеть:
  - **`vpn-clean`** (7 профилей): чистые публичные DoH-резолверы для работы поверх VPN или в сетях без блокировок.
  - **`rf-smart`** (4 профиля): Smart-DNS резолверы для прямого доступа к AI/Antigravity из РФ без VPN.
  - **`rf-clean`** (1 профиль): отечественный чистый DoH (`Yandex.DNS Basic`), устойчивый к ТСПУ.
- **Автоматическая очистка конфликтов NRPT**: Проводит аудит и безопасно удаляет устаревшие правила таблицы политики разрешения имён Windows (NRPT) — например, мёртвый локальный форвардер `127.0.0.53` (дающий задержки 189–991 мс на таймаутах), заблокированный Xbox DNS (`111.88.96.54–57`) или остатки прошлых DNS-утилит — предварительно сохраняя полную резервную копию.

---

## Универсальная поддержка VPN и прямого подключения

- **Автоматическое обнаружение любых VPN и туннелей**: Распознаёт активные адаптеры VPN/TUN/TAP (`sing-tun`, `wintun`, `WireGuard`, `OpenVPN`, `TAP-Windows`, `utun`, `Amnezia`, `NekoRay`/`NekoBox`, `Hiddify`, `v2ray`/`xray`, `Clash`/`Mihomo`, `Outline`, `WARP`, `Proton`, `Tailscale`, `NordLynx`, `IKEv2`/`SSTP`/`L2TP`), а также встроенные RAS VPN-подключения Windows (`Get-VpnConnection`).
- **Никакого вмешательства в работу VPN**: Инструмент никогда не останавливает, не отключает, не перезапускает службы VPN и не меняет маршруты туннеля.
- **Обход перехвата порта 53 на TUN-адаптерах**: Многие TUN-клиенты перехватывают весь трафик на UDP/TCP:53 (`hijack-dns`). Поскольку нативный DoH Windows работает по **TCP:443 (HTTPS)**, запросы обходят перехват 53-го порта и подмену DNS провайдером.
- **Прямой режим (без установленного или активного VPN)**: Когда VPN выключен или отсутствует, `dns_switcher` чисто работает с физическими адаптерами Ethernet/Wi-Fi без лишних предупреждений и предлагает профили `rf-smart` / `rf-clean`.

---

## Проверенные профили DNS

Все 12 профилей, 16 контрольных доменов и 17 исключённых IP-адресов описаны декларативно в [config/profiles.json](config/profiles.json) и валидируются по схеме [config/profiles.schema.json](config/profiles.schema.json).

### 1. `vpn-clean` — Чистые публичные DoH-резолверы (`AllowFallbackToUdp=false`)

Чистые публичные резолверы без сторонних SNI-прокси. Рекомендуются при включённом VPN или в открытых сетях.

| ID | Название | IPv4 | DoH-шаблон | Примечание |
| :--- | :--- | :--- | :--- | :--- |
| `cloudflare` | Cloudflare Unfiltered | `1.1.1.1`, `1.0.0.1` | `https://cloudflare-dns.com/dns-query` | **#1 для VPN ON**, 16/16 `CLEAN_GOOGLE` |
| `google` | Google Public DNS | `8.8.8.8`, `8.8.4.4` | `https://dns.google/dns-query` | **#2 для VPN ON**, 16/16 `CLEAN_GOOGLE` |
| `controld-p0` | Control D Free Unfiltered (p0) | `76.76.2.0`, `76.76.10.0` | `https://freedns.controld.com/p0` | **#3 для VPN ON**, без логов и фильтрации |
| `controld-p2` | Control D Free Adblock (p2) | `76.76.2.2`, `76.76.10.2` | `https://freedns.controld.com/p2` | Блокировка рекламы и трекеров, 16/16 `CLEAN_GOOGLE` |
| `quad9` | Quad9 Secured | `9.9.9.9`, `149.112.112.112` | `https://dns.quad9.net/dns-query` | Защита от вредоносных сайтов + DNSSEC; **требует HTTP/2** |
| `adguard-unfiltered` | AdGuard DNS Unfiltered | `94.140.14.140`, `94.140.14.141` | `https://unfiltered.adguard-dns.com/dns-query` | Приватный, без фильтрации (резерв) |
| `dns-sb` | DNS.SB | `185.222.222.222`, `45.11.45.11` | `https://doh.dns.sb/dns-query` | Зарубежный резервный без фильтрации |

### 2. `rf-smart` — Smart-DNS для доступа к AI без VPN (`AllowFallbackToUdp=true`)

> [!IMPORTANT]
> **Предупреждение о доверии (SNI / CNAME-прокси)**: Smart-DNS резолверы возвращают IP-адреса своих релеев (или CNAME-пулы) для выбранных доменов AI/Antigravity и пересылают TLS-трафик через SNI-прокси. Сквозной TLS по-прежнему проверяет подлинные сертификаты Google (подмена содержимого исключена), **но оператор Smart-DNS видит ваш IP-адрес и SNI-имена доменов, а также контролирует доступность релеев.** При необходимости максимальной приватности используйте VPN + `vpn-clean`.

| ID | Название | IPv4 | DoH-шаблон | Покрытие доменов (из 16) и особенности |
| :--- | :--- | :--- | :--- | :--- |
| `geohide` | GeoHide Smart-DNS | `37.230.192.51`, `193.233.112.88` | `https://dns.geohide.ru/dns-query` | **8/16** (`antigravity.google`, `antigravity-pa`, `antigravity.googleapis.com`, `daily-cloudcode-pa`, `antigravity-unleash.goog`, `generativelanguage`, `gemini`, `aistudio`). *Не добавляйте `159.194.200.33` как DNS-сервер — это целевой IP SNI-релея.* |
| `dns-ai` | DNS-AI Smart-DNS | `194.87.196.13`, `45.151.102.219` | `https://dns-ai.ru/dns-query` | **5/16** (`cloudcode-pa`, `daily-cloudcode-pa`, `generativelanguage`, `gemini`, `aistudio`). **Требует HTTP/2**. |
| `comss` | Comss.one DNS | `141.133.184.24`, `155.212.172.101`, `141.133.183.77` | `https://dns.comss.one/dns-query` | **3/16** через CNAME-пулы (`generativelanguage`, `gemini`, `aistudio`) + блокировка рекламы AdGuard/AdAway. Не проксирует `antigravity.google` и `cloudcode-pa`. |
| `malw` | Malw Smart-DNS | `179.254.166.171`, `164.5.224.81` | `https://dns.malw.link/dns-query` | **6/16** (`antigravity.google`, `daily-cloudcode-pa`, `antigravity-unleash.goog`, `generativelanguage`, `gemini`, `aistudio`). **Требует HTTP/2**; повышенная задержка (~899 мс). |

### 3. `rf-clean` — Отечественный чистый DoH (`AllowFallbackToUdp=true`)

| ID | Название | IPv4 | DoH-шаблон | Примечание |
| :--- | :--- | :--- | :--- | :--- |
| `yandex` | Yandex.DNS Basic | `77.88.8.1`, `77.88.8.8` | `https://common.dot.dns.yandex.net/dns-query` | Без сторонних SNI-прокси, высокая устойчивость к ТСПУ; **требует HTTP/2** (хост `common.doh.dns.yandex.net` возвращает `NXDOMAIN`, поэтому используется проверенный `common.dot.dns.yandex.net`). Не снимает гео-ограничения Google AI без VPN. |

### Почему исключены `Xbox DNS` и устаревшие IP (`deprecated_or_blocked`)

- **Xbox DNS (`111.88.96.54–57`)**: возвращает `0.0.0.0` (`BLOCKED`) для `generativelanguage.googleapis.com`, `gemini.google.com` и `aistudio.google.com` (`111.88.96.54` также падает с `SSLEOFError` на DoT).
- **Устаревшие / нерабочие IP Comss.one**: `92.38.153.185` (просроченный сертификат `joy-jet.com`), `91.230.211.67` (чужой сертификат `dash.hmax.name`), `83.220.169.155` (самоподписанный `for.test`), а также не отвечающие по таймауту `92.223.109.31`, `212.109.195.93`, `109.73.193.146`, `93.115.24.204`.
- **Прочие нерабочие адреса**: `127.0.0.53` (мёртвый локальный DNS-форвардер), `45.155.204.190` (устаревший нерабочий NRPT IP), `AstraCAT` (`135.106.217.200`, `144.31.151.64` — таймаут / TLS EOF), `Mullvad DNS` (`194.242.2.2` — сервис закрыт 2 ноября 2026 года), `159.194.200.33` (только SNI-релей GeoHide, а не DNS-сервер).

---

## Быстрый старт и интерактивное Rich-меню

### Требования

- **ОС**: Windows 11 (нативная поддержка IPv4 DoH).
- **Оболочка**: встроенный Windows PowerShell 5.1 или PowerShell 7+ (`pwsh.exe`).
- **Опциональный Rich TUI**: Python 3 с библиотекой `rich` (`pip install rich`). Автоматически включает обработку VT-последовательностей (`ENABLE_VIRTUAL_TERMINAL_PROCESSING`) и флаг `--force-color`, сохраняя полноцветный вывод в Windows Terminal и `conhost.exe` на PowerShell 5.1 и 7+. Отключить цвета можно переменной `NO_COLOR=1`, а флагом `-NoRich` (или без установленного `rich`) скрипт переключается на чистый текстовый вывод PowerShell.

### Запуск

Запустите двойным кликом [dns-switch.cmd](dns-switch.cmd) или из терминала:

```bat
.\dns-switch.cmd
```

Либо напрямую через PowerShell:

```powershell
.\dns-switch.ps1
# Принудительно без Rich UI (чистый текстовый вывод PowerShell):
.\dns-switch.ps1 -NoRich
```

### Возможности интерактивного меню

При запуске без аргументов `.\dns-switch.ps1` открывает интерактивную панель (интерфейс через [ui/rich_ui.py](ui/rich_ui.py)):

1. **Автоматическая живая проверка при старте**: При открытии меню запускается `Get-LiveDnsAvailability` — параллельная проверка всех 12 профилей по доменам `cloudcode-pa.googleapis.com`, `daily-cloudcode-pa.googleapis.com` и `antigravity.google` (таймаут 3 с; результат кэшируется на время сеанса).
2. **Панель «Рекомендуем прямо сейчас»**: Показывает топ-3 доступных профиля для текущего состояния VPN (по живым замерам `RecommendedIds` с задержкой в мс либо по статическому резерву при отсутствии сети).
3. **Однострочная таблица всех 12 профилей DNS**: Использует облегчённую сетку без лишних рамок (`box.SIMPLE_HEAD`) с разделителем групп `── Без VPN (РФ) ──` между `vpn-clean` и `rf-smart`/`rf-clean`, объединённый столбец **Статус** (`● OK · 56 мс`, `▲ Частично · 95 мс`, `✕ Офлайн`, `○ Не проверен`), краткое назначение и бейдж доверия (`Чистый DoH`, `DoH + защита`, `DoH + AdBlock`, `SNI-прокси`, `CNAME/AdBlock`, `РФ · Чистый`).
4. **Адаптивная ширина и сохранение ANSI-цветов**: Автоматически считывает ширину консоли (`72..140` столбцов) — при ширине `< 95` скрывает столбец «Назначение» и теги `({id})` в рекомендациях, при `< 100` перестраивает верхние карточки `status` друг под другом, а выровненную сетку действий 3×3 при `< 80` переводит в 2 столбца. Включение `ENABLE_VIRTUAL_TERMINAL_PROCESSING` и `--force-color` сохраняет цвета даже через пайп PowerShell в Windows Terminal и `conhost.exe` (отключается через `-NoRich` или `NO_COLOR=1`).
5. **Выровненная сетка действий 3×3**:
   - `1–12` — выбрать и применить профиль DNS + нативный IPv4 DoH Windows 11.
   - `[C]` — повторить живую параллельную проверку доступности всех 12 профилей.
   - `[P]` — подробная диагностика (`probe`) со строгой проверкой сертификатов TLS.
   - `[N]` — аудит, очистка и восстановление правил Windows NRPT.
   - `[R]` — сброс DNS к настройкам по умолчанию (DHCP / настройки VPN) или восстановление из бэкапа.
   - `[B]` — просмотр и создание резервных копий.
   - `[D]` — переключение режима предпросмотра (`Dry-Run`) без сброса кэша доступности.
   - `[S]` — обновить статус без повторного пробинга.
   - `[Q]` — выход (во всех подменю также работает мгновенный возврат по `[B]` или пустому `Enter`).

---

## Справочник CLI и примеры

### Команды

| Команда | Назначение и основные флаги |
| :--- | :--- |
| `status [-Json] [-NoRich]` | Показывает состояние VPN/туннелей, DNS на адаптерах, шаблоны IPv4/IPv6 DoH и сводку аудита NRPT. |
| `list [-Category <all\|vpn-clean\|rf-smart\|rf-clean>] [-Json]` | Список профилей с IPv4, DoH-шаблоном, флагом HTTP/2 и примечаниями о доверии. |
| `check [-Json] [-NoRich]` *(алиас: `availability`)* | Быстрая параллельная живая проверка всех 12 профилей и расчёт топ-3 рекомендаций с учётом VPN. |
| `probe [-Target <id>] [-Category <cat>] [-All] [-Quick] [-Availability] [-Json] [-NoRich]` | Живая read-only проверка DoH + строгая TLS-валидация (`-Quick`: 5 ключевых доменов, 1 замер; `-Availability`: матрица как `check`). |
| `switch <profileId> [флаги]` | Переключение DNS + регистрация нативного IPv4 DoH Windows 11. Флаги: `-TargetMode <auto\|vpn\|ethernet\|both\|custom>`, `-AdapterNames <имена>`, `-AllowUdpFallback <auto\|true\|false>`, `-CleanNrpt`, `-SkipPreflight`, `-DryRun`, `-NoElevate`, `-Json`, `-NoRich`. |
| `reset [флаги]` | Возвращает DNS адаптеров к настройкам по умолчанию (DHCP на физических NIC; стандартный сброс на активном VPN без изменения маршрутов). Флаги: `-TargetMode`, `-AdapterNames`, `-DryRun`, `-NoElevate`, `-Json`, `-NoRich`. |
| `nrpt [<status\|clean\|restore>] [-BackupPath <путь>] [-ReplaceExisting] [-DryRun] [-NoElevate] [-Json] [-NoRich]` | Аудит правил NRPT, резервное копирование и удаление конфликтных правил (`127.0.0.53`, Xbox DNS, устаревшие IP) или восстановление из бэкапа. |
| `backups [<list\|save\|restore>] [-BackupPath <путь>] [-Label <текст>] [-SkipNrpt] [-SkipDohTemplates] [-DryRun] [-NoElevate] [-Json] [-NoRich]` | Просмотр, создание и полный откат атомарных снимков состояния (DNS адаптеров + DoH-шаблоны + NRPT) в папке `backups\`. |
| `help [-Json] [-NoRich]` | Справка по командам и гарантиям безопасности. |

### Примеры использования

```powershell
# Живая параллельная проверка доступности всех 12 профилей
.\dns-switch.ps1 check
.\dns-switch.ps1 probe -Availability

# Проверка текущего состояния VPN, DNS, DoH и поиск старых правил NRPT
.\dns-switch.ps1 status
.\dns-switch.ps1 status -NoRich
.\dns-switch.ps1 nrpt status -Json

# Быстрый тест Cloudflare DoH + строгая проверка TLS (без изменений в системе)
.\dns-switch.ps1 probe -Target cloudflare -Quick

# Предпросмотр переключения DNS + очистки NRPT (без UAC и без записи)
.\dns-switch.ps1 switch cloudflare -CleanNrpt -DryRun

# Применение Cloudflare DoH с авто-очисткой старых правил NRPT (запросит UAC при необходимости)
.\dns-switch.ps1 switch cloudflare -CleanNrpt

# Переключение на GeoHide Smart-DNS только для физического Ethernet/Wi-Fi (без VPN)
.\dns-switch.ps1 switch geohide -TargetMode ethernet

# Предпросмотр сброса DNS или отката из сохранённого бэкапа
.\dns-switch.ps1 reset -DryRun
.\dns-switch.ps1 backups list
.\dns-switch.ps1 backups restore -BackupPath .\backups\dns-backup-20261126-000000-manual.json -DryRun
```

---

## Гарантии безопасности и приватности

- **Pre-flight проверка DoH перед применением**: Команда `switch` сначала проверяет живую доступность DoH целевого профиля (если не указан `-SkipPreflight`), чтобы исключить переключение на нерабочий сервер.
- **Атомарные локальные бэкапы (`backups/`)**: Перед любым изменением (`switch`, `reset`, `nrpt clean`) автоматически сохраняется UTF-8 JSON-снимок настроек адаптеров, шаблонов DoH и правил NRPT в каталог `backups/` (добавлен в [.gitignore](.gitignore)).
- **Безопасный режим `-DryRun` и `-WhatIf`**: Все изменяющие команды (`switch`, `reset`, `nrpt clean`, `nrpt restore`, `backups save`, `backups restore`) поддерживают предпросмотр без прав администратора и без записи в реестр или сетевые настройки.
- **Авто-UAC с ретрансляцией вывода (`-ElevationLogPath`)**: Команды чтения и `-DryRun` работают с обычными правами. Изменяющие команды автоматически запрашивают повышение прав UAC (отключается флагом `-NoElevate`) и передают временный `-ElevationLogPath`: повышенный дочерний процесс сохраняет свой лог, ошибки или JSON-результат в этот файл, а родительская консоль выводит полный отчёт и код возврата.
- **Ноль телеметрии**: Все проверки выполняются напрямую с вашего ПК к выбранным DNS/DoH-серверам без внешней аналитики и сбора данных.

---

## Структура проекта и запуск тестов

```text
dns_switcher/
├── .github/workflows/ci.yml       # CI: чистый ASCII, AST для PS 5.1 и 7, JSON Schema, py_compile, unit-тесты
├── .gitignore                     # Исключает backups/, __pycache__/, логи и временные файлы
├── LICENSE                        # Лицензия MIT
├── README.md                      # Документация на английском (основная)
├── README.ru.md                   # Документация на русском
├── dns-switch.cmd                 # Лаунчер (автовыбор pwsh.exe 7+ или powershell.exe 5.1)
├── dns-switch.ps1                 # Главный CLI и интерактивное меню
├── config/
│   ├── profiles.json              # 12 профилей, 16 тестовых доменов, 17 исключённых IP
│   └── profiles.schema.json       # JSON Schema для валидации profiles.json
├── lib/
│   ├── DnsCommon.psm1             # Универсальный детект VPN/TUN/RAS, снимки адаптеров, UAC elevation
│   ├── DnsBackupAndNrpt.psm1      # Атомарные JSON-бэкапы и аудит/очистка/восстановление NRPT
│   ├── DnsProbe.psm1              # Живой DoH-пробинг, строгий TLS-чек, параллельная проверка
│   └── DnsSwitcher.psm1           # Выбор адаптеров, регистрация DoH Windows 11, switch и reset
├── ui/
│   └── rich_ui.py                 # Опциональный Rich TUI рендерер (8 режимов --view, --width, --force-color, --color-system, --no-color)
├── backups/                       # Локальные JSON-снимки состояния (создаются при работе, в gitignore)
└── tests/
    ├── run-tests.ps1              # Единый раннер тестов (all | unit | integration)
    ├── TestHarness.ps1            # Общий каркас ассертов и запуска процессов
    ├── unit-config.ps1            # Юнит-тесты конфигурации и JSON-схемы (9 тестов)
    ├── unit-lib.ps1               # Юнит-тесты модулей lib\*.psm1 (20 тестов)
    └── integration-cli.ps1        # Интеграционные read-only/DryRun тесты CLI (33 теста)
```

### Запуск тестов

Запустить полный набор из 62 тестов (`9` config + `20` lib + `33` CLI-интеграция) можно как в PowerShell 7+ (`pwsh`), так и в Windows PowerShell 5.1 (`powershell`):

```powershell
.\tests\run-tests.ps1
# Либо выборочно:
.\tests\run-tests.ps1 -Suite unit
.\tests\run-tests.ps1 -Suite integration
```

Конвейер GitHub Actions CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) автоматически проверяет чистую ASCII-кодировку (`.ps1`, `.psm1`, `config/*.json`), отсутствие ошибок AST в `pwsh` 7 и `powershell` 5.1, валидацию JSON Schema, `python -X utf8 -m py_compile ui/rich_ui.py` и выполнение `.\tests\unit-config.ps1`.

---

## История версий

- **v1.0.1** — Разгруженный макет Rich TUI и сохранение ANSI-цветов и ширины консоли:
  - В `ui/rich_ui.py` переработана таблица 12 профилей в компактный однострочный вид с объединённым статусом/задержкой, разделителем `── Без VPN (РФ) ──`, выровненной сеткой действий 3×3 и адаптацией под ширину (`< 95`, `< 80`, `< 100` столбцов).
  - Добавлены `--force-color`, `--color-system`, поддержка `FORCE_COLOR`, ограничение ширины `72..140` столбцов и включение Win32 VT (`ENABLE_VIRTUAL_TERMINAL_PROCESSING` через `Enable-ConsoleVirtualTerminal`) в `dns-switch.ps1` для корректного цветного вывода в Windows Terminal и `conhost.exe` на PowerShell 5.1 и 7+.
- **v1.0.0** — Первый релиз:
  - Нативный переключатель IPv4 DoH для Windows 11 (`dns-switch.ps1` / `dns-switch.cmd`), 12 проверенных профилей (`vpn-clean`, `rf-smart`, `rf-clean`), универсальный детект VPN/TUN/RAS, параллельная живая проверка, строгий TLS `probe`, аудит/очистка NRPT, атомарные JSON-бэкапы, авто-UAC с ретрансляцией лога/JSON, опциональный Rich TUI и 62 теста под PS 5.1 и 7+.

---

## Лицензия

Распространяется по [лицензии MIT](LICENSE).
