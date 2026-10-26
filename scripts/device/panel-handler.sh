#!/bin/sh
# Обработчик запросов панели. Запускается socat'ом на каждое соединение.
#   /                      — страница
#   /api/status            — JSON со всем состоянием
#   /action?do=…&t=TOKEN   — действия (нужен токен)
#   /log?name=…            — хвост лога

T=/data/local/opt/airplay
L=/data/local/opt/tools/lib/ld-musl-aarch64.so.1
export LD_LIBRARY_PATH="$T/lib:/data/local/opt/tools/lib"
export ALSA_CONFIG_PATH=/data/local/etc/asound.conf

read -r REQ
while read -r H; do
  H=$(printf '%s' "$H" | tr -d '\r')
  [ -z "$H" ] && break
done
REQ=$(printf '%s' "$REQ" | tr -d '\r')
PATHQ=$(printf '%s' "$REQ" | awk '{print $2}')
URLPATH=${PATHQ%%\?*}
QUERY=${PATHQ#*\?}
[ "$QUERY" = "$PATHQ" ] && QUERY=""

qval() {
  printf '%s' "$QUERY" | tr '&' '\n' | awk -F= -v k="$1" '$1==k {print substr($0, length(k)+2); exit}'
}

send() {
  printf 'HTTP/1.1 200 OK\r\nContent-Type: %s\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n' "$1"
  printf '%s' "$2"
}

pcount() { ps w 2>/dev/null | grep -c "$1"; }

pcm_owner() {
  # Быстрый путь: ядро само называет владельца устройства (0 с вместо перебора
  # всех /proc — тот занимал 4 с на каждый запрос статуса и подвешивал панель).
  P=$(awk -F: '/owner_pid/ {gsub(/ /,"",$2); print $2}' /proc/asound/card0/pcm0p/sub0/status 2>/dev/null)
  if [ -n "$P" ] && [ "$P" != "0" ] && [ -d "/proc/$P" ]; then
    cat "/proc/$P/comm" 2>/dev/null
    return
  fi
  # Запасной путь: owner_pid бывает мёртвым — тогда ищем по открытым файлам.
  for p in $(ls /proc | grep -E '^[0-9]+$'); do
    for f in /proc/$p/fd/*; do
      t=$(readlink "$f" 2>/dev/null)
      case "$t" in *pcmC0D0p*) cat /proc/$p/comm 2>/dev/null; return;; esac
    done
  done
  echo "Свободно"
}

status_json() {
  SP=$(ps w | awk '/[s]hairport-sync/ {print $1}' | head -1)
  SH=0; [ -n "$SP" ] && SH=1
  AV=$(pcount '[a]vahi-daemon')
  NQ=$(pcount '[n]qptp')
  MD=$(pcount '[m]aind --mediad')
  UP=$(pcount '[u]pdatesd')
  EST=0; LPORT="—"
  if [ -n "$SP" ]; then
    LS=$(LD_LIBRARY_PATH="$T/lib:/data/local/opt/tools/lib" "$L" /data/local/opt/tools/bin/lsof -nP -a -p "$SP" -i TCP 2>/dev/null)
    EST=$(printf '%s\n' "$LS" | grep -c ESTABLISHED)
    LPORT=$(printf '%s\n' "$LS" | awk '/LISTEN/ {print $9}' | sed 's/.*://' | head -1)
    [ -z "$LPORT" ] && LPORT="—"
  fi
  UPT=$(cut -d. -f1 /proc/uptime)
  FREE=$(df -h /data 2>/dev/null | awk 'NR==2 {print $4}')
  TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
  [ -n "$TEMP" ] && TEMP=$((TEMP/1000)) || TEMP=0
  IP=$(ip -4 addr show wlan0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
  WC=/tmp/panel-wifi.txt
  WTS=/tmp/panel-wifi.ts
  WAGE=999
  if [ -f "$WTS" ]; then
    WSEEN=$(cat "$WTS" 2>/dev/null)
    case "$WSEEN" in ''|*[!0-9]*) WSEEN=0 ;; esac
    WAGE=$(( $(date +%s) - WSEEN ))
  fi
  if [ -f "$WC" ] && [ "$WAGE" -ge 0 ] && [ "$WAGE" -lt 60 ]; then
    WST=$(cat "$WC" 2>/dev/null)
  else
    WST=$(wpa_cli -i wlan0 status 2>/dev/null)
    printf '%s' "$WST" > "$WC" 2>/dev/null
    date +%s > "$WTS" 2>/dev/null
  fi
  SSID=$(printf '%s\n' "$WST" | awk -F= '/^ssid=/ {print substr($0,6); exit}')
  FRQ=$(printf '%s\n' "$WST" | awk -F= '/^freq=/ {print $2; exit}')
  BAND=""
  if [ -n "$FRQ" ]; then
    if [ "$FRQ" -ge 4000 ] 2>/dev/null; then BAND="5 ГГц"; else BAND="2.4 ГГц"; fi
  fi
  FW=$(cat /system/vendor/quasar/version_full 2>/dev/null)

  # --- нагрузка ---
  LOAD=$(cat /proc/loadavg)
  L1=$(printf '%s' "$LOAD" | awk '{print $1}')
  L5=$(printf '%s' "$LOAD" | awk '{print $2}')
  L15=$(printf '%s' "$LOAD" | awk '{print $3}')
  PROCS=$(printf '%s' "$LOAD" | awk '{print $4}')

  # --- процессор: разница /proc/stat с прошлым запросом ---
  CPU=$(awk '/^cpu / {t=0; for(i=2;i<=NF;i++) t+=$i; print t, $5+$6}' /proc/stat)
  PREV=$(cat /tmp/panel.stat 2>/dev/null)
  if [ -n "$PREV" ]; then
    CUR=1
  else
    sleep 0.4; CUR=0
  fi
  eval set -- $CPU
  T2=$1; I2=$2
  CPUPCT=""
  if [ -n "$PREV" ]; then
    set -- $PREV; T1=$1; I1=$2
    DT=$((T2-T1)); DI=$((I2-I1))
    [ "$DT" -gt 0 ] && CPUPCT=$(( (100 * (DT - DI)) / DT ))
  fi
  echo "$T2 $I2" > /tmp/panel.stat
  [ -z "$CPUPCT" ] && CPUPCT=0

  # --- память ---
  MEMT=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
  MEMA=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
  MEMU=$((MEMT - MEMA))
  [ -n "$MEMT" ] && [ "$MEMT" -gt 0 ] && MEMPCT=$(( 100 * MEMU / MEMT )) || MEMPCT=0

  # --- разделы (NAND/UBI: rootfs, /bkupgrade = /data, /tee) ---
  ROOT=$(df -k / 2>/dev/null | awk 'NR==2 {printf "%d/%dMB %d%%", int($3/1024), int($2/1024), $5+0}')
  DATA=$(df -k /bkupgrade 2>/dev/null | awk 'NR==2 {printf "%d/%dMB %d%%", int($3/1024), int($2/1024), $5+0}')
  TEE=$(df -k /tee 2>/dev/null | awk 'NR==2 {printf "%d/%dKB %d%%", $3, $2, $5+0}')

  # --- железо ---
  MODEL=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')
  CORES=$(grep -c ^processor /proc/cpuinfo)
  KERN=$(uname -r)

  # --- AirPlay: живая ли сессия (порт 7000, ESTABLISHED) ---
  APS=0
  for tt in /proc/net/tcp /proc/net/tcp6; do
    [ -r "$tt" ] || continue
    awk 'FNR>1 { split($2,a,":"); if ((a[length(a)]=="1B58" || a[length(a)]=="1388") && $4=="01") f=1 } END { exit(f?0:1) }' "$tt" && { APS=1; break; }
  done

  # --- плеер «Звук» ---
  ZS=off; ZT="—"
  ZOUT=$(/data/local/bin/zvukd status 2>/dev/null) || ZOUT=""
  case "$ZOUT" in
    play\|*)  ZS=play;  ZT=$(printf '%s' "$ZOUT" | cut -d'|' -f2) ;;
    pause\|*) ZS=pause; ZT=$(printf '%s' "$ZOUT" | cut -d'|' -f2) ;;
    idle\|*)  ZS=idle ;;
  esac
  ZC=""; ZI=0; ZN=0; ZP=0; ZD=0; ZAID=""; ZAL=""; ZSAV=0
  if [ -n "$ZOUT" ]; then
    ZC=$(printf '%s' "$ZOUT" | cut -d'|' -f4)
    ZI=$(printf '%s' "$ZOUT" | cut -d'|' -f5); ZI=${ZI:-0}
    ZN=$(printf '%s' "$ZOUT" | cut -d'|' -f6); ZN=${ZN:-0}
    ZP=$(printf '%s' "$ZOUT" | cut -d'|' -f7); ZP=${ZP:-0}
    ZD=$(printf '%s' "$ZOUT" | cut -d'|' -f8); ZD=${ZD:-0}
    ZAID=$(printf '%s' "$ZOUT" | cut -d'|' -f9)
    ZAL=$(printf '%s' "$ZOUT" | cut -d'|' -f10)
    ZSAV=$(printf '%s' "$ZOUT" | cut -d'|' -f11); ZSAV=${ZSAV:-0}
  fi

  echo "{\"fw\":\"${FW:-—}\",\"shairport\":$SH,\"airplay\":$APS,\"nqptp\":$NQ,\"avahi\":$AV,\"mediad\":$MD,\"updatesd\":$UP,\"listen\":\"${LPORT}\",\"playing\":$EST,\"pcm\":\"$(pcm_owner)\",\"zvuk\":\"$ZS\",\"zvuk_title\":\"$ZT\",\"zvuk_cover\":\"$ZC\",\"zvuk_idx\":$ZI,\"zvuk_total\":$ZN,\"zvuk_pos\":$ZP,\"zvuk_dur\":$ZD,\"zvuk_album_id\":\"$ZAID\",\"zvuk_album\":\"$ZAL\",\"zvuk_saved\":$ZSAV,\"uptime\":$((UPT/60)),\"free\":\"${FREE:--}\",\"temp\":$TEMP,\"ip\":\"${IP:-—}\",\"ssid\":\"${SSID:-—}\",\"band\":\"${BAND:-—}\",\"load1\":\"$L1\",\"load5\":\"$L5\",\"load15\":\"$L15\",\"procs\":\"$PROCS\",\"cpu\":$CPUPCT,\"mem_total\":${MEMT:-0},\"mem_used\":${MEMU:-0},\"mem_pct\":$MEMPCT,\"root\":\"${ROOT:-—}\",\"data\":\"${DATA:-—}\",\"tee\":\"${TEE:-—}\",\"model\":\"${MODEL:-—}\",\"cores\":${CORES:-0},\"kernel\":\"${KERN:-—}\"}"
}

do_action() {
  A=$(qval do)
  case "$A" in
    airplay-prev)
      send "text/plain; charset=utf-8" "$(/data/local/bin/airplay-ctl.sh prev >/dev/null 2>&1 && echo 'назад' || echo 'не вышло')" ;;
    airplay-toggle)
      send "text/plain; charset=utf-8" "$(/data/local/bin/airplay-ctl.sh toggle >/dev/null 2>&1 && echo 'пауза/играть' || echo 'не вышло')" ;;
    airplay-next)
      send "text/plain; charset=utf-8" "$(/data/local/bin/airplay-ctl.sh next >/dev/null 2>&1 && echo 'дальше' || echo 'не вышло')" ;;
    zvuk-flow)
      # запуск потока качает трек несколько секунд — панель не должна ждать
      ( /data/local/bin/zvukd flow >>/data/local/tmp/zvukd.log 2>&1 & )
      send "text/plain; charset=utf-8" "включаю Мой поток" ;;
    zvuk-next)
      ( /data/local/bin/zvukd next >>/data/local/tmp/zvukd.log 2>&1 & )
      send "text/plain; charset=utf-8" "следующий трек" ;;
    zvuk-pause)
      send "text/plain; charset=utf-8" "$(/data/local/bin/zvukd pause 2>&1)" ;;
    zvuk-resume)
      send "text/plain; charset=utf-8" "$(/data/local/bin/zvukd resume 2>&1)" ;;
    zvuk-stop)
      send "text/plain; charset=utf-8" "$(/data/local/bin/zvukd stop 2>&1)" ;;
    zvuk-shuffle)
      send "text/plain; charset=utf-8" "$(/data/local/bin/zvukd shuffle 2>&1)" ;;
    zvuk-resume-last)
      ( /data/local/bin/zvukd resume-last >>/data/local/tmp/zvukd.log 2>&1 & )
      send "text/plain; charset=utf-8" "продолжаю с сохранённого места" ;;
    zvuk-play-playlist-shuffled)
      ID=$(qval id)
      ( /data/local/bin/zvukd play-playlist-shuffled "$ID" >>/data/local/tmp/zvukd.log 2>&1 & )
      send "text/plain; charset=utf-8" "включаю плейлист вперемешку" ;;
    zvuk-play-playlist)
      ID=$(qval id)
      ( /data/local/bin/zvukd play-playlist "$ID" >>/data/local/tmp/zvukd.log 2>&1 & )
      send "text/plain; charset=utf-8" "включаю плейлист" ;;
    zvuk-play-album)
      ID=$(qval id)
      ( /data/local/bin/zvukd play-album "$ID" >>/data/local/tmp/zvukd.log 2>&1 & )
      send "text/plain; charset=utf-8" "включаю альбом" ;;
    zvuk-play-artist)
      ID=$(qval id)
      ( /data/local/bin/zvukd play-artist "$ID" >>/data/local/tmp/zvukd.log 2>&1 & )
      send "text/plain; charset=utf-8" "включаю исполнителя" ;;
    zvuk-play-id)
      ID=$(qval id)
      ( /data/local/bin/zvukd play-id "$ID" >>/data/local/tmp/zvukd.log 2>&1 & )
      send "text/plain; charset=utf-8" "включаю выбранный трек" ;;
    airplay-restart)
      for p in $(ps w | awk '/[s]hairport-sync/ {print $1}'); do kill "$p" 2>/dev/null; done
      sleep 1; /data/local/bin/airplay-daemon.sh >/dev/null 2>&1
      send "text/plain; charset=utf-8" "приёмник перезапущен" ;;
    airplay-off)
      for p in $(ps w | awk '/[s]hairport-sync/ {print $1}'); do kill "$p" 2>/dev/null; done
      send "text/plain; charset=utf-8" "приёмник остановлен, звук у Алисы" ;;
    avahi-restart)
      for p in $(ps w | awk '/[a]vahi-daemon/ {print $1}'); do kill "$p" 2>/dev/null; done
      send "text/plain; charset=utf-8" "avahi перезапущен — сторож поднимает его за пару секунд" ;;
    mediad-restart)
      for p in $(ps w | awk '/[m]aind --mediad/ {print $1}'); do kill "$p" 2>/dev/null; done
      sleep 2
      cd /data/quasar 2>/dev/null || cd /
      MALLOC_ARENA_MAX=2 CA_CERTIFICATES=/system/vendor/quasar/ca-certificates.crt \
        nohup /system/vendor/quasar/maind --mediad >>/data/quasar/mediad.log 2>&1 </dev/null &
      send "text/plain; charset=utf-8" "медиа-демон перезапущен" ;;
    reboot)
      send "text/plain; charset=utf-8" "перезагрузка через 2 секунды"
      (sleep 2; sync; reboot) >/dev/null 2>&1 &
      ;;
    *) send "text/plain; charset=utf-8" "неизвестное действие" ;;
  esac
}

do_log() {
  N=$(qval name)
  case "$N" in
    airplay) F=/data/local/tmp/shairport.log ;;
    owner)   F=/data/local/tmp/audio-owner.log ;;
    avahi)   F=/data/local/tmp/avahi-keep.log ;;
    boot)    F=/data/local/tmp/boot-airplay.log ;;
    updates) F=/data/local/tmp/watch-launchd.log ;;
    panel)   F=/data/local/tmp/panel.log ;;
    *) send "text/plain; charset=utf-8" "нет такого лога"; return ;;
  esac
  send "text/plain; charset=utf-8" "$(tail -40 "$F" 2>/dev/null)"
}

# Журнал загрузок и выключений. Пишется из /etc/init.d/S97station-root.
# Формат строки: boot|epoch|iso  либо  shutdown|epoch|iso
JOURNAL=/data/local/tmp/boots.log

events_json() {
  if [ ! -s "$JOURNAL" ]; then
    echo '{"events":[]}'
    return
  fi
  # clean=1 — перед этой загрузкой было штатное выключение;
  # clean=0 — выключения не было (сбой, watchdog, питание); clean=-1 — самая первая запись.
  awk -F'|' '
    { n++; k[n]=$1; t[n]=$2+0; i[n]=$3 }
    END {
      printf "{\"events\":[";
      for (j=1;j<=n;j++) {
        if (k[j]=="shutdown") clean=1;
        else if (j==1) clean=-1;
        else if (k[j-1]=="shutdown") clean=1;
        else clean=0;
        if (j>1) printf ",";
        printf "{\"kind\":\"%s\",\"time\":%d,\"iso\":\"%s\",\"clean\":%d}", k[j], t[j], i[j], clean;
      }
      printf "]}";
    }' "$JOURNAL"
}

do_syslog() {
  N=$(qval name)
  L=$(qval lines)
  case "$L" in ''|*[!0-9]*) L=80 ;; esac
  [ "$L" -gt 300 ] && L=300
  case "$N" in
    mediad)   F=/data/quasar/daemons_logs/mediad.log ;;
    airplay)  F=/data/local/tmp/shairport2.log ;;
    owner)    F=/data/local/tmp/audio-owner.log ;;
    zvukd)    F=/data/local/tmp/zvukd.log ;;
    alice)    F=/data/local/tmp/alice-voice.log ;;
    watchdog) F=/data/local/tmp/watchdog.log ;;
    panel)    F=/data/local/tmp/panel.log ;;
    boot)     F=/data/local/tmp/boot-airplay.log ;;
    *) send "text/plain; charset=utf-8" "нет такого лога"; return ;;
  esac
  if [ ! -f "$F" ]; then
    send "text/plain; charset=utf-8" "файла нет: $F"
    return
  fi
  send "text/plain; charset=utf-8" "$(tail -n "$L" "$F" 2>/dev/null)"
}

page() {
  printf 'HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n'
  cat <<'EOF'
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Станция Midi</title><style>
:root{color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;padding:24px;background:#111318;color:#e8eaed;font:16px/1.45 -apple-system,system-ui,sans-serif}
h1{font-size:20px;margin:0 0 4px}
.sub{color:#8b93a1;font-size:13px;margin-bottom:18px}
.card{background:#181b22;border:1px solid #262a33;border-radius:14px;padding:14px 16px;margin-bottom:14px}
.row{display:flex;justify-content:space-between;gap:12px;padding:7px 0;border-bottom:1px solid #22262e}
.row:last-child{border:0}
.ok{color:#5fd38d}.bad{color:#f2707b}.dim{color:#8b93a1}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:10px}
button{width:100%;padding:12px;border-radius:10px;border:1px solid #2d3340;background:#1f2430;color:#e8eaed;font-size:15px}
button:active{background:#2a3140}
button.warn{border-color:#553;color:#f0c674}
input[type=text]{width:100%;padding:10px;border-radius:10px;border:1px solid #2d3340;background:#12151b;color:#e8eaed}
input[type=range]{width:100%;accent-color:#79a8ff}
.small{font-size:13px;color:#8b93a1;margin-top:10px}
.hdr{display:flex;justify-content:space-between;align-items:baseline;margin-bottom:6px}
.cols{display:grid;grid-template-columns:1fr;gap:0}
@media (min-width:900px){.cols{grid-template-columns:repeat(3,minmax(0,1fr));gap:14px;align-items:start}}
.cols>.card{margin-bottom:14px}
pre{white-space:pre-wrap;margin:10px 0 0}
.tabs{display:flex;gap:8px;margin:0 0 16px}
.tab{width:auto;padding:9px 16px;border-radius:10px;border:1px solid #262a33;background:#181b22;color:#8b93a1;font-size:14px}
.tab.on{background:#232833;color:#e8eaed;border-color:#3a4152}
.ev{display:flex;justify-content:space-between;gap:10px;padding:6px 0;border-bottom:1px solid #22262e;font-size:14px}
.ev:last-child{border:0}
select{width:100%;padding:10px;border-radius:10px;border:1px solid #2d3340;background:#12151b;color:#e8eaed}
</style></head><body>
<h1>Яндекс Станция Midi</h1>
<div class="sub">Root · AirPlay · Обновления выключены</div>

<div class="tabs">
  <button class="tab on" data-view="main">Панель</button>
  <button class="tab" data-view="sys">Система</button>
</div>

<div id="view-main">
<div class="cols">
<div style="grid-column:1/-1" class="dim">Состояние и железо</div>

<div class="card">
  <div class="hdr"><span class="dim">Сейчас звучит</span><b id="now">…</b></div>
  <div class="row"><span>Приёмник AirPlay</span><b id="v-shairport" class="dim">…</b></div>
  <div class="row"><span>Avahi (объявление в сети)</span><b id="v-avahi" class="dim">…</b></div>
  <div class="row"><span>Демон Алисы</span><b id="v-mediad" class="dim">…</b></div>
  <div class="row"><span>Слушает порт</span><b id="v-port" class="dim">…</b></div>
  <div class="row"><span>Nqptp (AirPlay 2)</span><b id="v-nqptp" class="dim">…</b></div>
  <div class="row"><span>Обновлятор updatesd</span><b id="v-upd" class="dim">…</b></div>
  <div class="row"><span>Звук занят</span><b id="v-pcm" class="dim">…</b></div>
</div>

<div class="card">
  <div class="dim" style="margin-bottom:6px">Нагрузка</div>
  <div class="row"><span>Процессор</span><b id="v-cpu" class="dim">…</b></div>
  <div class="row"><span>Load average (1 / 5 / 15)</span><b id="v-load" class="dim">…</b></div>
  <div class="row"><span>Процессов</span><b id="v-procs" class="dim">…</b></div>
  <div class="row"><span>Память</span><b id="v-ram" class="dim">…</b></div>
  <div class="row"><span>Температура</span><b id="v-temp" class="dim">…</b></div>
  <div class="row"><span>Аптайм</span><b id="v-uptime" class="dim">…</b></div>
</div>

<div class="card">
  <div class="dim" style="margin-bottom:6px">Железо и диски</div>
  <div class="row"><span>Модель</span><b id="v-model" class="dim">…</b></div>
  <div class="row"><span>Ядра / ядро</span><b id="v-hw" class="dim">…</b></div>
  <div class="row"><span>rootfs (/)</span><b id="v-root" class="dim">…</b></div>
  <div class="row"><span>/data (bkupgrade)</span><b id="v-data" class="dim">…</b></div>
  <div class="row"><span>/tee</span><b id="v-tee" class="dim">…</b></div>
  <div class="row"><span>Сеть</span><b id="v-net" class="dim">…</b></div>
  <div class="row"><span>Прошивка</span><b id="v-fw" class="dim">…</b></div>
</div>

</div>

<div class="cols">
<div class="card">
  <div class="hdr"><span class="dim">AirPlay</span><b id="v-airplay" class="dim">…</b></div>
  <div class="grid" style="margin-top:8px">
    <button data-a="airplay-prev">Назад</button>
    <button data-a="airplay-toggle">Пауза / играть</button>
    <button data-a="airplay-next">Дальше</button>
  </div>
  <div class="small">Управление тем, что играет с Mac или iPhone: команда уходит источнику</div>
</div>

<div style="grid-column:1/-1;margin-bottom:6px" class="dim">Плеер</div>

<div class="card">
  <div class="hdr"><span class="dim">Поиск в Звуке</span><b id="s-count" class="dim"></b></div>
  <input type="text" id="s-q" placeholder="исполнитель или трек">
  <div class="grid" style="margin-top:8px">
    <button onclick="doSearch()">Найти</button>
    <button onclick="loadQueue()">Обновить очередь</button>
  </div>
  <div class="grid" style="grid-template-columns:repeat(5,minmax(0,1fr));gap:6px;margin-top:8px">
    <button class="tab" data-m="all" onclick="setMode('all')">Всё</button>
    <button class="tab" data-m="tracks" onclick="setMode('tracks')">Треки</button>
    <button class="tab" data-m="albums" onclick="setMode('albums')">Альбомы</button>
    <button class="tab" data-m="artists" onclick="setMode('artists')">Исполнители</button>
    <button class="tab" data-m="playlists" onclick="setMode('playlists')">Плейлисты</button>
  </div>
  <div class="grid" style="grid-template-columns:1fr;margin-top:6px">
    <button id="shufbtn" onclick="toggleShuffle()">Плейлисты вперемешку: выкл</button>
  </div>
  <div id="s-list" style="margin-top:10px"></div>
  <div class="small">Выбранный трек играет, остальные найденные встают в очередь</div>
</div>

<div class="card">
  <div class="hdr"><span class="dim">Мой плеер · Звук</span><b id="z-state" class="dim">…</b></div>
  <div style="display:flex;gap:12px;align-items:flex-start;margin-top:4px">
    <img id="z-cover" alt="" style="width:88px;height:88px;border-radius:10px;object-fit:cover;background:#1f2430;flex:0 0 auto">
    <div style="flex:1;min-width:0">
      <div class="row" style="border:0"><span>Сейчас играет</span><b id="z-title">—</b></div>
      <div class="row" style="border:0"><span>Очередь</span><b id="z-queue" class="dim">—</b></div>
      <div class="row" style="border:0"><span>Альбом</span><b id="z-album" class="dim">—</b></div>
      <div style="margin:8px 0 2px;height:6px;border-radius:3px;background:#232833;overflow:hidden">
        <div id="z-bar" style="height:100%;width:0;background:#79a8ff;transition:width .9s linear"></div>
      </div>
      <div class="row" style="border:0;padding-top:0"><span id="z-time" class="dim">0:00</span><b id="z-time-total" class="dim">0:00</b></div>
    </div>
  </div>
  <div class="grid" style="margin-top:8px">
    <button data-a="zvuk-flow">Включить Мой поток</button>
    <button data-a="zvuk-next">Следующий трек</button>
    <button data-a="zvuk-pause">Пауза</button>
    <button data-a="zvuk-resume">Продолжить</button>
    <button data-a="zvuk-stop">Остановить</button>
    <button data-a="zvuk-shuffle">Перемешать</button>
    <button data-a="zvuk-resume-last" id="z-resume" style="display:none">Продолжить последнее</button>
  </div>
  <div class="small">Музыка из Звука по твоему вкусу, без остановки</div>
</div>

<div class="card">
  <div class="hdr"><span class="dim">Очередь</span><b id="q-count" class="dim"></b></div>
  <div id="q-list"></div>
</div>
</div>

</div><!-- /view-main -->

<div id="view-sys" style="display:none">
<div class="cols">

<div class="card">
  <div class="hdr"><span class="dim">События</span><b id="ev-up" class="dim"></b></div>
  <div id="ev-list"><div class="dim">…</div></div>
  <div class="small">Загрузки и выключения. «Нештатная» — если перед загрузкой не было штатного выключения (сбой, watchdog, щёлкнули питанием).</div>
</div>

<div class="card">
  <div class="hdr"><span class="dim">Сторож демонов</span><b class="dim">watchdog.log</b></div>
  <pre id="sys-watch" class="small">…</pre>
  <div class="grid" style="margin-top:8px"><button onclick="loadSys()">Обновить</button><button data-view="main">Вернуться</button></div>
</div>

<div class="card">
  <div class="hdr"><span class="dim">Логи</span><b class="dim">хвост файла</b></div>
  <select id="log-name">
    <option value="mediad">Алиса (mediad)</option>
    <option value="airplay">Приёмник AirPlay</option>
    <option value="owner">Распорядитель звука</option>
    <option value="zvukd">Плеер Звук</option>
    <option value="alice">Голосовые команды</option>
    <option value="watchdog">Сторож</option>
    <option value="boot">Загрузка AirPlay</option>
    <option value="panel">Панель</option>
  </select>
  <div class="grid" style="margin-top:8px"><button onclick="loadLog()">Показать</button></div>
  <pre id="sys-log" class="small">…</pre>
</div>

</div>
<div class="card">
  <div class="grid">
    <button data-a="airplay-restart">Перезапустить AirPlay</button>
    <button data-a="airplay-off">Выключить AirPlay</button>
    <button data-a="avahi-restart">Перезапустить avahi</button>
    <button data-a="mediad-restart">Поднять Алису</button>
    <button data-a="reboot" class="warn">Перезагрузить</button>
  </div>
  <div class="small">Только домашняя сеть</div>
</div>

<div class="card">
  <div class="dim">Логи · быстрый доступ</div>
  <div class="grid" style="margin-top:8px">
    <button data-log="airplay">Приёмник</button>
    <button data-log="owner">Распорядитель</button>
    <button data-log="avahi">Avahi</button>
    <button data-log="boot">Загрузка</button>
    <button data-log="updates">Обновления</button>
    <button data-log="panel">Панель</button>
  </div>
  <pre id="out" class="small"></pre>
</div>
</div><!-- /view-sys -->

<script>
var out=document.getElementById('out');

function show(t){out.textContent=t}
function cls(el,good){el.className=good?'ok':'bad'}

function paint(s){
  document.getElementById('now').textContent=s.playing?'AirPlay играет':'Алиса';
  var m={shairport:'v-shairport',avahi:'v-avahi',mediad:'v-mediad'};
  for(var k in m){
    var el=document.getElementById(m[k]);
    el.textContent=s[k]>0?'Работает':'Нет';
    cls(el,s[k]>0);
  }
  var nq=document.getElementById('v-nqptp');
  nq.textContent=s.nqptp>0?'Работает':'Нет';cls(nq,s.nqptp>0);
  var pp=document.getElementById('v-port');
  pp.textContent=s.listen||'—';pp.className='dim';
  var ap=document.getElementById('v-airplay');
  if(ap){ap.textContent=s.airplay?'Активна':'Нет';cls(ap,!!s.airplay);}
  var md=document.getElementById('v-mediad');
  if(s.playing&&s.mediad===0){md.textContent='Уступлен AirPlay';md.className='dim'}
  var u=document.getElementById('v-upd');
  u.textContent=s.updatesd>0?'Включён':'Выключен';cls(u,s.updatesd===0);
  var p=document.getElementById('v-pcm');p.textContent=s.pcm||'—';p.className='dim';

  var zn={play:'Играет',pause:'Пауза',idle:'Молчит',off:'Плеер не отвечает'};
  var zs=document.getElementById('z-state');
  zs.textContent=zn[s.zvuk]||'—';
  zs.className=(s.zvuk==='play')?'ok':((s.zvuk==='off')?'bad':'dim');
  document.getElementById('z-title').textContent=s.zvuk_title||'—';
  var cov=document.getElementById('z-cover');
  if(s.zvuk_cover){cov.src=s.zvuk_cover;cov.style.display='block'}else{cov.removeAttribute('src');cov.style.display='none'}
  document.getElementById('z-queue').textContent=(s.zvuk_total>0)?((s.zvuk_idx+1)+' из '+s.zvuk_total):'пусто';
  var alb=document.getElementById('z-album');
  if(s.zvuk_album){alb.textContent=s.zvuk_album;alb.className='';alb.style.cursor='pointer';alb.onclick=function(){albumTracks(s.zvuk_album_id,s.zvuk_album)}}
  else{alb.textContent='—';alb.className='dim';alb.style.cursor='default';alb.onclick=null}
  var pos=s.zvuk_pos||0,dur=s.zvuk_dur||0;
  document.getElementById('z-bar').style.width=(dur>0?Math.min(100,Math.round(pos*100/dur)):0)+'%';
  document.getElementById('z-time').textContent=fmt(pos);
  document.getElementById('z-time-total').textContent=dur?fmt(dur):'0:00';
  document.getElementById('z-resume').style.display=s.zvuk_saved?'block':'none';
  document.getElementById('v-net').textContent=(s.ip||'—')+' · '+(s.ssid||'—')+' · '+(s.band||'—');
  document.getElementById('v-fw').textContent=s.fw||'—';
  document.getElementById('v-model').textContent=s.model||'—';
  document.getElementById('v-hw').textContent=(s.cores||0)+' шт · ядро '+(s.kernel||'—');

  var cpu=document.getElementById('v-cpu');
  cpu.textContent=(s.cpu||0)+'%';
  cpu.className=(s.cpu>85)?'bad':((s.cpu>50)?'dim':'ok');

  document.getElementById('v-load').textContent=[s.load1,s.load5,s.load15].join(' / ');
  document.getElementById('v-procs').textContent=s.procs||'—';

  var ram=document.getElementById('v-ram');
  ram.textContent=(s.mem_used||0)+' / '+(s.mem_total||0)+' МБ ('+(s.mem_pct||0)+'%)';
  ram.className=(s.mem_pct>90)?'bad':((s.mem_pct>70)?'dim':'ok');

  document.getElementById('v-root').textContent=s.root||'—';
  document.getElementById('v-data').textContent=s.data||'—';
  document.getElementById('v-tee').textContent=s.tee||'—';
  document.getElementById('v-temp').textContent=(s.temp?s.temp+' °C':'—');
  document.getElementById('v-uptime').textContent=(s.uptime||0)+' мин';
  document.title=(s.playing?'▶ ':'')+'Станция Midi';
}

function fmt(sec){var m=Math.floor((sec||0)/60),x=(sec||0)%60;return m+':'+(x<10?'0':'')+x}

function mkRow(t,mark,action,sub,extra){
  var d=document.createElement('div');
  d.style.cssText='display:flex;align-items:center;gap:10px;padding:7px 0;border-top:1px solid #232833';
  var img=document.createElement('img');
  img.style.cssText='width:44px;height:44px;border-radius:6px;object-fit:cover;background:#1f2430;flex:0 0 auto';
  if(t.cover && t.cover.indexOf('/static/')<0)img.src=t.cover;
  var box=document.createElement('div');box.style.cssText='flex:1;min-width:0';
  var tt=document.createElement('div');tt.style.cssText='font-size:14px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap';
  tt.textContent=(mark?'▶ ':'')+(t.title||'');
  var st=document.createElement('div');st.className='small';st.style.marginTop='2px';
  st.textContent=sub||((t.artists||'')+(t.duration?' · '+fmt(t.duration):''));
  box.appendChild(tt);box.appendChild(st);
  var b=document.createElement('button');b.textContent='Играть';
  b.style.cssText='width:auto;padding:8px 12px;font-size:13px;flex:0 0 auto';
  b.onclick=function(){
    b.textContent='…';
    fetch('/action?do='+(action||'zvuk-play-id')+'&id='+encodeURIComponent(t.id))
      .then(function(r){return r.text()}).then(function(x){
        show(x);b.textContent='Играть';
        setTimeout(function(){refresh();loadQueue()},2500);
      }).catch(function(){b.textContent='Играть'});
  };
  d.appendChild(img);d.appendChild(box);
  if(extra&&extra.label){
    var eb=document.createElement('button');eb.textContent=extra.label;
    eb.style.cssText='width:auto;padding:8px 10px;font-size:13px;flex:0 0 auto';
    eb.onclick=extra.run;
    d.appendChild(eb);
  }
  d.appendChild(b);
  return d;
}

function b64(str){return btoa(unescape(encodeURIComponent(str)))}

var lastFound=null, mode='all', shufflePlaylists=false;

function toggleShuffle(){
  shufflePlaylists=!shufflePlaylists;
  var b=document.getElementById('shufbtn');
  b.textContent='Плейлисты вперемешку: '+(shufflePlaylists?'вкл':'выкл');
  b.style.borderColor=shufflePlaylists?'#79a8ff':'#2d3340';
  b.style.background=shufflePlaylists?'#253046':'#1f2430';
  if(lastFound)renderResults(lastFound);
}

function setMode(m){
  mode=m;
  document.querySelectorAll('.tab').forEach(function(b){
    var on=(b.dataset.m===m);
    b.style.borderColor=on?'#79a8ff':'#2d3340';
    b.style.background=on?'#253046':'#1f2430';
    b.style.color=on?'#fff':'#e8eaed';
  });
  if(lastFound)renderResults(lastFound);
}

function renderResults(d){
  var list=document.getElementById('s-list');
  list.innerHTML='';
  var groups=[
    ['Треки',d&&d.tracks,'zvuk-play-id',function(t){return t.artists||''}],
    ['Альбомы',d&&d.albums,'zvuk-play-album',function(t){return (t.artists||'')+(t.year?' · '+t.year:'')+' · '+(t.kind==='single'?'сингл':(t.kind==='ep'?'EP':(t.kind==='compilation'?'сборник':'альбом')))}],
    ['Исполнители',d&&d.artists,'zvuk-play-artist',function(t){return 'популярные треки'}],
    ['Плейлисты',d&&d.playlists,'zvuk-play-playlist',function(t){return (t.tracks?Math.max(1,Math.round(t.tracks/60))+' мин':'плейлист')}],
    ['Альбомы исполнителя',null,null,null]
  ];
  var want={all:['Треки','Альбомы','Исполнители','Плейлисты'],tracks:['Треки'],albums:['Альбомы'],artists:['Исполнители'],playlists:['Плейлисты']}[mode];
  groups=groups.filter(function(g){return !want||want.indexOf(g[0])>=0});
  var total=0;
  groups.forEach(function(g){
    var items=g[1]||[];total+=items.length;
    if(!items.length)return;
    var h=document.createElement('div');
    h.className='dim';h.style.cssText='margin:12px 0 2px;font-size:13px';
    h.textContent=g[0]+' · '+items.length;
    list.appendChild(h);
    items.forEach(function(t){
      var extra=(g[0]==='Исполнители')?{label:'Альбомы',run:function(){artistAlbums(t)}}:null;
      var action=g[2];
      if(g[0]==='Плейлисты'&&shufflePlaylists)action='zvuk-play-playlist-shuffled';
      list.appendChild(mkRow(t,false,action,g[3](t),extra));
    });
  });
  document.getElementById('s-count').textContent=total+' шт';
  if(!total)list.textContent=(mode==='all')?'ничего не нашлось':'в этой группе ничего нет';
}

function doSearch(){
  var q=document.getElementById('s-q').value.trim();
  if(!q)return;
  document.getElementById('s-list').textContent='ищу…';
  document.getElementById('s-count').textContent='';
  fetch('/api/search?q64='+encodeURIComponent(b64(q)),{cache:'no-store'})
    .then(function(r){return r.json()}).then(function(d){lastFound=d;renderResults(d)})
    .catch(function(e){document.getElementById('s-list').textContent='ошибка: '+e});
}

function albumTracks(id,title){
  if(!id)return;
  var list=document.getElementById('s-list');
  list.textContent='загружаю альбом…';
  document.getElementById('s-count').textContent='';
  fetch('/api/album-tracks?id='+encodeURIComponent(id),{cache:'no-store'})
    .then(function(r){return r.json()}).then(function(d){
      var items=(d&&d.items)||[];
      list.innerHTML='';
      var back=document.createElement('button');
      back.textContent='← назад к поиску';
      back.style.cssText='width:auto;padding:6px 10px;font-size:13px;margin-bottom:8px';
      back.onclick=function(){if(lastFound)renderResults(lastFound)};
      list.appendChild(back);
      var h=document.createElement('div');
      h.className='dim';h.style.cssText='margin:6px 0 2px;font-size:13px';
      h.textContent=(title||'альбом')+' · '+items.length+' трек(ов)';
      list.appendChild(h);
      document.getElementById('s-count').textContent=items.length+' шт';
      var playAll=document.createElement('button');
      playAll.textContent='Играть весь альбом';
      playAll.style.cssText='width:auto;padding:6px 10px;font-size:13px;margin:6px 0';
      playAll.onclick=function(){fetch('/action?do=zvuk-play-album&id='+encodeURIComponent(id)).then(function(){setTimeout(function(){refresh();loadQueue()},2500)})};
      list.appendChild(playAll);
      items.forEach(function(t){list.appendChild(mkRow(t,false,'zvuk-play-id',t.artists||''))});
    }).catch(function(e){list.textContent='ошибка: '+e});
}

function artistAlbums(a){
  var list=document.getElementById('s-list');
  list.textContent='загружаю альбомы…';
  document.getElementById('s-count').textContent='';
  fetch('/api/artist-albums?id='+encodeURIComponent(a.id),{cache:'no-store'})
    .then(function(r){return r.json()}).then(function(d){
      var items=(d&&d.items)||[];
      list.innerHTML='';
      var back=document.createElement('button');
      back.textContent='← назад к поиску';
      back.style.cssText='width:auto;padding:6px 10px;font-size:13px;margin-bottom:8px';
      back.onclick=function(){if(lastFound)renderResults(lastFound)};
      list.appendChild(back);
      var h=document.createElement('div');
      h.className='dim';h.style.cssText='margin:6px 0 2px;font-size:13px';
      h.textContent='Альбомы · '+(a.title||'')+' · '+items.length;
      list.appendChild(h);
      document.getElementById('s-count').textContent=items.length+' шт';
      items.forEach(function(t){
        list.appendChild(mkRow(t,false,'zvuk-play-album',
          (t.year?t.year+' · ':'')+(t.kind==='single'?'сингл':(t.kind==='ep'?'EP':(t.kind==='compilation'?'сборник':'альбом')))));
      });
    }).catch(function(e){list.textContent='ошибка: '+e});
}

function loadQueue(){
  var list=document.getElementById('q-list');
  fetch('/api/queue',{cache:'no-store'}).then(function(r){return r.json()}).then(function(d){
    list.innerHTML='';
    var items=(d&&d.items)||[];
    document.getElementById('q-count').textContent=items.length?((d.index+1)+' из '+items.length):'';
    if(!items.length){list.textContent='пусто — включи поток или выбери трек из поиска';return}
    items.forEach(function(t,i){list.appendChild(mkRow(t,i===d.index))});
  }).catch(function(){});
}

function refresh(){
  fetch('/api/status',{cache:'no-store'}).then(function(r){return r.json()}).then(paint).catch(function(){});
}
refresh();loadQueue();setInterval(refresh,5000);setInterval(loadQueue,15000);
var sq=document.getElementById('s-q');if(sq&&window.innerWidth>700)sq.focus();

document.querySelectorAll('[data-a]').forEach(function(b){b.onclick=function(){
  if(b.dataset.a==='reboot'&&!confirm('Перезагрузить колонку?'))return;
  show('…');
  fetch('/action?do='+b.dataset.a)
    .then(function(r){return r.text()}).then(function(t){show(t);refresh();loadQueue()})
    .catch(function(e){show('ошибка: '+e)});
}});

document.querySelectorAll('[data-log]').forEach(function(b){b.onclick=function(){
  show('…');
  fetch('/log?name='+b.dataset.log).then(function(r){return r.text()}).then(show)
    .catch(function(e){show('ошибка: '+e)});
}});

// --- вкладки: панель / система ---
function switchView(v){
  document.getElementById('view-main').style.display = (v==='main')?'':'none';
  document.getElementById('view-sys').style.display  = (v==='sys')?'':'none';
  document.querySelectorAll('.tab').forEach(function(t){t.classList.toggle('on', t.dataset.view===v)});
  if(v==='sys') loadSys();
}
document.querySelectorAll('[data-view]').forEach(function(b){b.onclick=function(){switchView(b.dataset.view)}});

function fmtTs(t){
  var d=new Date(t*1000);
  if(isNaN(d.getTime())) return '—';
  var p=function(n){return (n<10?'0':'')+n};
  return p(d.getDate())+'.'+p(d.getMonth()+1)+' '+p(d.getHours())+':'+p(d.getMinutes());
}
function uptimeStr(sec){
  if(sec<=0) return '';
  var h=Math.floor(sec/3600), m=Math.round((sec%3600)/60);
  return h>0 ? (h+' ч '+m+' мин') : (m+' мин');
}
function loadEvents(){
  var box=document.getElementById('ev-list');
  fetch('/api/events',{cache:'no-store'}).then(function(r){return r.json()}).then(function(d){
    var ev=(d.events||[]).slice(-30).reverse();
    if(!ev.length){box.innerHTML='<div class="dim">пока нет записей</div>';return}
    var out='';
    for(var i=0;i<ev.length;i++){
      var e=ev[i], prev=ev[i+1];
      var title = e.kind==='shutdown' ? 'Выключение' : 'Загрузка';
      var badge = '';
      if(e.kind==='boot' && e.clean===0) badge=' <span class="bad">нештатная</span>';
      var extra = '';
      if(prev && prev.kind==='boot' && e.kind==='shutdown'){
        var d2=e.time-prev.time; if(d2>0) extra=' <span class="dim">· работала '+uptimeStr(d2)+'</span>';
      }
      out+='<div class="ev"><span>'+title+badge+extra+'</span><span class="dim">'+fmtTs(e.time)+'</span></div>';
    }
    box.innerHTML=out;
  }).catch(function(){box.innerHTML='<div class="bad">не удалось получить события</div>'});
}
function loadSys(){
  loadEvents();
  fetch('/api/logs?name=watchdog&lines=20',{cache:'no-store'}).then(function(r){return r.text()})
    .then(function(t){document.getElementById('sys-watch').textContent=t||'(пусто)'})
    .catch(function(){document.getElementById('sys-watch').textContent='ошибка'});
}
function loadLog(){
  var n=document.getElementById('log-name').value;
  var pre=document.getElementById('sys-log');
  pre.textContent='…';
  fetch('/api/logs?name='+encodeURIComponent(n)+'&lines=120',{cache:'no-store'})
    .then(function(r){return r.text()}).then(function(t){pre.textContent=t||'(пусто)'})
    .catch(function(e){pre.textContent='ошибка: '+e});
}
</script></body></html>
EOF
}

case "$URLPATH" in
  /api/status)
      CACHE=/tmp/panel-status.json
      NOW=$(date +%s)
      if [ -f "$CACHE" ]; then
        SEEN=$(cut -d' ' -f1 "$CACHE" 2>/dev/null)
        case "$SEEN" in ''|*[!0-9]*) SEEN=0 ;; esac
        BODY=$(cut -d' ' -f2- "$CACHE" 2>/dev/null)
        AGE=$((NOW - SEEN))
        if [ -n "$BODY" ] && [ "$AGE" -ge 0 ] && [ "$AGE" -lt 3 ]; then
          send "application/json" "$BODY"
          exit 0
        fi
      fi
      JSON=$(status_json)
      printf '%s %s' "$NOW" "$JSON" > "$CACHE" 2>/dev/null
      send "application/json" "$JSON" ;;
  /api/search)
      Q64=$(qval q64)
      Q64=$(printf '%s' "$Q64" | sed 's/%2B/+/g; s/%2b/+/g; s/%2F/\//g; s/%2f/\//g; s/%3D/=/g; s/%3d/=/g')
      Q=$(printf '%s' "$Q64" | busybox base64 -d 2>/dev/null)
      send "application/json" "$(/data/local/bin/zvukd search "$Q" 2>/dev/null || echo '{"tracks":[],"albums":[],"artists":[]}')" ;;
  /api/queue)  send "application/json" "$(/data/local/bin/zvukd queue 2>/dev/null || echo '{"items":[]}')" ;;
  /api/album-tracks) send "application/json" "$(/data/local/bin/zvukd album-tracks "$(qval id)" 2>/dev/null || echo '{"items":[]}')" ;;
  /api/artist-albums)
      send "application/json" "$(/data/local/bin/zvukd artist-albums "$(qval id)" 2>/dev/null || echo '{"items":[]}')" ;;
  /api/events) send "application/json" "$(events_json)" ;;
  /api/logs)   do_syslog ;;
  /action)     do_action ;;
  /log)        do_log ;;
  /)           page ;;
  *)           send "text/plain; charset=utf-8" "не найдено" ;;
esac
