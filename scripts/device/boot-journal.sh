#!/bin/sh
# Журнал загрузок и выключений для вкладки «Система» в панели.
# Вызывается из /etc/init.d/S97station-root: start -> boot, stop -> shutdown.
F=/data/local/tmp/boots.log
[ -f "$F" ] || : > "$F"
TS=$(date +%s)
ISO=$(date '+%Y-%m-%d %H:%M:%S')
case "$ISO" in
  1970*|1969*) ISO="до NTP, up$(cut -d. -f1 /proc/uptime)s" ;;
esac
echo "$1|$TS|$ISO" >> "$F"
# журнал не должен расти: держим последние 200 записей
tail -200 "$F" > "$F.t" 2>/dev/null && mv "$F.t" "$F"
