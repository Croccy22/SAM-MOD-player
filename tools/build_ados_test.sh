#!/bin/bash
# build_ados_test.sh [OUT.mgt] - assembles the player as build.xml does, with
# no DOS on the disk (for ADOS, which is already loaded: DIR = "the.mgt" then
# BOOT), using pyz80 from PATH.
set -e
cd "$(dirname "$0")/.."
OUT=${1:-obj/SAM.MOD.player.ados.mgt}
mkdir -p obj
pyz80 --obj=obj/loader --exportfile=obj/loader.sym --mapfile=obj/loader.map src/loader/loader.s >/dev/null
pyz80 --obj=obj/ados --importfile=obj/loader.sym --mapfile=obj/ados.map src/loader/ados.s >/dev/null
pyz80 --obj=obj/demo src/demo/demo.s >/dev/null
pyz80 -D debug --obj=obj/burstplayer src/burstplayer.s >/dev/null
pyz80 --obj=obj/tracker src/tracker/tracker.s >/dev/null
pyz80 --obj=res/test.m src/test.mod.s >/dev/null
pyz80 -I res/loading.\$ -I obj/tracker -I obj/burstplayer -I obj/loader -I obj/demo -I obj/ados \
      -I res/test.m -o "$OUT" --nozip src/boot.s >/dev/null
echo "$OUT"
