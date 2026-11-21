# Creality K1 SE — Vanilla Klipper (GD32F303 + CS1237) Ops

Репозиторий-оркестратор для поддержания **ванильного Klipper** (`v0.14.0+`) и **Katapult** на модернизированном **Creality K1 SE** с нативной поддержкой `GD32F303` и детерминированной сборкой/прошивкой всех 3 MCU.

---

## Аппаратная конфигурация

| Компонент | Детали |
|---|---|
| **Принтер** | Creality K1 SE |
| **Тензодатчики** | 4 штатных датчика запараллелены → **CS1237** на главном `mcu`. Плата стола (`GD32E230`) удалена. |
| **Хост** | **Orange Pi Zero 3** (Armbian Linux) + Linux `host` MCU (`klipper-mcu.service`) |
| **Связь Хост ↔ MCU** | USB-UART **Bluepill Serial Monster** (`230400` бод, общая земля) |
| **`mcu` (Mainboard)** | `GD32F303RET6`, `120 MHz` (8 МГц XTAL), `USART2` (`*-if00`), Katapult @ `0x08002000`, `INITIAL_PINS="PC7,PB0"` |
| **`nozzle_mcu` (Head)** | `GD32F303CBT6`, `120 MHz` (8 МГц XTAL), `USART2` (`*-if04`), Katapult @ `0x08002000`, `INITIAL_PINS="!PB5,!PB6,!PB7"` |

> **Порядок прошивки:** сначала всегда `mcu` (поднимает `PC7` = +24 В на голову), затем `nozzle_mcu`. Зашито в `scripts/build_and_flash.sh`.

---

## Карта репозиториев (`ivan-habl`)

| Репозиторий | Путь на Orange Pi | Ветка | Назначение |
|---|---|---|---|
| `ivan-habl/klipper` | `~/klipper` | `k1se-gd32` | Ванильный `Klipper3d/klipper` (`upstream`) + выборка PR #7369 + 2 фикса |
| `ivan-habl/katapult` | `~/katapult` | `k1se-gd32` | `Arksine/katapult` (`upstream`) + PR #191 (GD32F303) |
| `ivan-habl/k1se-ops` | `~/k1se-ops` | `main` | Kconfig-профили, патчи, скрипты сборки/прошивки и тестов |
| `ivan-habl/k1se-printer-config` | `~/printer_data/config` | `main` | Приватный бэкап конфигов (`CS1237`, макросы, `ext/`) |

---

## Патчи поверх PR #7369 (Root-Cause Analysis)

Ветка `k1se-gd32` в `~/klipper` содержит 3 атомарных коммита поверх `upstream/master` (копии в `patches/`):

1. **`feat(gd32f303): apply PR #7369 selection (PR head 9edd5a34)`** — выборка из 9 файлов для `GD32F303` (без `GD32E230`).
2. **`armcm_timer: fix GD32F303 SysTick one-shot and clear PENDST`** (`src/generic/armcm_timer.c`):
   - *Причина:* в PR #7369 убрано `SysTick->LOAD = 0` в `timer_set_diff()`, из-за чего SysTick перешёл в Auto-Reload. При быстрых шагах (`stepper_event`) и вложенных прерываниях `USART2` (`timer_kick()`) взводился паразитный `SCB_ICSR_PENDSTSET`, вызывая преждевременный повторный вход в `SysTick_Handler()` и сбой таймингов `tmcuart`.
   - *Фикс:* остановка `SysTick->LOAD = 0` в `SysTick_Handler()` и сброс `SCB->ICSR = SCB_ICSR_PENDSTCLR_Msk` в `SysTick_Handler()` и `timer_set_diff()`.
3. **`tmcuart: keep fixed cfg_bit_time on 32-bit MCU and extend RX window`** (`src/tmcuart.c`):
   - *Причина:* AVR-коррекция `t->bit_time` по синхро-нибблу при разовом джиттере на 5-м суб-бите сдвигала частоту чтения всех 80 суб-битов ответа драйвера.
   - *Фикс:* фиксированный `t->bit_time = t->cfg_bit_time` на 120 МГц МК и окно ожидания старт-бита `128` суб-битов.

---

## Структура `~/k1se-ops`

```text
~/k1se-ops/
├── README.md
├── configs/           # klipper-{host,mcu,nozzle}.config, katapult-{mcu,nozzle}.config
├── patches/           # git format-patch (0001..0003)
├── scripts/
│   ├── build_and_flash.sh   # сборка (-j1, rm -rf out), Katapult flash, verify()
│   └── uart_stress.sh       # стресс-тест TMC UART
├── builds/            # (.gitignore) .bin с Git-версией + симлинки
└── katapult-outfw/    # (локально, *.bin в .gitignore) эталонные .bin Katapult
```

---

## Runbook (повседневная эксплуатация)

### Сборка и прошивка MCU

```bash
~/k1se-ops/scripts/build_and_flash.sh all              # mcu + nozzle_mcu + verify
WITH_HOST=1 ~/k1se-ops/scripts/build_and_flash.sh all  # все 3 MCU (включая host)
~/k1se-ops/scripts/build_and_flash.sh build            # только сборка и проверка INITIAL_PINS
~/k1se-ops/scripts/build_and_flash.sh flash            # только прошивка + verify
~/k1se-ops/scripts/build_and_flash.sh verify           # проверка последнего запуска
```

### Обновление до нового официального Klipper

```bash
cd ~/klipper
git fetch upstream --tags
git branch -f master upstream/master
git rebase upstream/master
git push --force-with-lease origin k1se-gd32
WITH_HOST=1 ~/k1se-ops/scripts/build_and_flash.sh all
```

### Бэкап конфигов принтера (`~/printer_data/config`)

```bash
cd ~/printer_data/config
git add -A && git commit -m "Update printer config / SAVE_CONFIG" && git push
```

### Проверка чистоты репозиториев

```bash
git -C ~/klipper status -sb && git -C ~/katapult status -sb
```

---

## Runbook (повседневная эксплуатация)

### Сборка и прошивка MCU

```bash
~/k1se-ops/scripts/build_and_flash.sh all              # mcu + nozzle_mcu + verify
WITH_HOST=1 ~/k1se-ops/scripts/build_and_flash.sh all  # все 3 MCU (включая host)
~/k1se-ops/scripts/build_and_flash.sh build            # только сборка и проверка INITIAL_PINS
~/k1se-ops/scripts/build_and_flash.sh flash            # только прошивка + verify
~/k1se-ops/scripts/build_and_flash.sh verify           # проверка последнего запуска
```

### Обновление до нового официального Klipper

```bash
cd ~/klipper
git fetch upstream --tags
git branch -f master upstream/master
git rebase upstream/master
git push --force-with-lease origin k1se-gd32
WITH_HOST=1 ~/k1se-ops/scripts/build_and_flash.sh all
```

### Бэкап конфигов принтера (`~/printer_data/config`)

```bash
cd ~/printer_data/config
git add -A && git commit -m "Update printer config / SAVE_CONFIG" && git push
```

### Проверка чистоты репозиториев

```bash
git -C ~/klipper status -sb && git -C ~/katapult status -sb
```
