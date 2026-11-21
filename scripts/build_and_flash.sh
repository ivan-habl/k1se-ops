#!/usr/bin/env bash
# =============================================================================
#  build_and_flash.sh — детерминированная сборка и прошивка K1 SE
#  (host MCU + [mcu] GD32F303RET6 + [nozzle_mcu] GD32F303CBT6 через Katapult)
#  Живёт в ~/k1se-ops/scripts/, оставляет ~/klipper 100% чистым для Git/Moonraker.
# =============================================================================
set -euo pipefail

# ----------------------------- конфигурация ---------------------------------
OPS_DIR="$HOME/k1se-ops"
PROFILES_DIR="$OPS_DIR/configs"
OUTFW_DIR="$OPS_DIR/builds"

KLIPPER_DIR="$HOME/klipper"
KATAPULT_DIR="$HOME/katapult"
FLASHTOOL="$KATAPULT_DIR/scripts/flashtool.py"
PY="$HOME/klippy-env/bin/python3"
LOG="$HOME/printer_data/logs/klippy.log"

BYID="/dev/serial/by-id/usb-R2AXZ_Kirill_Kotyagin_Bluepill_Serial_Monster_1319030132124353354B4E00"
MCU_PORT="${BYID}-if00"
NOZ_PORT="${BYID}-if04"
BAUD=230400

INIT_MCU='PC7,PB0'          # PC7 — затвор +24В головы, PB0 — подсветка
INIT_NOZ='!PB5,!PB6,!PB7'   # заводская защита: кулеры и MOSFET хотэнда в 0

BUILD_LOG="/tmp/klipper-build.log"
MODE="${1:-all}"

# ------------------------------- утилиты ------------------------------------
log()  { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
warn() { printf '\033[33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[31m[ОШИБКА] %s\033[0m\n' "$*" >&2; exit 1; }

preflight() {
    local check_ports="${1:-1}"
    command -v make >/dev/null || die "нет make"
    command -v arm-none-eabi-gcc >/dev/null || die "нет arm-none-eabi-gcc в PATH"
    [[ -x "$PY" ]]            || die "нет python в klippy-env: $PY"
    [[ -f "$FLASHTOOL" ]]     || die "нет flashtool.py: $FLASHTOOL"
    if [[ "$check_ports" == "1" ]]; then
        [[ -e "$MCU_PORT" ]]  || die "нет порта $MCU_PORT"
        [[ -e "$NOZ_PORT" ]]  || die "нет порта $NOZ_PORT"
    fi
}

# ----------------------------- профили --------------------------------------
write_profiles() {
    mkdir -p "$PROFILES_DIR"

    cat > "$PROFILES_DIR/klipper-host.config" <<'CONF'
CONFIG_LOW_LEVEL_OPTIONS=y
CONFIG_MACH_LINUX=y
CONF

    cat > "$PROFILES_DIR/klipper-mcu.config" <<CONF
CONFIG_LOW_LEVEL_OPTIONS=y
CONFIG_MACH_STM32=y
CONFIG_MACH_GD32F303=y
CONFIG_STM32_FLASH_START_2000=y
CONFIG_STM32_CLOCK_REF_8M=y
CONFIG_STM32_SERIAL_USART2=y
CONFIG_SERIAL_BAUD=$BAUD
CONFIG_INITIAL_PINS="$INIT_MCU"
CONF

    cat > "$PROFILES_DIR/klipper-nozzle.config" <<CONF
CONFIG_LOW_LEVEL_OPTIONS=y
CONFIG_MACH_STM32=y
CONFIG_MACH_GD32F303=y
CONFIG_STM32_FLASH_START_2000=y
CONFIG_STM32_CLOCK_REF_8M=y
CONFIG_STM32_SERIAL_USART2=y
CONFIG_SERIAL_BAUD=$BAUD
CONFIG_INITIAL_PINS="$INIT_NOZ"
CONF

    log "Профили сборки записаны в $PROFILES_DIR"
    grep -H "INITIAL_PINS" "$PROFILES_DIR/klipper-mcu.config" "$PROFILES_DIR/klipper-nozzle.config"
}

# ----------------------------- сборка ---------------------------------------
# $1 — профиль, $2 — ожидаемые INITIAL_PINS ("" для host), $3 — артефакт на выходе
build_target() {
    local profile="$1" expect="$2" outfile="$3"

    cd "$KLIPPER_DIR"
    cp "$profile" .config
    make olddefconfig >/dev/null 2>&1 || die "olddefconfig для $(basename "$profile") упал"
    rm -rf out                                   # всегда с нуля: детерминизм
    log "Сборка $(basename "$profile") (-j1)"

    if ! make -j1 >"$BUILD_LOG" 2>&1; then
        tail -25 "$BUILD_LOG" >&2
        die "сборка $(basename "$profile") упала"
    fi

    if [[ -n "$expect" ]]; then
        grep -q "CONFIG_INITIAL_PINS \"$expect\"" out/autoconf.h \
            || { grep "INITIAL_PINS" out/autoconf.h || true; die "в autoconf.h не '$expect'"; }
        grep "INITIAL_PINS" out/autoconf.h
    fi

    [[ -f "$outfile" ]] || die "не создан артефакт $outfile"
    echo "ok: $(basename "$profile")"
}

build_all() {
    local rev
    rev=$(git -C "$KLIPPER_DIR" describe --tags --always --dirty)
    mkdir -p "$OUTFW_DIR"

    log "Ревизия Klipper: $rev"

    # 1. Linux MCU (host) — по WITH_HOST=1
    if [[ "${WITH_HOST:-0}" == "1" ]]; then
        build_target "$PROFILES_DIR/klipper-host.config" "" "$KLIPPER_DIR/out/klipper.elf"
        sudo systemctl stop klipper klipper-mcu || true
        sudo cp "$KLIPPER_DIR/out/klipper.elf" /usr/local/bin/klipper_mcu.new
        sudo mv -f /usr/local/bin/klipper_mcu.new /usr/local/bin/klipper_mcu
        echo "host MCU установлен ($rev)"
        if [[ "$MODE" == "build" ]]; then
            sudo systemctl start klipper-mcu klipper || true
        fi
    else
        echo "host MCU пропущен (запустите с WITH_HOST=1 чтобы пересобрать)"
    fi

    # 2. Основная плата (GD32F303RET6, USART2, PC7+PB0)
    build_target "$PROFILES_DIR/klipper-mcu.config" "$INIT_MCU" "$KLIPPER_DIR/out/klipper.bin"
    cp "$KLIPPER_DIR/out/klipper.bin" "$OUTFW_DIR/mcu_klipper-${rev}.bin"
    ln -sf "mcu_klipper-${rev}.bin"   "$OUTFW_DIR/mcu_klipper.bin"

    # 3. Плата головы (GD32F303CBT6, USART2, !PB5,!PB6,!PB7)
    build_target "$PROFILES_DIR/klipper-nozzle.config" "$INIT_NOZ" "$KLIPPER_DIR/out/klipper.bin"
    cp "$KLIPPER_DIR/out/klipper.bin" "$OUTFW_DIR/noz_klipper-${rev}.bin"
    ln -sf "noz_klipper-${rev}.bin"   "$OUTFW_DIR/noz_klipper.bin"

    ls -lh "$OUTFW_DIR"/mcu_klipper*.bin "$OUTFW_DIR"/noz_klipper*.bin
}

# ----------------------------- прошивка -------------------------------------
enter_katapult() {
    local port="$1"
    "$PY" - "$port" "$BAUD" <<'PY'
import sys, time, serial
port, baud = sys.argv[1], int(sys.argv[2])
s = serial.Serial(port, baud, timeout=0.5)
s.write(b'~ \x1c Request Serial Bootloader\x21\x21 ~')
s.flush(); s.close(); time.sleep(0.4)
PY
}

flash_one() {
    local port="$1" bin="$2"
    [[ -f "$bin" ]] || die "нет файла прошивки: $bin"
    log "Прошивка $(readlink -f "$bin" | xargs basename) -> $port"
    enter_katapult "$port"
    "$PY" "$FLASHTOOL" -d "$port" -b "$BAUD" -f "$bin"
}

flash_all() {
    trap 'sudo systemctl start klipper-mcu klipper >/dev/null 2>&1 || true' EXIT
    sudo systemctl stop klipper klipper-mcu || true

    # Сначала основная плата: её приложение поднимет PC7 и запитает голову.
    flash_one "$MCU_PORT" "$OUTFW_DIR/mcu_klipper.bin"
    sleep 2

    # Голова уже под питанием — можно прошивать.
    flash_one "$NOZ_PORT" "$OUTFW_DIR/noz_klipper.bin"

    sudo systemctl start klipper-mcu klipper
}

# ----------------------------- проверка -------------------------------------
verify() {
    log "Проверка последнего запуска по klippy.log"
    [[ -f "$LOG" ]] || die "нет лога $LOG"

    local boot_log
    boot_log=$(tr -d '\0' < "$LOG" | awk '/^Start printer at /{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}')

    echo "--- константы из прошивок ---"
    grep "INITIAL_PINS=" <<< "$boot_log" || true

    echo "--- подключённые MCU ---"
    grep "Loaded MCU" <<< "$boot_log" || true

    echo "--- ожидаемое ---"
    echo "  mcu:        INITIAL_PINS=$INIT_MCU"
    echo "  nozzle_mcu: INITIAL_PINS=$INIT_NOZ"

    if grep -q "INITIAL_PINS=$INIT_MCU" <<< "$boot_log" && grep -q "INITIAL_PINS=$INIT_NOZ" <<< "$boot_log"; then
        echo; echo "ОБА MCU С ПРАВИЛЬНЫМИ ПИНАМИ"
    else
        warn "не все константы найдены в последнем запуске — смотрите строки выше"
    fi
}

# ------------------------------- main ---------------------------------------
case "$MODE" in
    profiles)    write_profiles ;;
    build)       preflight 0; write_profiles; build_all ;;
    flash)       preflight 1; flash_all; sleep 10; verify ;;
    verify)      verify ;;
    all)         preflight 1; write_profiles; build_all; flash_all; sleep 10; verify ;;
    *)           echo "usage: [WITH_HOST=1] $0 {all|profiles|build|flash|verify}"; exit 1 ;;
esac
