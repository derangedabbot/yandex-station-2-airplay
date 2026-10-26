#!/bin/sh
# Слушатель локального IPC Алисы (127.0.0.1:9875).
# Читает кадры: 4 байта длины (LE) + protobuf. Внутри — финальный текст распознавания.
# Ищет фразы из /data/local/etc/voice-triggers.txt (по одной в строке, UTF-8)
# и отдаёт их в hook(), где фраза превращается в команду плеера «Звук».
LOG=/data/local/tmp/alice-voice.log
PAT=/data/local/etc/voice-triggers.txt
FRAME=/tmp/alice-frame.bin
STATE=/tmp/alice-voice.last
COOLDOWN=2
ZVUKD=/data/local/bin/zvukd
ZVUKLOG=/data/local/tmp/zvukd.log

# Одна копия: при перезапусках остаются жить подпроцессы прежних копий, и тогда
# одна фраза срабатывает столько раз, сколько копий висит (проверено: 5 копий → 5 переключений).
for d in /proc/[0-9]*; do
  pid=${d#/proc/}
  [ "$pid" = "$$" ] && continue
  [ "$pid" = "$PPID" ] && continue
  case "$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null || true)" in
    *"/data/local/bin/alice-voice.sh"*|*socat*9875*) kill "$pid" 2>/dev/null ;;
  esac
done

hook() { # $1 — сработавшая фраза
  # В кадре лежит и сам текст распознавания — пишем его в лог, иначе непонятно,
  # на какую именно фразу сработал шаблон (было: «стоп» на чужой фразе).
  TXT=$(/usr/bin/strings -a "$FRAME" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-90)
  echo "$(date): СРАБОТАЛО «$1»${TXT:+ · в кадре: $TXT}" >> "$LOG"
  # Если идёт AirPlay — команду адресуем источнику (Mac/iPhone), а не нашему плееру.
  AP=/data/local/bin/airplay-ctl.sh
  if [ -x "$AP" ] && "$AP" status 2>/dev/null | head -1 | grep -q 'активен'; then
    case "$1" in
      *ыключи*|*стоп*)     APCMD=stop ;;
      *ауза*)              APCMD=pause ;;
      *родолж*)            APCMD=play ;;
      *азад*|*редыдущ*)    APCMD=prev ;;
      *ледующий*|*альше*)  APCMD=next ;;
      *)                   APCMD= ;;
    esac
    if [ -n "$APCMD" ]; then
      echo "$(date): AirPlay получает «$APCMD»" >> "$LOG"
      ( "$AP" "$APCMD" >> "$LOG" 2>&1 & )
      return 0
    fi
  fi
  [ -x "$ZVUKD" ] || return 0
  case "$1" in
    *ыключи*|*стоп*)      CMD=stop ;;
    *ауза*)               CMD=pause ;;
    *родолж*)             CMD=resume ;;
    *ледующий*|*альше*)   CMD=next ;;
    *)                    CMD=flow ;;
  esac
  # в фоне: запуск потока качает трек несколько секунд, слушатель ждать не должен.
  # «продолжи»/«дальше» ставим СРАЗУ (иначе её волна успевает заиграть на секунду),
  # а через 3 с переигрываем свой трек с той же секунды — её облако отвечает позже
  # и включает свой поток поверх нашего (проверено голосом).
  case "$CMD" in
    resume|next)
      # Её облако отвечает позже нас и на «продолжи»/«дальше» включает свой поток.
      # Ждём 3 с (её ответ уже прошёл) и ставим наш трек последним — он и выигрывает.
      # Автоматические «возвраты» после этого не нужны и только вредят.
      # 1.5 с: её поток стартует через ~0.3 с после команды (замер по mediad.log),
      # значит мы гарантированно позже, но ждём меньше. `sleep 1.5` на busybox
      # обрезается до целого, поэтому дробная пауза — через usleep.
      ( usleep 1500000; "$ZVUKD" "$CMD" >> "$ZVUKLOG" 2>&1 ) &
      ;;
    *)
      ( "$ZVUKD" "$CMD" >> "$ZVUKLOG" 2>&1 & )
      ;;
  esac
}

while :; do
  # -u = только чтение: без этого socat закрывает соединение по EOF на stdin
  /data/local/bin/socat -u TCP:127.0.0.1:9875 - 2>/dev/null | while :; do
    SZ=$(dd bs=4 count=1 2>/dev/null | od -An -tu4 2>/dev/null | tr -d ' \n')
    case "$SZ" in ''|*[!0-9]*) break ;; esac
    [ "$SZ" -le 0 ] && break
    [ "$SZ" -gt 600000 ] && break
    dd bs="$SZ" count=1 of="$FRAME" 2>/dev/null
    [ -s "$PAT" ] || continue
    while read -r PATTERN; do
      [ -z "$PATTERN" ] && continue
      case "$PATTERN" in \#*) continue ;; esac
      if grep -aqF -- "$PATTERN" "$FRAME"; then
        NOW=$(date +%s)
        # Распознавание приходит несколькими кадрами, и в одном кадре могут совпасть сразу
        # два шаблона («ыключи музыку» и «ыключи»). Раньше гасился только повтор ТОГО ЖЕ
        # шаблона, поэтому чередование давало серию команд (наблюдали 8 «стоп» подряд).
        # Теперь после любого срабатывания молчим COOLDOWN секунд.
        LAST_TS=0
        [ -f "$STATE" ] && LAST_TS=$(cut -d'|' -f1 "$STATE" 2>/dev/null)
        case "$LAST_TS" in ''|*[!0-9]*) LAST_TS=0 ;; esac
        if [ $((NOW - LAST_TS)) -lt "$COOLDOWN" ]; then
          continue
        fi
        echo "$NOW|$PATTERN" > "$STATE"
        hook "$PATTERN"
      fi
    done < "$PAT"
  done
  echo "$(date): соединение с IPC потеряно, переподключаюсь" >> "$LOG"
  sleep 2
done
