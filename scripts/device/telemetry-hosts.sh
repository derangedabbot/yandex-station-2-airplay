#!/bin/sh
# Телеметрия AppMetrica. Служба metricad (это maind --telemetry) должна быть жива:
# без неё maind каждые 10 секунд пишет «Unable to send a message to the metricad service»
# — за сутки это тысячи строк в лог на флеше.
# Наружу ничего не уходит: домены AppMetrica указывают на 127.0.0.1, соединение получает отказ.
H=/etc/hosts
grep -q 'report.appmetrica.yandex.net' "$H" 2>/dev/null && exit 0
mount -o remount,rw / 2>/dev/null
cp -p "$H" "/etc/hosts.bak-$(date +%s)" 2>/dev/null
{
  echo '127.0.0.1\treport.appmetrica.yandex.net'
  echo '127.0.0.1\tstartup.mobile.yandex.net'
  echo '127.0.0.1\tappmetrica.yandex.net'
} >> "$H"
sync
mount -o remount,ro / 2>/dev/null
