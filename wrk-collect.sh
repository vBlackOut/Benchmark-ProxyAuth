#!/bin/bash

# === CONFIGURATION ===
URL="https://127.0.0.1:8080/app"
AUTH_URL="https://127.0.0.1:8080/auth"
USERNAME="admin"
PASSWORD="admin123"
DURATION=300            # Total benchmark duration in seconds
INTERVAL=10             # Interval between measurements
CONNECTIONS=500 # laptop 100 / 500 on server.
THREADS=64 # change over your configuration cpu
FINAL_JSON="chart_metrics.json"
TIMEOUT=5               # curl timeout in seconds

# === REQUIREMENTS CHECK ===
for cmd in curl jq wrk bc sensors ss lsof; do
  command -v $cmd >/dev/null || { echo "$cmd is required"; exit 1; }
done

export CURL_CA_BUNDLE=""

# === INIT JSON OUTPUT ===
echo "[" > "$FINAL_JSON"
FIRST=true

# === LATENCY CONVERSION (us/ms/s -> ms) ===
convert_latency() {
  local val="$1"
  local result
  if [[ "$val" == *ms ]]; then
    result="${val%ms}"
  elif [[ "$val" == *us ]]; then
    base="${val%us}"
    result=$(echo "scale=3; $base / 1000" | bc)
  elif [[ "$val" == *s ]]; then
    base="${val%s}"
    result=$(echo "$base * 1000" | bc)
  else
    result="0"
  fi
  [[ "$result" =~ ^\.[0-9]+$ ]] && result="0$result"
  echo "$result"
}

# === GET CPU SNAPSHOT ===
get_cpu_usage_snapshot() {
  read cpu user nice system idle iowait irq softirq steal guest < /proc/stat
  active=$((user + nice + system + irq + softirq + steal))
  total=$((active + idle + iowait))
  echo "$active $total"
}

# === MAIN LOOP ===
SECONDS=0
read prev_active prev_total < <(get_cpu_usage_snapshot)

while [ $SECONDS -lt $DURATION ]; do
  echo "[+] Authenticating..."
  RESPONSE=$(curl -k -s --max-time "$TIMEOUT" -X POST "$AUTH_URL" \
    -H "Content-Type: application/json" \
    -d "{\"username\": \"$USERNAME\", \"password\": \"$PASSWORD\"}")

  TOKEN=$(echo "$RESPONSE" | jq -r .token)

  if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    echo "❌ Token not received. Full response: $RESPONSE"
    exit 1
  fi

  echo "[+] Token OK. Running wrk for $INTERVAL seconds..."

  OUT=$(timeout $(($INTERVAL + 2))s wrk -t$THREADS -c$CONNECTIONS -d${INTERVAL}s \
    -H "Authorization: Bearer $TOKEN" "$URL" 2>&1)

  RPS=$(echo "$OUT" | grep "Requests/sec" | awk '{print $2}')
  LATENCY=$(echo "$OUT" | grep -m1 "Latency" | awk '{print $2}')
  MAX_LATENCY=$(echo "$OUT" | grep -m1 "Latency" | awk '{print $4}')
  NOW=$(date +%s)

  LATENCY=${LATENCY:-0ms}
  MAX_LATENCY=${MAX_LATENCY:-0ms}
  LAT_MS=$(convert_latency "$LATENCY")
  MAX_LAT_MS=$(convert_latency "$MAX_LATENCY")

  # === CPU USAGE DIFF ===
  read cur_active cur_total < <(get_cpu_usage_snapshot)
  delta_total=$((cur_total - prev_total))
  delta_active=$((cur_active - prev_active))
  if [ "$delta_total" -gt 0 ]; then
    CPU_LOAD=$(echo "scale=2; 100 * $delta_active / $delta_total" | bc)
  else
    CPU_LOAD="0.00"
  fi
  [[ "$CPU_LOAD" =~ ^\.[0-9]+$ ]] && CPU_LOAD="0$CPU_LOAD"
  prev_active=$cur_active
  prev_total=$cur_total

  # === TEMP CPU ===
  TEMP=$(sensors | grep -m1 'CPUTIN' | grep -oE '\+[0-9]+\.[0-9]+' | head -n1 | tr -d '+')
  [[ -z "$TEMP" ]] && TEMP=$(sensors | grep -m1 'CPU' | grep -oE '\+[0-9]+\.[0-9]+' | head -n1 | tr -d '+')
  [[ -z "$TEMP" ]] && TEMP="0.0"
  [[ "$TEMP" =~ ^\.[0-9]+$ ]] && TEMP="0$TEMP"

  # === CONNECTION DEBUG ===
  PID=$(pidof proxyauth)
  FD_COUNT=$(ls /proc/$PID/fd | wc -l)
  TIMEWAIT_COUNT=$(ss -tan state time-wait | wc -l)
  ESTAB_COUNT=$(ss -tan state established | grep -c 127.0.0.1)

  echo "[+] $NOW : RPS=$RPS, Lat=$LAT_MS ms, MaxLat=$MAX_LAT_MS ms, CPU=$CPU_LOAD%, TempCPU=${TEMP}°C"
  echo "    ↳ FD=$FD_COUNT | TIME_WAIT=$TIMEWAIT_COUNT | ESTABLISHED=$ESTAB_COUNT"

  # === BUILD METRIC JSON ===
  METRIC=$(jq -n \
    --argjson timestamp "$NOW" \
    --argjson rps "${RPS:-0}" \
    --argjson latency "${LAT_MS:-0}" \
    --argjson max_latency "${MAX_LAT_MS:-0}" \
    --argjson cpu "${CPU_LOAD:-0}" \
    --argjson temp "${TEMP:-0}" \
    '{timestamp: $timestamp, rps: $rps, latency_ms: $latency, max_latency_ms: $max_latency, cpu_percent: $cpu, cpu_temp: $temp}')

  # === APPEND JSON ===
  if [ "$FIRST" = true ]; then
    FIRST=false
    echo "$METRIC" >> "$FINAL_JSON"
  else
    echo ", $METRIC" >> "$FINAL_JSON"
  fi
done

echo "]" >> "$FINAL_JSON"
echo "[✔] Benchmark complete. Metrics exported to $FINAL_JSON"
