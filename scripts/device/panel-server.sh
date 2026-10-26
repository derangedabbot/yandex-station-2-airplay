#!/bin/sh
# Веб-панель колонки: socat слушает порт и на каждое соединение запускает обработчик.
# Доступ только из домашней сети. При падении поднимается заново.
PORT=${PANEL_PORT:-8081}
LAN=${PANEL_LAN:-192.168.100.0/24}
LOG=/data/local/tmp/panel.log

# Токена нет намеренно: панель слушает только домашнюю подсеть (range=), этого достаточно.

echo "=== $(date): панель на $PORT для $LAN ===" >> "$LOG"
while :; do
  /data/local/bin/socat -t 10 TCP-LISTEN:"$PORT",fork,reuseaddr,range="$LAN" \
    EXEC:"/bin/sh /data/local/bin/panel-handler.sh"
  echo "=== $(date): socat завершился, перезапуск через 3 с ===" >> "$LOG"
  sleep 3
done
