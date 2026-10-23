#!/bin/sh
# Assemble the SAM MOD player objects and a B-DOS boot disk with pyz80.
# Usage: ./build.sh [b-dos|atom-lite|trinity|samdos]
set -e
cd "$(dirname "$0")"

dos=res/dos/B-DOS15a
case "$1" in
    atom-lite) dos=res/dos/AL-BDOS15a ;;
    trinity)   dos=res/dos/bdos15t-6 ;;
    samdos)    dos=res/dos/samdos2 ;;
esac

version=$(sed -n 's/^version *= *//p' .properties)
printf '; SAM MOD player version\n\ndefm "%s"\n' "$version" > src/constants/text.version.i

mkdir -p obj
for s in loader demo burstplayer tracker; do
    src=src/$s.s
    [ -d src/$s ] && src=src/$s/$s.s
    extra=""
    [ $s = burstplayer ] && extra="-D debug"
    pyz80 --obj=obj/$s --mapfile=obj/$s.map $extra $src
done

pyz80 -I $dos -I res/loading.\$ -I obj/tracker -I obj/burstplayer \
      -I obj/loader -I obj/demo \
      -o obj/SAM.MOD.player.$version.mgt --nozip src/boot.s

echo "built obj/SAM.MOD.player.$version.mgt"
