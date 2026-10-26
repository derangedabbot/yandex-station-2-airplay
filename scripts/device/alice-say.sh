#!/bin/sh
# Сказать Алисе текстом — отладочный CLI движка (maind --cli):
#   q <Enter>  текст <Enter>  x <Enter>
# Это то же, что произнести фразу: она понимает команду и отвечает как обычно.
# Осторожно: команда может занять динамик (например, «включи музыку»), поэтому
# запуск один за раз, кулдаун и запись в лог.
#   alice-say.sh "громкость 3"
Q=/system/vendor/quasar
LOCK=/tmp/alice-say.pid
LOG=/data/local/tmp/alice-say.log
OUT=/tmp/alice-say.out

[ -n "$1" ] || { echo "нужен текст команды"; exit 2; }

# один запуск за раз
if [ -f "$LOCK" ]; then
  P=$(cat "$LOCK" 2>/dev/null)
  if [ -n "$P" ] && [ -d "/proc/$P" ]; then
    echo "уже отправляю, подожди"
    exit 3
  fi
  rm -f "$LOCK"
fi
echo $$ > "$LOCK"

echo "$(date '+%Y-%m-%d %H:%M:%S') → $1" >> "$LOG"

(
  sleep 2
  printf 'q\n'; sleep 0.5
  printf '%s\n' "$1"; sleep 3
  printf 'x\n'; sleep 1
) | LD_LIBRARY_PATH=$Q/libs $Q/maind --cli > "$OUT" 2>&1 &
p=$!

i=0
while kill -0 "$p" 2>/dev/null && [ "$i" -lt 12 ]; do
  sleep 1
  i=$((i+1))
done
kill "$p" 2>/dev/null
rm -f "$LOCK"

# в лог — короткая выжимка ответа движка
grep -a -i 'error\|fail' "$OUT" 2>/dev/null | head -3 >> "$LOG"
echo "отправлено: $1"
