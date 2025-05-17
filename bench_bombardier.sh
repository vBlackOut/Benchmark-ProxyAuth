#!/bin/bash

# === CONFIGURATION ===
URL="https://127.0.0.1:8080/app"
AUTH_URL="https://127.0.0.1:8080/auth"
USERNAME="admin"
PASSWORD="admin123"
DURATION=300           # Total benchmark duration in seconds
INTERVAL=10            # Interval between measurements
CONNECTIONS=500
TIMEOUT=8
FINAL_JSON="chart_metrics.json"

# === REQUIREMENTS CHECK ===
for cmd in curl jq bc sensors bombardier; do
  command -v $cmd >/dev/null || { echo "$cmd is required"; exit 1; }
done

export CURL_CA_BUNDLE=""

# === INIT JSON OUTPUT ===
echo "[" > "$FINAL_JSON"
FIRST=true

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
  RESPONSE=$(curl -k -s -X POST "$AUTH_URL" \
    -H "Content-Type: application/json" \
    -d "{\"username\": \"$USERNAME\", \"password\": \"$PASSWORD\"}")
  TOKEN=$(echo "$RESPONSE" | jq -r .token)

  if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    echo "Token not received. Full response: $RESPONSE"
    exit 1
  fi

  echo "[+] Token OK. Benchmarking for $INTERVAL seconds..."

  OUT=$(bombardier -k -c $CONNECTIONS -d${INTERVAL}s -t${TIMEOUT}s -l \
  -H "Authorization: Bearer $TOKEN" "$URL">&1)

  RPS=$(echo "$OUT" | grep -i "Reqs/sec" | awk '{print $2}')
  LATENCY=$(echo "$OUT" | grep -i "Latency" | head -n1 | awk '{print $2}')
  MAX_LATENCY=$(echo "$OUT" | grep -i "99%" | awk '{print $2}')
  NOW=$(date +%s)

  LAT_MS=$(convert_latency "$LATENCY")
  MAX_LAT_MS=$(convert_latency "$MAX_LATENCY")

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

  TEMP=$(sensors | grep -m1 'CPUTIN' | grep -oE '\+[0-9]+\.[0-9]+' | head -n1 | tr -d '+')
  [[ -z "$TEMP" ]] && TEMP=$(sensors | grep -m1 'CPU' | grep -oE '\+[0-9]+\.[0-9]+' | head -n1 | tr -d '+')
  [[ -z "$TEMP" ]] && TEMP="0.0"
  [[ "$TEMP" =~ ^\.[0-9]+$ ]] && TEMP="0$TEMP"

  METRIC=$(jq -n \
    --argjson timestamp "$NOW" \
    --argjson rps "${RPS:-0}" \
    --argjson latency "${LAT_MS:-0}" \
    --argjson max_latency "${MAX_LAT_MS:-0}" \
    --argjson cpu "${CPU_LOAD:-0}" \
    --argjson temp "${TEMP:-0}" \
    '{timestamp: $timestamp, rps: $rps, latency_ms: $latency, max_latency_ms: $max_latency, cpu_percent: $cpu, cpu_temp: $temp}')

  if [ "$FIRST" = true ]; then
    FIRST=false
    echo "$METRIC" >> "$FINAL_JSON"
  else
    echo ", $METRIC" >> "$FINAL_JSON"
  fi

  echo "[+] $NOW : RPS=$RPS, Lat=$LAT_MS ms, MaxLat=$MAX_LAT_MS ms, CPU=$CPU_LOAD%, TempCPU=${TEMP}°C"
done

echo "]" >> "$FINAL_JSON"
echo "[x] JSON metrics exported to $FINAL_JSON"
