# Спайк 0A — SimBridge на симуляторе

Прототип без MCP: `SimBridgeSpike.m` (ввод + AX-дерево) и `DTUHIDProbe.m` (отладочный клиент протокола `dtuhidd`).

```bash
make -C Spikes/0A-SimBridge
B=Spikes/0A-SimBridge/.build/simbridge-spike
$B list
$B tap booted 201 717            # координаты в pt
$B swipe booted 350 450 50 450 250
$B button booted home            # home, lock, side, siri, volume_up, volume_down
$B type booted 'Hello, World! 123'
$B key booted 0x04 0xe3          # Cmd+A (usage + модификаторы)
$B ui booted                     # AX-дерево фронтального приложения
$B point booted 201 319          # элемент под точкой
$B indigo-tap booted 201 319     # legacy Indigo, для сравнения
```

Проверено на Xcode 27.1, iOS 27.0, iPhone 16 Pro, 22.10.2026.

## Итог

| Шаг плана | Результат |
|---|---|
| 1. `SimServiceContext` → `SimDeviceSet` → `SimDevice` | ✅ |
| 2. Тап по координатам открывает приложение | ✅ через `dtuhidd`; legacy Indigo тоже сработал, но см. ниже |
| 3. Клавиатура и Home | ✅ только через `dtuhidd`. Legacy Indigo в Xcode 27 **не работает** |
| 4. AX-дерево Settings с координатами, как на скриншоте | ✅ фреймы в pt совпадают с пикселями скриншота (×3) |

## Главная находка: legacy Indigo в Xcode 27 сломан для кнопок и клавиатуры

`SimDeviceLegacyHIDClient` + `IndigoHIDMessageForButton` / `ForKeyboardArbitrary` / `ForHIDArbitrary` отправляются без ошибок, но события до backboardd не доходят (проверено логом backboardd). Начиная с CoreSimulator 1155.4 гость молча отбрасывает Indigo-кнопки и клавиатуру, а Indigo-touch доставляет ненадёжно ([idb README](https://github.com/facebook/idb/blob/main/FBSimulatorControl/README.md)). Simulator.app заменён на DeviceHub.app, который сам Indigo не использует.

### Рабочий путь: `dtuhidd`

В каждом симуляторе крутится демон CoreDevice `dtuhidd` (`CoreSimulator.framework/Resources/Platforms/iphoneos/usr/libexec/dtuhidd`). Он публикует mach-сервисы `com.apple.coredevice.feature.remote.hid.{digitizer,button,keyboard,scroll,vendordefined}` и принимает обычные XPC-словари.

Подключение с хоста:
1. `-[SimDevice lookup:error:]` → send right на сервис `com.apple.coredevice.feature.remote.hid.digitizer` в bootstrap-namespace симулятора.
2. `xpc_endpoint_create_mach_port_4sim(port, 0, 0)` → `xpc_connection_create_from_endpoint`.
3. **`xpc_connection_enable_sim2host_4sim(conn)`** — без этого демон видит peer, но не получает ни одного сообщения (на это ушло больше всего времени).
4. Barrier-сообщение с ответом: демон запускается по требованию и выбрасывает события, пришедшие до активации peer. Ответ приходит через ~600 мс, после него ждём ещё ~200 мс.

Конверт (все числа — `uint64`):

```
{ messageType: "IndigoDigitizerEvent" | "IndigoButtonEvent" | "IndigoKeyboardButtonEvent",
  isBarrier: bool, featureIdentifier: <имя сервиса>, payload: {...} }
```

| messageType | payload |
|---|---|
| `IndigoDigitizerEvent` | `pointOne {x, y}` (доли 0…1 от экрана в pt), `pointTwo?`, `eventType` (0 start / 1 position / 2 end), `edge`, `target` |
| `IndigoButtonEvent` | `usagePage` 0x0C, `usageCode` (Home 0x40, Lock 0x30, Side 0x95, Siri 0xCF, Vol+ 0xE9, Vol− 0xEA), `state` (1 down / 2 up) |
| `IndigoKeyboardButtonEvent` | `usageCode` (USB HID, модификаторы 0xE0–0xE7), `state` |

Формат сверен с MIT-кодом idb ([DTUHIDModels.swift](https://github.com/facebook/idb/blob/main/FBSimulatorControl/HID/DTUHIDModels.swift), [SimulatorXPCConnection.swift](https://github.com/facebook/idb/blob/main/FBSimulatorControl/XPC/SimulatorXPCConnection.swift)).

## Остальное

- **Не-ASCII текст:** `xcrun simctl pbcopy` в Xcode 27 буфер симулятора не меняет. Работает `devicectl device pasteboard copy -d <udid>` + Cmd+V (`key 0x19 0xe3`); кириллица и эмодзи вставляются без диалога «Разрешить вставку».
- **AX:** `AXPTranslator.sharedInstance` + делегат с `accessibilityTranslationDelegateBridgeCallbackWithToken:`, который проксирует запрос в `-[SimDevice sendAccessibilityRequestAsync:…]`. Первый запрос после старта AX-рантайма ~3,3 с, дальше 30–50 мс на экран. Фреймы приходят сразу в pt.
- **Задержки:** новое соединение с `dtuhidd` стоит ~0,8 с (barrier + хвост), поэтому в сервере соединение должно жить всю сессию. Сами события — единицы миллисекунд.
- **Подводные камни из чужого опыта** (idb, AXe): `dtuhidd` может упасть на медленной загрузке и быть придушен launchd на ~10 с — нужен ретрай barrier с бэкоффом; на рантаймах старше iOS 18 в Xcode 27.0 ввод не работает.

## Что это меняет в плане

- `SimBridge` = CoreSimulator (lookup, AX) + клиент `dtuhidd` (весь ввод). SimulatorKit и Indigo не нужны — минус одна зависимость от приватного Swift-класса.
- `type_text` в режиме `paste` использует `devicectl pasteboard`, а не `simctl pbcopy`.
- `doctor` должен проверять доступность сервиса `dtuhidd` (barrier с таймаутом), а не символы SimulatorKit.
- `dtuhidd` — это CoreDevice-фича `remote.hid.*`. На физических устройствах те же фичи доступны через RemoteXPC при смонтированном DDI ([pymobiledevice3](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/remote/core_device/hid_service.py), go-ios). Потенциально это ввод на iPhone без XCUITest — стоит проверить в рамках 0B.
