#!/usr/bin/env bash
set -euo pipefail

OPS_DIR="$HOME/k1se-ops"
KLIPPER_DIR="$HOME/klipper"
REV=$(git -C "$KLIPPER_DIR" describe --tags --always --dirty)
mkdir -p "$OPS_DIR/builds"

build_mcu() {
  local name="$1"
  local cfg="$OPS_DIR/configs/klipper-${name}.config"
  local out_dir="out-${name}/"

  echo "=== Building Klipper [${name}] @ ${REV} ==="
  make -C "$KLIPPER_DIR" KCONFIG_CONFIG="$cfg" OUT="$out_dir" olddefconfig
  make -C "$KLIPPER_DIR" KCONFIG_CONFIG="$cfg" OUT="$out_dir" -j"$(nproc)"

  if [[ "$name" == "host" ]]; then
    cp "$KLIPPER_DIR/${out_dir}klipper.elf.hex" "$OPS_DIR/builds/klipper-host-${REV}.elf" 2>/dev/null || \
    cp "$KLIPPER_DIR/${out_dir}klipper.elf"     "$OPS_DIR/builds/klipper-host-${REV}.elf"
    ln -sf "klipper-host-${REV}.elf"            "$OPS_DIR/builds/klipper-host-latest.elf"
  else
    cp "$KLIPPER_DIR/${out_dir}klipper.bin"     "$OPS_DIR/builds/klipper-${name}-${REV}.bin"
    ln -sf "klipper-${name}-${REV}.bin"         "$OPS_DIR/builds/klipper-${name}-latest.bin"
  fi
}

TARGETS=("$@")
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  TARGETS=(mcu nozzle host)
fi

for t in "${TARGETS[@]}"; do
  build_mcu "$t"
done

echo "=== Built artifacts ==="
ls -lh "$OPS_DIR/builds/"*-latest.*
