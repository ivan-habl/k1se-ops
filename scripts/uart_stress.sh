#!/bin/bash
API=http://localhost:7125
L=~/printer_data/logs/klippy.log
START=$(wc -l < $L)
N=${1:-30}; F=${2:-1500}; CUR=${3:-0.30}
ok=0; fail=0
g() { curl -s --max-time 180 -X POST "$API/printer/gcode/script" --data-urlencode "script=$1" -o /tmp/g.out -w "%{http_code}"; }
state() { curl -s $API/printer/info | grep -a -o '"state":"[a-z]*"'; }
for i in $(seq 1 $N); do
  if [ "$(state)" != '"state":"ready"' ]; then
    curl -s -X POST $API/printer/firmware_restart >/dev/null; sleep 25
  fi
  g "SET_TMC_CURRENT STEPPER=stepper_x CURRENT=$CUR
SET_TMC_CURRENT STEPPER=stepper_y CURRENT=$CUR
SET_KINEMATIC_POSITION X=114 Y=113 Z=5" >/dev/null
  c=$(g "G91
G1 X30 F$F
DUMP_TMC STEPPER=stepper_x
DUMP_TMC STEPPER=stepper_y
DUMP_TMC STEPPER=stepper_x
DUMP_TMC STEPPER=stepper_y
G1 X-30 F$F
DUMP_TMC STEPPER=stepper_x
DUMP_TMC STEPPER=stepper_y
M400
G90")
  if [ "$c" = "200" ]; then ok=$((ok+1)); else fail=$((fail+1)); fi
  g "M84" >/dev/null; sleep 1
done
echo "RESULT: OK=$ok FAIL=$fail of $N (F=$F, I=$CUR A)"
tail -n +$START $L | grep -a "Transition to shutdown" | sort | uniq -c
