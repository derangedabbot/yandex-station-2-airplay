#!/bin/sh
# Веб-панель колонки: socat слушает порт и на каждое соединение запускает обработчик.
# Доступ только из домашней сети. При падении поднимается заново.
PORT=${PANEL_PORT:-8081}
# Подсеть не зашиваем в код: берём адрес с самой колонки, иначе домашняя топология
# уезжает в публичный репозиторий.
# socat понимает «адрес/маска», поэтому достаточно своего IP с префиксом.
LAN=${PANEL_LAN:-$(ip -4 -o addr show 2>/dev/null | awk '$2 != "lo" && $4 ~ /\// {print $4; exit}')}
[ -n "$LAN" ] || LAN=127.0.0.1/32
LOG=/data/local/tmp/panel.log

# Токена нет намеренно: панель слушает только домашнюю подсеть (range=), этого достаточно.

echo "=== $(date): панель на $PORT для $LAN ===" >> "$LOG"
while :; do
  /data/local/bin/socat -t 10 TCP-LISTEN:"$PORT",fork,reuseaddr,range="$LAN" \
    EXEC:"/bin/sh /data/local/bin/panel-handler.sh"
  echo "=== $(date): socat завершился, перезапуск через 3 с ===" >> "$LOG"
  sleep 3
done
