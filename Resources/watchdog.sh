#!/bin/sh
# Turns lid-close sleep off, then turns it back on when any stop condition hits.
# Runs as root after the admin prompt, or as the user when the optional
# /etc/sudoers.d/lid-awake rule allows exactly these two pmset commands.
#   $1 flag file   app writes it to request "turn off" (no second password needed)
#   $2 app pid     if Lid Awake quits or crashes, normal sleep comes back
#   $3 deadline    epoch seconds, 0 = no timer
#   $4 min battery percent on battery power before auto-off

FLAG="$1"
APP_PID="$2"
DEADLINE="$3"
MIN_BATT="$4"

set_sleep() {
  if [ "$(id -u)" -eq 0 ]; then
    /usr/bin/pmset -a disablesleep "$1"
  else
    sudo -n /usr/bin/pmset -a disablesleep "$1"
  fi
}

rm -f "$FLAG"
set_sleep 1

while :; do
  sleep 5
  [ -e "$FLAG" ] && break
  kill -0 "$APP_PID" 2>/dev/null || break
  if [ "$DEADLINE" -gt 0 ] && [ "$(date +%s)" -ge "$DEADLINE" ]; then break; fi
  BATT=$(/usr/bin/pmset -g batt)
  if echo "$BATT" | grep -q "Battery Power"; then
    PCT=$(echo "$BATT" | grep -Eo '[0-9]+%' | head -1 | tr -d '%')
    if [ -n "$PCT" ] && [ "$PCT" -le "$MIN_BATT" ]; then break; fi
  fi
done

set_sleep 0
rm -f "$FLAG"
