#!/bin/sh
# Автозапуск на Яндекс.Станции: отладка по сети, SSH, сторож обновлений,
# AirPlay-приёмник (доступен всегда) и распорядитель звука.
case "$1" in
  start)
    /data/local/bin/boot-journal.sh boot 2>/dev/null
    /data/local/bin/telemetry-hosts.sh 2>/dev/null
    mount -o remount,rw / 2>/dev/null
    mkdir -p /data/quasar
    touch /data/quasar/activate_adb_quasmodrom /data/quasar/activate_network_adb 2>/dev/null

    T=/data/local/opt/airplay
    L=/data/local/opt/tools/lib/ld-musl-aarch64.so.1

    # SSH
    if [ -x "$T/bin/dropbear" ] && [ -f /data/local/etc/dropbear/host_ed25519 ]; then
      LD_LIBRARY_PATH="$T/lib:/data/local/opt/tools/lib" \
        "$L" "$T/bin/dropbear" -r /data/local/etc/dropbear/host_ed25519 \
        -p 2222 -P /run/dropbear.pid >/dev/null 2>&1
    fi

    # сторож обновлений
    [ -x /data/local/bin/watch-launchd.sh ] && \
      start-stop-daemon -S -b -m -p /run/watch-launchd.pid -x /bin/sh -- /data/local/bin/watch-launchd.sh

    # AirPlay: поднимаем после того, как появятся /data и звуковая карта
    [ -x /data/local/bin/boot-airplay.sh ] && \
      start-stop-daemon -S -b -m -p /run/boot-airplay.pid -x /bin/sh -- /data/local/bin/boot-airplay.sh

    # одна копия: живой pid в pid-файле или устаревший (иначе start-stop-daemon
    # отказывается стартовать, потому что pid указывает на любой живой /bin/sh)
    av_pid=$(cat /run/alice-voice.pid 2>/dev/null)
    case "$(tr '\0' ' ' < /proc/${av_pid:-0}/cmdline 2>/dev/null)" in
      *alice-voice.sh*) ;;
      *)
        rm -f /run/alice-voice.pid
        [ -x /data/local/bin/alice-voice.sh ] && \
          start-stop-daemon -S -b -m -p /run/alice-voice.pid -x /bin/sh -- /data/local/bin/alice-voice.sh
        ;;
    esac

    # проигрыватель Звука
    [ -x /data/local/bin/zvukd-daemon.sh ] && \
      start-stop-daemon -S -b -m -p /run/zvukd.pid -x /bin/sh -- /data/local/bin/zvukd-daemon.sh
    # веб-панель (только домашняя сеть)
    [ -x /data/local/bin/panel-server.sh ] && \
      start-stop-daemon -S -b -m -p /run/panel.pid -x /bin/sh -- /data/local/bin/panel-server.sh
    # сторож: поднимает упавшие демоны (ничего не убивает)
    [ -x /data/local/bin/watchdog.sh ] && \
      start-stop-daemon -S -b -m -p /run/watchdog.pid -x /bin/sh -- /data/local/bin/watchdog.sh
    ;;
  stop)
    /data/local/bin/boot-journal.sh shutdown 2>/dev/null
    pkill -f watch-launchd.sh 2>/dev/null
    pkill -f audio-owner.sh 2>/dev/null
    pkill -f airplay2-daemon.sh 2>/dev/null
    pkill -f avahi-keeper.sh 2>/dev/null
    pkill -f panel-server.sh 2>/dev/null
    pkill -f watchdog.sh 2>/dev/null
    pkill -f "/data/local/opt/zvuk/bin/zvukd" 2>/dev/null
    pkill -f '[n]qptp' 2>/dev/null
    pkill -f 'shairport-sync' 2>/dev/null
    pkill -f "dropbear -r" 2>/dev/null
    ;;
esac
exit 0