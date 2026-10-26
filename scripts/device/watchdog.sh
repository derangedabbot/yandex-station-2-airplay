#!/bin/sh
# Сторож за демонами колонки. Правила:
#  * ничего не убивает — только поднимает отсутствующее;
#  * не трогает mediad, пока жива AirPlay-сессия (его гасит распорядитель намеренно);
#  * один сервис поднимает не чаще раза в 5 минут (кулдаун), чтобы не дёргать в цикле;
#  * каждый случай пишет в лог с датой.
# Запускается из /etc/init.d/S97station-root, живёт одним экземпляром.
LOG=/data/local/tmp/watchdog.log
PIDF=/run/watchdog.pid
INTERVAL=60
COOLDOWN=300

if [ -f "$PIDF" ]; then
  OLD=$(cat "$PIDF" 2>/dev/null)
  if [ -n "$OLD" ] && [ "$OLD" != "$$" ] && grep -qa 'watchdog.sh' "/proc/$OLD/cmdline" 2>/dev/null; then
    exit 0
  fi
fi
echo $$ > "$PIDF"

# В первые секунды после загрузки часов ещё нет (NTP не отработал) — в логе
# получается 1970 год. Тогда пишем время от старта системы.
log() {
  T=$(date '+%Y-%m-%d %H:%M:%S')
  case "$T" in 1970*|1969*) T="up$(cut -d. -f1 /proc/uptime)s" ;; esac
  echo "$T $*" >> "$LOG"
}

# лог не должен расти бесконечно
if [ -f "$LOG" ]; then
  SZ=$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')
  if [ -n "$SZ" ] && [ "$SZ" -gt 200000 ]; then
    tail -300 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
fi

airplay_active() {
  for t in /proc/net/tcp /proc/net/tcp6; do
    [ -r "$t" ] || continue
    awk 'FNR>1 { split($2,a,":"); if ((a[length(a)]=="1B58" || a[length(a)]=="1388") && $4=="01") f=1 } END { exit(f?0:1) }' "$t" && return 0
  done
  return 1
}

has() {  # есть ли процесс, в командной строке которого встречается подстрока $1
  for d in /proc/[0-9]*; do
    c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
    case "$c" in *"$1"*) return 0 ;; esac
  done
  return 1
}

listening() {  # слушает ли кто-то TCP-порт из аргумента (в hex)
  for t in /proc/net/tcp /proc/net/tcp6; do
    [ -r "$t" ] || continue
    awk -v p="$1" 'FNR>1 { split($2,a,":"); if (a[length(a)]==p && $4=="0A") f=1 } END { exit(f?0:1) }' "$t" && return 0
  done
  return 1
}

try() {  # try <имя> <команда...>
  name=$1; shift
  eval "last=\$LAST_$name"
  last=${last:-0}
  now=$(date +%s)
  if [ $((now - last)) -lt $COOLDOWN ]; then
    return 0
  fi
  log "$name не работает — поднимаю"
  # Вывод демона в лог сторожа не пускаем: audio-owner живёт вечно и писал туда всё,
  # из-за чего лог распухал до мегабайтов. У каждого демона свой лог.
  "$@" >/dev/null 2>&1 &
  eval "LAST_$name=$now"
}

log "сторож запущен (pid $$)"
while :; do
  /data/local/opt/zvuk/bin/zvukd ping 2>/dev/null | grep -q pong || try zvukd /data/local/bin/zvukd-start.sh
  has 'airplay2/bin/shairport-sync' || try shairport /bin/sh /data/local/bin/run-sps.sh
  has 'audio-owner.sh' || try owner /bin/sh /data/local/bin/audio-owner.sh
  has 'alice-voice.sh' || try voice /bin/sh /data/local/bin/alice-voice.sh
  if airplay_active; then
    : # звук у приёмника, mediad гасится намеренно — не трогаем
  else
    has 'maind --mediad' || try mediad /data/local/bin/start-mediad.sh
  fi
  listening 1F91 || try panel /bin/sh /data/local/bin/panel-server.sh

  # подрезка лога в цикле: на старте её мало, демоны шумят
  SZ=$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')
  if [ -n "$SZ" ] && [ "$SZ" -gt 200000 ]; then
    tail -300 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
  fi
  sleep $INTERVAL
done
