# iSim-mcp — план

MCP-сервер на Swift для управления iOS-устройствами — **симуляторами и физическими iPhone/iPad**: устройства, приложения, скриншоты, ввод (тапы, свайпы, текст), дерево accessibility, системные настройки, логи, сборка. Нужен, чтобы агент (Claude Code, Cursor и т.п.) мог сам запускать приложение, смотреть на экран и проходить сценарии без ручной работы.

## 0. Принятые решения

| Вопрос | Решение |
|---|---|
| Версии Xcode | Только **Xcode 27 и новее**. Старые пути и сигнатуры приватных фреймворков не поддерживаем |
| Физические устройства | **Да**, с полноценным вводом и инспекцией UI через агента на XCUITest (раздел 3) |
| Платформы | Только **iOS/iPadOS** |
| Сборка проекта | **Да**, отдельная группа `build` (раздел 5.10). Обёртка над `xcodebuild` всё равно нужна, чтобы собирать агента для iPhone, а агенту одна команда «собери, установи, запусти» удобнее, чем разбирать тысячи строк лога `xcodebuild` |
| Дистрибуция | Локальная сборка: `swift build -c release` + `make install`. Homebrew — потом, если понадобится |

## 1. Контекст

### Что умеют стандартные инструменты (проверено на Xcode 27.1)

**`devicectl` в Xcode 27 работает и с физическими устройствами, и с симуляторами** (`devicectl list devices` показывает оба вида, `capture screenshot` и `orientation get` отработали на booted-симуляторе). У него стабильный JSON-вывод (`--json-output -`), и умеет он многое:
- приложения: install, uninstall, launch (`--console`, `--terminate-existing`), terminate, openURL, sendMemoryWarning;
- информация: apps, processes, displays, lockState, details;
- экран: `capture screenshot`, `capture screen-record`, `orientation get/set/rotate`;
- симуляция: `simulate location` (coordinate, route, scenario), `simulate statusBar` (override, preset, clear), `simulate biometrics`;
- настройки: `settings appearance`, `settings biometrics`, `settings voiceover`, `settings reset`;
- `pasteboard`, Darwin-нотификации (`notification post/observe`), файлы (`copy to/from`, домены `appDataContainer`, `appGroupDataContainer`, `systemCrashLogs`), reboot, rename.

Push-уведомлений в `devicectl` нет (проверены все 102 подкоманды). `notification post` — это Darwin-нотификации, внутренние системные сигналы, а не push.

**`simctl`** остаётся нужен для того, что есть только у симулятора: create, boot, erase, delete, clone, privacy, push, addmedia, Dynamic Type, Increase Contrast, keychain, `spawn` (unified log, defaults), recordVideo.

**Чего нет ни там, ни там:**
- ввода: тапов, свайпов, набора текста;
- дерева элементов экрана.

Это и есть основная задача сервера, плюс единый удобный интерфейс поверх двух CLI.

### Окружение

| Что | Значение |
|---|---|
| macOS | 26.7.1 |
| Xcode | 27.1 (27A9275) — минимальная поддерживаемая версия: 27.0 |
| Swift | 6.4 |
| Рантаймы | iOS 27.0, iOS 27.1 |
| Физическое устройство | iPhone 14 Plus (paired) |
| CoreSimulator | `/Library/Developer/PrivateFrameworks/CoreSimulator.framework` |
| SimulatorKit | `/Applications/Xcode.app/Contents/SharedFrameworks/SimulatorKit.framework` |
| AccessibilityPlatformTranslation | `/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework` |
| usbmuxd | `/var/run/usbmuxd` (для проброса порта агента на iPhone) |
| MCP Swift SDK | `modelcontextprotocol/swift-sdk` 0.12.1 |

Нужные приватные API для симулятора (проверено в спайке 0A, см. `Spikes/0A-SimBridge/README.md`):
- ввод — XPC к демону CoreDevice `dtuhidd` внутри симулятора: `-[SimDevice lookup:error:]` → `xpc_endpoint_create_mach_port_4sim` → `xpc_connection_enable_sim2host_4sim`, сообщения `IndigoDigitizerEvent` / `IndigoButtonEvent` / `IndigoKeyboardButtonEvent`. Legacy Indigo (`SimulatorKit.SimDeviceLegacyHIDClient`) в Xcode 27 для кнопок и клавиатуры не работает, touch ненадёжен — не используем;
- `-[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:]` + `AXPTranslator` — AX-дерево.

## 2. Архитектура

```
┌──────────────────────────────────────────────────────────────────┐
│  MCP-клиент (Claude Code / Cursor / Inspector)                   │
└───────────────┬──────────────────────────────────────────────────┘
                │ JSON-RPC over stdio
┌───────────────▼──────────────────────────────────────────────────┐
│  ISimMCP — MCP-слой                                              │
│  • тулзы, JSON Schema, аннотации, toolsets                       │
│  • ToolRouter: вид устройства + capability → бэкенд              │
└───────────────┬──────────────────────────────────────────────────┘
┌───────────────▼──────────────────────────────────────────────────┐
│  DeviceCore — домен                                              │
│  • Device(kind: .simulator / .physical), DeviceResolver          │
│  • CapabilityMatrix: что поддержано на каком виде устройства     │
│  • JobManager (actor): логи, видео, консоль приложения           │
└──┬────────────┬─────────────┬───────────────┬────────────────┬───┘
   │            │             │               │                │
┌──▼─────────┐┌─▼──────────┐┌─▼────────────┐┌─▼─────────────┐┌─▼──────────┐
│Devicectl   ││Simctl      ││SimBridge     ││AgentClient    ││XcodeBuild  │
│Backend     ││Backend     ││(ObjC)        ││HTTP + usbmux  ││            │
│обе платф.: ││только сим: ││только сим:   ││физ. (и сим    ││сборка      │
│apps, экран,││lifecycle,  ││HID-ввод,     ││как fallback)  ││агента и    │
│гео, статус-││privacy,    ││AX-дерево     ││               ││проектов    │
│бар, файлы, ││push, media,││              ││       │       ││            │
│краши       ││логи, видео ││              ││       │       ││            │
└────────────┘└────────────┘└──────────────┘└───────┼───────┘└────────────┘
                                                    │ TCP через usbmuxd
                                                    │ (сим: localhost)
                                    ┌───────────────▼────────────────┐
                                    │ ISimAgent на устройстве        │
                                    │ XCUITest-раннер + HTTP-сервер  │
                                    │ tap/type/snapshot/alerts/...   │
                                    └────────────────────────────────┘
```

**Правило выбора бэкенда:** сначала `devicectl` (один код для обоих видов устройств, стабильный JSON), `simctl` — только там, где `devicectl` чего-то не умеет. Ввод и UI-инспекция: симулятор → `SimBridge` (мгновенно, без сборки), физическое устройство → `ISimAgent`. Если тулз не поддержан на этом виде устройства, ошибка говорит об этом прямо и предлагает альтернативу.

### Структура репозитория

```
iSim-mcp/
├── Package.swift
├── Makefile                 # build, install, agent-build
├── Sources/
│   ├── isim-mcp/            # executable: main, ArgumentParser, запуск сервера
│   ├── ISimMCP/             # MCP-слой: ToolRegistry, ToolRouter, хендлеры по группам
│   ├── DeviceCore/          # модели, DeviceResolver, CapabilityMatrix, JobManager, протоколы
│   ├── DevicectlBackend/    # обёртки над `xcrun devicectl` (JSON-вывод)
│   ├── SimctlBackend/       # обёртки над `xcrun simctl`
│   ├── SimBridge/           # ObjC: CoreSimulator + AXPT (Accessibility), XPC-клиент dtuhidd (ввод)
│   ├── AgentClient/         # HTTP-клиент к агенту + usbmux-проброс порта на Swift
│   ├── XcodeBuild/          # xcodebuild: build, build-for-testing, test-without-building, парсинг ошибок
│   └── ProcessKit/          # async ProcessRunner: таймауты, отмена, стриминг вывода
├── Agent/                   # Xcode-проект агента
│   ├── ISimAgent.xcodeproj
│   ├── ISimAgentHost/       # пустое host-приложение
│   └── ISimAgentRunner/     # UI-test bundle: HTTP-сервер (NWListener) → XCUITest API
└── Tests/
    ├── DeviceCoreTests/
    ├── BackendTests/        # парсинг фикстур simctl/devicectl JSON
    └── IntegrationTests/    # против живого симулятора/устройства, по env-флагу
```

### Зависимости

- `modelcontextprotocol/swift-sdk` — сервер, stdio-транспорт;
- `apple/swift-argument-parser` — CLI-флаги (`--toolsets`, `--team-id`, `--log-level`);
- `apple/swift-log` — логирование **только в stderr**.

Агент использует только XCTest и Network.framework. Ничего на Python/Node, никаких idb/libimobiledevice/pymobiledevice3.

## 3. Физические устройства: агент ISimAgent

### Как это работает

1. `ui_agent start` (или первый UI-тулз) собирает `Agent/` через `xcodebuild build-for-testing` с командой разработчика пользователя (`DEVELOPMENT_TEAM`, `-allowProvisioningUpdates`). Сборка кэшируется в `~/Library/Application Support/iSim-mcp/agent/<team>/`, пересобирается только при смене версии агента или Xcode.
2. Запускает `xcodebuild test-without-building -destination id=<UDID>`. Единственный тест в раннере не завершается: он поднимает HTTP-сервер на порту устройства и выполняет команды.
3. Сервер пробрасывает порт через usbmuxd (протокол — plist поверх unix-сокета, как у `iproxy`; работает и по USB, и по Wi-Fi для сопряжённых устройств). Для симулятора агент слушает localhost напрямую.
4. Агент живёт, пока жив MCP-сервер, чтобы не платить 10–30 секунд старта на каждый вызов. Если агент упал, следующий UI-тулз поднимает его заново.

### Что агент умеет (через XCUITest)

- тап, двойной тап, long press, drag (`XCUICoordinate`), pinch и rotate (`XCUIElement.pinch/rotate`);
- ввод текста любым алфавитом (`typeText`, кириллица работает без трюков с буфером), клавиши Return и Delete;
- снимок дерева accessibility (`snapshot().dictionaryRepresentation`) любого приложения по bundle id, включая SpringBoard;
- системные алерты (разрешения, «Разрешить вставку» и т.п.) через SpringBoard;
- кнопки Home и громкости (`XCUIDevice.press`).

Произвольный многоточечный путь пальца в публичном XCUITest недоступен; если понадобится, через приватный `XCPointerEventPath` (так делает WebDriverAgent).

### Требования к устройству и аккаунту

- Developer Mode включён, устройство сопряжено с Mac и доверяет ему;
- Settings → Developer → **Enable UI Automation**;
- сертификат Apple Development и Team ID. Платный аккаунт — без ограничений; бесплатный Apple ID работает, но профили живут 7 дней;
- **экран разблокирован** во время работы UI-тулзов (XCUITest не работает на заблокированном устройстве, `doctor` проверяет `lockState`).

### Чего на физическом устройстве не будет

| Возможность | Почему | Альтернатива |
|---|---|---|
| Выдать разрешения без диалога (`set_permission`) | Нет механизма ни в devicectl, ни в XCUITest | `handle_system_alert` — нажать «Разрешить» в системном диалоге |
| Стереть устройство (`erase_device`) | `devicectl settings reset` существует, но это личный телефон — **намеренно не поддерживаем** | — |
| Dynamic Type, Increase Contrast, язык и регион, keychain, добавление фото в галерею, shake | Нет механизма | — |
| Полноценный стрим unified log | `devicectl` отдаёт только stdout/stderr запущенного приложения | `launch_app(capture_output)`; разовый `query_logs` через `log collect` (медленно) |

Всё остальное, включая весь ввод и инспекцию UI, на физическом устройстве будет.

## 4. Ключевые технические решения

1. **stdout — только MCP.** Логи, вывод CLI и отладка идут в stderr или файл, иначе клиент получит битый JSON-RPC.
2. **Выбор устройства.** У каждого тулза есть необязательный `device` (UDID или имя). Если не передан: активное устройство сессии (`set_active_device`) → единственное booted-симулятор/подключённое устройство → ошибка со списком и подсказкой. `list_devices` объединяет `simctl` и `devicectl` и помечает `kind`.
3. **Координаты в точках (pt)** на обоих видах устройств. `screenshot` возвращает размер в точках и scale, чтобы агент переводил позиции с картинки в координаты тапа.
4. **Экономия токенов на картинках.** Скриншот по умолчанию уменьшается до `max_dimension` (1024 px) и кодируется в JPEG; PNG в полном разрешении — по запросу. Есть режим «только сохранить в файл и вернуть путь».
5. **AX-дерево в компактном виде.** По умолчанию — плоский список интерактивных элементов (`[button] "Войти" id=loginButton (16,700 343×50)`), полный JSON — по флагу.
6. **Ввод не-ASCII на симуляторе.** HID-клавиатура симулятора набирает только символы US-раскладки. Для кириллицы и эмодзи `type_text` в режиме `auto` кладёт текст в буфер обмена через `devicectl device pasteboard copy` (`simctl pbcopy` в Xcode 27 буфер не меняет) и шлёт Cmd+V. На физическом устройстве это не нужно, `typeText` агента понимает Unicode.
7. **Долгие операции — через джобы.** Стрим логов, консоль приложения и запись видео — фоновые процессы в `JobManager` (actor) с `job_id`, явными `read`/`stop`, остановкой всех джоб при выходе и корректной финализацией видео через SIGINT.
8. **Таймауты и отмена везде**, включая MCP `notifications/cancelled`.
9. **Toolsets.** 73 тулза перегружают контекст агента, поэтому группы включаются флагом: по умолчанию `core,devices,apps,screen,ui`, остальные — `system,data,logs,build,advanced`.
10. **Аннотации MCP.** `readOnlyHint` для чтения, `destructiveHint` для `erase_device`, `delete_device`, `uninstall_app`, `keychain`. На физическом устройстве разрушительные операции, кроме `uninstall_app`, недоступны совсем.
11. **Ошибки с подсказками.** `Device "iPhone 16 Pro" is Shutdown. Call boot_device first.`, `set_permission is not available on physical devices. Use handle_system_alert to accept the system prompt.`
12. **Изоляция приватного API.** `SimBridge` спрятан за протоколами `InputInjecting` и `AccessibilityProviding`. Если после обновления Xcode символы пропадут или `dtuhidd` не ответит на barrier, `doctor` скажет, что именно сломалось, а UI-тулзы на симуляторе переключатся на `ISimAgent`, который работает на публичном XCUITest.
13. **Путь к Xcode:** `DEVELOPER_DIR` → `xcode-select -p`; проверка версии ≥ 27.0 при старте.
14. **Push через APNs.** Свой HTTP/2-клиент на `URLSession` с JWT-авторизацией (ES256 через CryptoKit), без новых зависимостей. Ключ `.p8`, Key ID и Team ID задаются при запуске сервера флагами (`--apns-key-path`, `--apns-key-id`, `--team-id`) или переменными окружения. Ключ не попадает ни в параметры тулзов, ни в ответы — ИИ-агент его не видит.
15. **Соединение с `dtuhidd` живёт всю сессию.** Новое соединение стоит ~0,8 с (barrier-сообщение с ответом + ожидание активации peer). `dtuhidd` запускается по требованию и может упасть на медленной загрузке симулятора, поэтому barrier ретраится с бэкоффом ~4 с.

## 5. Каталог тулзов

Колонки **Сим** и **Физ** показывают бэкенд на симуляторе и на физическом устройстве: `D` — devicectl, `S` — simctl, `K` — SimBridge, `A` — ISimAgent, `H` — хост (файлы/процессы macOS), `X` — xcodebuild, `✓` — бэкенд не нужен, `—` — не поддерживается, `?` — команда есть, но работу на этом виде устройства нужно проверить. **Ф** — фаза (раздел 6). ⚠️ — разрушительная операция. Необязательный параметр `device` есть у всех тулзов, работающих с устройством, и в таблицах не повторяется.

### 5.1 core — всегда включено

| Тулз | Назначение | Ключевые параметры | Сим | Физ | Ф |
|---|---|---|---|---|---|
| `doctor` | Проверка окружения: Xcode ≥ 27, загрузка приватных фреймворков, устройства; для iPhone — Developer Mode, UI Automation, lockState, сертификат и Team ID | — | S,D,K | D,X | 1 |
| `set_active_device` | Устройство по умолчанию для сессии | `device` | ✓ | ✓ | 1 |
| `ui_agent` | Статус, запуск или остановка агента (сборка при необходимости) | `action` (status/start/stop), `team_id`, `rebuild` | A | X,A | 4 |

### 5.2 devices — устройства

| Тулз | Назначение | Ключевые параметры | Сим | Физ | Ф |
|---|---|---|---|---|---|
| `list_devices` | Симуляторы и физические устройства: udid, имя, `kind`, состояние, ОС, модель, активное ли | `kind`, `state`, `name_contains`, `include_unavailable` | S,D | D | 1 |
| `boot_device` | Загрузить и дождаться полной готовности | `wait`=true, `open_simulator_app`=false | S | — | 1 |
| `shutdown_device` | Выключить одно или все | `all` | S | — | 1 |
| `reboot_device` | Перезагрузить | `wait`=true | S | D | 2 |
| `open_simulator_app` | Открыть Simulator.app с нужным устройством | — | H | — | 2 |
| `list_runtimes` | Рантаймы и поддерживаемые типы устройств | — | S | — | 2 |
| `create_device` | Создать симулятор | `name`, `device_type`, `runtime` | S | — | 2 |
| `erase_device` ⚠️ | Сбросить контент и настройки | — | S | — | 2 |
| `delete_device` ⚠️ | Удалить устройство или все unavailable | `unavailable_only` | S | — | 2 |
| `clone_device` | Клонировать (быстрый «снапшот» состояния) | `name` | S | — | 5 |
| `rename_device` | Переименовать | `name` | S | D | 5 |

### 5.3 apps — приложения

| Тулз | Назначение | Ключевые параметры | Сим | Физ | Ф |
|---|---|---|---|---|---|
| `list_apps` | Установленные приложения: bundle id, имя, версия, тип | `include_system`=false | S | D | 1 |
| `get_app_info` | Подробности: версия, пути, entitlements | `bundle_id` | S | D | 2 |
| `install_app` | Установить `.app` или `.ipa` (на iPhone — подписанную сборку) | `path` | S | D | 1 |
| `uninstall_app` ⚠️ | Удалить приложение | `bundle_id` | S | D | 1 |
| `launch_app` | Запустить; по умолчанию перезапускает. Опционально сразу захватывает stdout/stderr в джобу | `bundle_id`, `args[]`, `env{}`, `terminate_existing`=true, `capture_output`, `start_stopped` | S | D | 1 |
| `terminate_app` | Остановить | `bundle_id` | S | D | 1 |
| `open_url` | Deep link, universal link, http-ссылка | `url` | S | D | 1 |
| `list_processes` | Запущенные процессы | `name_contains` | D? | D | 2 |
| `send_memory_warning` | Послать memory warning процессу | `bundle_id` \| `pid` | D? | D | 5 |
| `get_app_container` | Путь к контейнеру на диске Mac (на iPhone файлов на Mac нет, см. 5.7) | `bundle_id`, `kind` (app/data/groups/`<group-id>`) | S | — | 2 |

### 5.4 screen — экран и медиа

| Тулз | Назначение | Ключевые параметры | Сим | Физ | Ф |
|---|---|---|---|---|---|
| `screenshot` | Скриншот как MCP image + размер в pt, scale, ориентация | `format` (jpeg/png), `quality`, `max_dimension`=1024, `return` (image/path/both), `save_path`, `display` | S | D | 1 |
| `get_screen_info` | Дисплеи, размер в pt/px, scale, ориентация | — | D | D | 2 |
| `start_recording` | Начать запись видео → `job_id` | `path`, `codec` (h264/hevc) | S | D? | 5 |
| `stop_recording` | Остановить, вернуть путь и длительность | `job_id` | S | D? | 5 |
| `add_media` | Фото, видео, контакты в библиотеку | `paths[]` | S | — | 2 |

### 5.5 ui — ввод и инспекция

**Селектор элемента** (общий для нескольких тулзов): `{ identifier?, label?, label_contains?, value?, role?, index? }`. На физическом устройстве UI-тулзы смотрят в приложение, запущенное последним через `launch_app`, или в `bundle_id`, переданный явно.

| Тулз | Назначение | Ключевые параметры | Сим | Физ | Ф |
|---|---|---|---|---|---|
| `tap` | Тап по координатам **или** элементу. Двойной тап и long press — параметрами | `x`,`y` \| `element`, `count`=1, `duration_ms` | K | A | 3/4 |
| `swipe` | Свайп/скролл между точками или по направлению | `from`,`to` \| `direction`+`element?`, `duration_ms` | K | A | 3/4 |
| `touch_path` | Произвольный путь одним пальцем: drag & drop, рисование | `points[{x,y,dt_ms}]` | K | A? | 5 |
| `multi_touch` | Жест двумя пальцами: pinch, rotate | `preset` (pinch_in/pinch_out/rotate)+`center`,`scale`,`angle` \| `points[]` (только сим) | K | A | 5 |
| `type_text` | Ввести текст в элемент в фокусе | `text`, `method` (auto/hid/paste), `submit` | K,D | A | 3/4 |
| `press_key` | Клавиша или сочетание: return, delete, tab, escape, стрелки, Cmd+A | `key` \| `hid_usage`, `modifiers[]`, `repeat` | K | A? | 3/4 |
| `press_button` | Аппаратная кнопка: home, lock, side, siri, volume_up/down | `button`, `duration_ms` | K | A? | 3/4 |
| `describe_ui` | Дерево accessibility фронтального приложения | `format` (compact/json), `interactive_only`=true, `max_depth`, `bundle_id?` | K | A | 3/4 |
| `describe_point` | Элемент под точкой | `x`,`y` | K | A | 3/4 |
| `find_elements` | Найти элементы по селектору → frame и центр | `element`, `limit` | K | A | 3/4 |
| `wait_for` | Ждать: элемент появился, исчез, экран перестал меняться | `condition` (exists/gone/screen_stable), `element?`, `timeout_ms` | K | A | 3/4 |
| `scroll_until_visible` | Скроллить, пока элемент не появится | `element`, `direction`, `max_swipes` | K | A | 5 |
| `handle_system_alert` | Прочитать или нажать кнопку в системном диалоге (разрешения и т.п.) | `action` (read/accept/deny/tap), `button_label?` | K | A | 3/4 |
| `set_orientation` | Повернуть устройство | `orientation` (portrait/landscapeLeft/landscapeRight/portraitUpsideDown) | D | D | 2 |
| `shake` | Жест «встряхнуть» | — | S | — | 5 |

### 5.6 system — окружение

| Тулз | Назначение | Ключевые параметры | Сим | Физ | Ф |
|---|---|---|---|---|---|
| `configure_ui` | Тема, Dynamic Type, Increase Contrast. Без параметров возвращает текущие значения. На iPhone — только тема | `appearance`, `content_size`, `increase_contrast` | D,S | D | 2 |
| `set_permission` | Выдать, отозвать или сбросить разрешение без диалога | `action` (grant/revoke/reset), `service` (all, calendar, contacts, contacts-limited, location, location-always, photos, photos-add, media-library, microphone, motion, reminders, siri), `bundle_id` | S | — | 2 |
| `set_location` | Задать координаты или сбросить | `latitude`,`longitude` \| `clear` | D | D | 2 |
| `simulate_route` | Движение по точкам или встроенный сценарий; стоп — `set_location(clear)` | `waypoints[]` \| `scenario`, `speed` | D | D | 2 |
| `override_status_bar` | Подменить статус-бар для скриншотов | `preset` \| `time`, `battery_level`, `battery_state`, `cellular_bars`, `wifi_bars`, `data_network`, `operator_name`; `clear` | D | D? | 2 |
| `biometrics` | Face ID / Touch ID: включить, выключить, успешное или неуспешное совпадение | `action` (enable/disable/match/nonmatch) | D | D? | 2 |
| `set_pasteboard` | Положить текст в буфер обмена | `text` | D | D | 2 |
| `get_pasteboard` | Прочитать буфер обмена | — | D | D | 2 |
| `send_push` | Push-уведомление. `local` — мгновенно через `simctl push`, без настроек (только симулятор, только обычные push, payload до 4 КБ). `apns` — настоящая отправка через APNs sandbox по device token: работает и на iPhone, и на симуляторе, поддерживает silent, VoIP и Live Activity | `bundle_id`, `payload` \| `payload_path`, `mode` (local/apns; по умолчанию local на симуляторе, apns на iPhone), `device_token` (для apns), `push_type` (alert/background/voip/liveactivity), `priority`, `collapse_id` | S,H | H | 2 / 5 |
| `set_locale` | Язык и регион с перезапуском SpringBoard | `language`, `region` | S | — | 5 |
| `icloud_sync` | Запустить синхронизацию iCloud | — | S | — | 5 |

### 5.7 data — данные приложения

| Тулз | Назначение | Ключевые параметры | Сим | Физ | Ф |
|---|---|---|---|---|---|
| `list_container_files` | Файлы в контейнере приложения или app group | `bundle_id`, `kind` (data/group), `subpath`, `depth` | H | D | 5 |
| `read_container_file` | Прочитать файл; plist — сразу JSON, бинарник — base64 с лимитом | `bundle_id`, `path`, `max_bytes` | H | D | 5 |
| `write_container_file` | Записать или скопировать файл в контейнер | `bundle_id`, `path`, `content` \| `source_path` | H | D | 5 |
| `read_user_defaults` | UserDefaults приложения (домен целиком или ключ) | `bundle_id`, `key?`, `suite?` | S | D | 5 |
| `write_user_defaults` | Записать значение (feature flags, онбординг и т.п.) | `bundle_id`, `key`, `value`, `type` | S | — | 5 |
| `keychain` ⚠️ | Добавить root/обычный сертификат или сбросить keychain | `action` (add_root_cert/add_cert/reset), `path` | S | — | 5 |

### 5.8 logs — логи и диагностика

| Тулз | Назначение | Ключевые параметры | Сим | Физ | Ф |
|---|---|---|---|---|---|
| `start_log_capture` | Стрим unified log в кольцевой буфер → `job_id`. На iPhone — только stdout/stderr приложения | `bundle_id` \| `process` \| `subsystem` \| `predicate`, `level` | S | D | 5 |
| `read_log_capture` | Новые строки с курсора, фильтр по подстроке. Читает и консоль из `launch_app(capture_output)` | `job_id`, `cursor`, `max_lines`, `grep` | ✓ | ✓ | 5 |
| `stop_log_capture` | Остановить джобу | `job_id` | ✓ | ✓ | 5 |
| `query_logs` | Разовый запрос логов за прошедшее время | `last` (напр. `5m`), `predicate` \| `bundle_id`, `max_lines` | S | H? | 5 |
| `list_crash_reports` | Краш-репорты `.ips` | `bundle_id?`, `since?` | H | D | 5 |
| `get_crash_report` | Исключение и стек упавшего потока | `id` | H | D | 5 |

### 5.9 advanced — выключено по умолчанию

| Тулз | Назначение | Ключевые параметры | Сим | Физ | Ф |
|---|---|---|---|---|---|
| `simctl_raw` | `simctl` с произвольными аргументами | `args[]`, `timeout_ms` | S | — | 5 |
| `devicectl_raw` | `devicectl` с произвольными аргументами | `args[]`, `timeout_ms` | D | D | 5 |
| `post_darwin_notification` | Отправить Darwin-нотификацию | `name` | D | D | 5 |
| `spawn_process` | Запустить бинарник внутри симулятора | `executable`, `args[]`, `timeout_ms` | S | — | 5 |

### 5.10 build — сборка проекта

| Тулз | Назначение | Ключевые параметры | Сим | Физ | Ф |
|---|---|---|---|---|---|
| `list_schemes` | Схемы и конфигурации проекта или workspace | `project` \| `workspace` | X | X | 6 |
| `build_app` | Собрать под выбранное устройство. Возвращает путь к `.app`, bundle id и компактный список ошибок и предупреждений вместо полного лога. Опционально сразу ставит и запускает | `project` \| `workspace`, `scheme`, `configuration`=Debug, `install`=false, `launch`=false, `team_id?` | X | X | 6 |

**Итого:** 73 тулза (core 3, devices 11, apps 10, screen 5, ui 15, system 11, data 6, logs 6, advanced 4, build 2). В дефолтном наборе `core,devices,apps,screen,ui` — 44.

### 5.11 MCP Resources и Prompts

- Resources:
  - `device://list` — актуальный список устройств;
  - `device://{udid}/screenshot` — последний скриншот;
  - `device://{udid}/ui` — текущее AX-дерево;
  - `job://{job_id}` — вывод джобы.
- Prompts:
  - `smoke_test_app` — собрать, установить, запустить, пройти по экранам, собрать краши;
  - `capture_store_screenshots` — статус-бар 9:41, светлая и тёмная тема, несколько локалей (симулятор).

## 6. Этапы

### Фаза 0 — два спайка (3–4 дня) ✅ 22.10.2026

Главные риски проекта, поэтому они первые. Оба делаются отдельными прототипами, без MCP.

**Итог:** оба спайка прошли критерии. Отчёты и код — `Spikes/0A-SimBridge/README.md`, `Spikes/0B-Agent/README.md`. Что поменялось против исходного плана:
- 0A: ввод на симуляторе идёт не через SimulatorKit/Indigo (в Xcode 27 кнопки и клавиатура там молча теряются), а через XPC к демону `dtuhidd`. AX — как задумано, 30–50 мс на экран.
- 0B: агент на Personal Team работает; перед первым запуском нужно вручную доверить сертификат на iPhone. Тап по элементу через XCUITest ~2 с — кандидат на оптимизацию в фазе 4.

**0A. SimBridge на симуляторе:**
1. Загрузить CoreSimulator, получить `SimServiceContext` → `SimDeviceSet` → `SimDevice` по UDID.
2. ~~Загрузить SimulatorKit, создать `SimDeviceLegacyHIDClient`, собрать `IndigoHIDMessageStruct` для touch down/up~~ → XPC-соединение с `dtuhidd`, `IndigoDigitizerEvent`. **Готово, когда** тап по координатам открывает приложение на home screen.
3. Клавиатурное событие и кнопка Home.
4. AX-дерево через `AXPTranslator` + `sendAccessibilityRequestAsync`. **Готово, когда** выводится список кнопок Settings.app с координатами, совпадающими со скриншотом.

**0B. ISimAgent на iPhone:**
1. Минимальный Xcode-проект: host app + UI-test bundle с HTTP-сервером на `NWListener`.
2. `build-for-testing` с Team ID, `test-without-building` на подключённом iPhone.
3. Проброс порта через usbmuxd из Swift.
4. **Готово, когда** с Mac по HTTP можно открыть Settings, тапнуть по пункту меню и получить его AX-дерево.

Если 0A не взлетит за разумное время, на симуляторе тоже используем агента: медленнее старт, зато публичный API.

### Фаза 1 — скелет и MVP для обоих видов устройств (2–3 дня)

- SwiftPM-пакет, stdio-сервер, `ToolRegistry`, `ToolRouter`, `CapabilityMatrix`, toolsets, `ProcessKit`.
- Тулзы: `doctor`, `set_active_device`, `list_devices`, `boot_device`, `shutdown_device`, `list_apps`, `install_app`, `uninstall_app`, `launch_app`, `terminate_app`, `open_url`, `screenshot`.
- Подключение к Claude Code: `claude mcp add isim -- ~/.local/bin/isim-mcp`.
- **Готово, когда** агент ставит приложение, запускает его и присылает скриншот — и на симуляторе, и на iPhone.

### Фаза 2 — окружение (2 дня)

- Остальные тулзы фазы 2 из `devices`, `apps`, `screen`, `ui` (`set_orientation`) и весь `system` фазы 2. Проверка всех ячеек с `?`.
- **Готово, когда** можно подготовить устройство под скриншоты: тёмная тема, статус-бар 9:41, гео, разрешения (на симуляторе).

### Фаза 3 — ввод и accessibility на симуляторе (4–6 дней)

- Перенос спайка 0A в `SimBridge`: `tap`, `swipe`, `type_text`, `press_key`, `press_button`, `describe_ui`, `describe_point`, `find_elements`, `wait_for`, `handle_system_alert`.
- Компактный формат AX-дерева, селекторы, тап по элементу.
- **Готово, когда** агент проходит сценарий «логин → список → деталь» только по селекторам.

### Фаза 4 — ввод и accessibility на iPhone (5–7 дней)

- Перенос спайка 0B: полноценный `ISimAgent`, `AgentClient`, `ui_agent`, кэш сборки, автоперезапуск.
- Те же UI-тулзы, что в фазе 3, через агента. Агент как fallback для симулятора.
- **Готово, когда** тот же сценарий «логин → список → деталь» проходит на iPhone без изменений в вызовах.

### Фаза 5 — логи, видео, данные, продвинутые жесты (3–4 дня)

- `JobManager`; логи, консоль приложения, видео; краши; `send_push` в режиме `apns`; файлы контейнера и UserDefaults; `touch_path`, `multi_touch`, `scroll_until_visible`, `shake`, `set_locale`, `keychain`, `icloud_sync`, `clone_device`, `rename_device`, `send_memory_warning`, `advanced`.

### Фаза 6 — сборка проекта и полировка (2–3 дня)

- `XcodeBuild` для пользовательских проектов: `list_schemes`, `build_app` с компактным разбором ошибок.
- Resources и Prompts.
- README с конфигами для Claude Code, Cursor, VS Code; `make install` (бинарник в `~/.local/bin`, исходники агента в `~/.local/share/isim-mcp/Agent`).

## 7. Риски

| Риск | Митигация |
|---|---|
| Apple меняет приватные API симулятора (уже случилось: в Xcode 27 legacy Indigo перестал доставлять кнопки и клавиатуру, ввод переехал в `dtuhidd`) | Изоляция в `SimBridge`, поиск символов в runtime, `doctor` с barrier-проверкой `dtuhidd`; fallback на `ISimAgent` |
| `dtuhidd` падает на медленной загрузке симулятора, launchd придерживает перезапуск ~10 с | Ретрай barrier с бэкоффом; ошибка, если демон не ответил за ~20 с |
| Сертификат Personal Team не доверен на iPhone | `ui_agent start` распознаёт ошибку `Developer App Certificate is not trusted` и пишет путь в Settings |
| Подпись агента: нет сертификата, истёк профиль бесплатного аккаунта, не включён UI Automation | `doctor` проверяет всё заранее и пишет, что именно сделать; пересборка по `ui_agent start rebuild=true` |
| Медленный старт агента (10–30 с) и медленный `snapshot` на тяжёлых экранах | Агент живёт всю сессию; лимит глубины и `interactive_only` для дерева |
| Wi-Fi-соединение с iPhone рвётся | Рекомендовать USB; автопереподключение и перезапуск агента |
| Работа на личном телефоне | Разрушительные операции на физическом устройстве недоступны, кроме `uninstall_app` с `destructiveHint` |
| AX-дерево неполное (кастомные view без accessibility, Canvas, игры) | Можно вернуться к координатам со скриншота; `describe_point` для проверки |
| Кириллица не набирается через HID на симуляторе | Режим `paste`: `devicectl device pasteboard copy` + Cmd+V |
| Тяжёлые ответы (картинки, деревья, логи) | Ресайз и JPEG, компактный формат, курсоры и лимиты |
| Зависшие процессы `simctl`/`devicectl`/`xcodebuild` | Таймауты, отмена, `JobManager` гасит всё при выходе |

## 8. Тестирование

- **Unit:** `DeviceResolver`, `CapabilityMatrix`/`ToolRouter`, парсинг JSON `simctl`/`devicectl` по фикстурам, построение аргументов команд, форматтер AX-дерева, сообщения `dtuhidd`, протокол usbmux, парсер ошибок `xcodebuild`. Процессы мокаются через протокол `ProcessRunning`.
- **Интеграционные, симулятор** (`ISIM_INTEGRATION=sim`): одноразовый симулятор, сценарии на Settings.app и тестовом приложении из `Tests/Fixtures`, в конце удаление.
- **Интеграционные, iPhone** (`ISIM_INTEGRATION=device`, `ISIM_TEAM_ID=…`): только неразрушающие сценарии — установка тестового приложения, UI-сценарий, удаление тестового приложения.
- **Ручные:** MCP Inspector (`npx @modelcontextprotocol/inspector ~/.local/bin/isim-mcp`) и живой прогон из Claude Code.

## 9. Открытые вопросы

1. ~~Какой Apple Developer аккаунт будет подписывать агента?~~ Решено: Personal Team (бесплатный Apple ID), `-allowProvisioningUpdates`, профили на 7 дней.
2. ~~iPhone будет подключён по USB или по Wi-Fi?~~ Сейчас USB; Wi-Fi поддерживаем, но с переподключением.
3. Есть ли у приложения APNs-ключ (`.p8`) и логирует ли debug-сборка device token? Без ключа push на iPhone не отправить; на симуляторе хватит режима `local`.
4. Ввод на iPhone без агента? iPhone объявляет CoreDevice-фичи `remote.hid.{digitizer,button,keyboard}` — тот же механизм, что `dtuhidd` в симуляторе. Если до них можно достучаться с хоста (RemoteXPC через туннель CoreDevice), тапы и текст на iPhone не требуют XCUITest; AX-дерево всё равно остаётся за агентом. Нужен отдельный спайк до фазы 4.
