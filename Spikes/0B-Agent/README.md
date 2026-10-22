# Спайк 0B — ISimAgent на iPhone

Прототип без MCP: Xcode-проект агента (пустое host-приложение + UI-test runner с HTTP-сервером на `NWListener`) и хостовый клиент `agentctl`, который ходит к агенту через usbmuxd.

```bash
cd Spikes/0B-Agent
UDID=00008110-000244D21181401E
TEAM=VYL36DLB34

xcodebuild build-for-testing -project ISimAgent.xcodeproj -scheme ISimAgent \
  -destination id=$UDID -derivedDataPath .build/dd-device \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=$TEAM
xcodebuild test-without-building -destination id=$UDID \
  -xctestrun .build/dd-device/Build/Products/ISimAgent_iphoneos27.1-arm64.xctestrun &

swiftc -O Client/agentctl.swift -o .build/agentctl
.build/agentctl $UDID GET /status
.build/agentctl $UDID POST /launch '{"bundle_id":"com.apple.Preferences"}'
.build/agentctl $UDID POST /tap '{"identifier":"com.apple.settings.general"}'
.build/agentctl $UDID GET /tree            # ?format=json для полного JSON
.build/agentctl $UDID POST /tap '{"x":42,"y":69}'
.build/agentctl $UDID POST /button '{"name":"home"}'
.build/agentctl $UDID POST /stop
```

Для симулятора вместо UDID передаётся `local`: агент слушает порт прямо на Mac.

Проверено на iPhone 14 Plus (iOS 27.0.1, USB) и iPhone 16 Pro Simulator (iOS 27.0), Xcode 27.1, 22.10.2026.

## Итог

Критерий выполнен: с Mac по HTTP открыли Settings, тапнули «General» по идентификатору, получили AX-дерево нового экрана. Дополнительно работают тап по координатам (кнопка «Назад»), Home и `/stop` (тест завершается штатно, `TEST EXECUTE SUCCEEDED`).

| Операция | iPhone | Симулятор |
|---|---|---|
| Старт теста после `test-without-building` (сборка готова) | ~9 с | ~10 с |
| `/status` через usbmuxd | 33 мс | 15 мс |
| `/launch` Settings | 2,7 с | 5,6 с |
| `/tree` Settings (компактный формат) | 240–270 мс | 64–470 мс |
| `/tap` по identifier | 2,45 с | 1,9 с |
| `/tap` по координатам | 0,85 с | — |
| `/button home` | 0,49 с | — |

## Находки

- **Проект без генераторов.** `project.pbxproj` написан вручную в формате Xcode 16+ (`objectVersion = 77`, `PBXFileSystemSynchronizedRootGroup`): файлы исходников в проекте не перечисляются, xcodegen/Tuist не нужны.
- **Bundle ID включает Team ID** (`dev.isimmcp.$(DEVELOPMENT_TEAM).AgentRunner`): явные App ID уникальны глобально, иначе у второго пользователя с тем же ID сборка упадёт.
- **Personal Team работает.** `-allowProvisioningUpdates` сам создал сертификат и профиль. Перед первым запуском пользователь должен вручную доверить сертификат на iPhone (Settings → General → VPN & Device Management), иначе `xcodebuild` падает с `The application could not be launched because the Developer App Certificate is not trusted`. `doctor` и `ui_agent start` должны распознавать эту строку и говорить, что делать.
- **usbmuxd из Swift** — ~100 строк: plist-сообщения `ListDevices` и `Connect` по `/var/run/usbmuxd`, после `Connect` сокет становится TCP-потоком на порт устройства. Для iOS 27 по USB работает. `SerialNumber` в usbmuxd — UDID без дефиса, `PortNumber` — в сетевом порядке байт.
- **Тап по элементу медленный** (~2 с): XCUITest ждёт `waitForExistence` и простоя приложения. Тап по координатам в 3 раза быстрее. В фазе 4 стоит искать, как отключить ожидание простоя (WebDriverAgent делает это через приватный API).
- **Компактное дерево** схлопывает анонимные `[Other]`-контейнеры, иначе Settings даёт ~10 уровней пустых обёрток.
- **Кнопки громкости** в XCUITest недоступны для симулятора на этапе компиляции — нужен `#if !targetEnvironment(simulator)`.
- **Агент как fallback на симуляторе работает** без изменений кода.
- **Личные данные.** Дерево Settings на личном телефоне содержит имя аккаунта и SSID Wi-Fi. `describe_ui` будет отдавать это агенту — стоит упомянуть в README сервера.

## Открытый вопрос: ввод на iPhone без агента

iPhone объявляет те же CoreDevice-фичи, что и `dtuhidd` в симуляторе: `remote.hid.{digitizer,button,keyboard,scroll}` (но не accessibility). Значит, тапы и клавиатуру на iPhone, вероятно, можно слать без XCUITest: быстрее старт, нет подписи. Сторонние реализации ([pymobiledevice3](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/remote/core_device/hid_service.py), go-ios) ходят туда через RemoteXPC. Быстрая проверка: системный туннель CoreDevice поднят (`utun`, адрес устройства `fdde:…::1`), но RSD-порт 58783 по нему напрямую не отвечает. Чтобы ответить, нужен отдельный спайк: найти порт RSD системного туннеля или поднять свой, и реализовать RemoteXPC (HTTP/2 + XPC wire format). AX-дерево в любом случае остаётся за агентом.
