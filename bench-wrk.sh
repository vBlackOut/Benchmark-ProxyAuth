#!/bin/bash

# === CONFIGURATION ===
URL="https://127.0.0.1:8080/app"
AUTH_URL="https://127.0.0.1:8080/auth"
USERNAME="admin"
PASSWORD="admin123"
DURATION=300            # Total benchmark duration in seconds
INTERVAL=10            # Interval between measurements
CONNECTIONS=200
THREADS=8
FINAL_JSON="chart_metrics.json"

# === REQUIREMENTS CHECK ===
command -v curl >/dev/null || { echo "curl is required"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }
command -v wrk >/dev/null || { echo "wrk is required"; exit 1; }
command -v bc >/dev/null || { echo "bc is required"; exit 1; }

export CURL_CA_BUNDLE=""

# === INIT JSON OUTPUT ===
echo "[" > "$FINAL_JSON"
FIRST=true

# === LATENCY CONVERSION TO JSON-SAFE FLOAT (ms) ===
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

    # Fix if result starts with dot (.xxx)
    if [[ "$result" =~ ^\.[0-9]+$ ]]; then
        result="0$result"
    fi

    echo "$result"
}

# === FAST CPU USAGE CALCULATION (approx) ===
get_cpu_usage_snapshot() {
    read cpu user nice system idle iowait irq softirq steal guest < /proc/stat
    active=$((user + nice + system + irq + softirq + steal))
    total=$((active + idle + iowait))
    echo "$active $total"
}

# === MAIN LOOP ===
SECONDS=0
PREV_ACTIVE=0
PREV_TOTAL=0

read prev_active prev_total < <(get_cpu_usage_snapshot)

while [ $SECONDS -lt $DURATION ]; do
    echo "[+] Authenticating..."

    RESPONSE=$(curl -k -s -X POST "$AUTH_URL" \
        -H "Content-Type: application/json" \
        -d "{\"username\": \"$USERNAME\", \"password\": \"$PASSWORD\"}")
    TOKEN=$(echo "$RESPONSE" | jq -r .token)

    if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
        echo "❌ Token not received. Full response: $RESPONSE"
        exit 1
    fi

    echo "[+] Token OK. Benchmarking for $INTERVAL seconds..."

    OUT=$(wrk -t$THREADS -c$CONNECTIONS -d${INTERVAL}s \
        -H "Authorization: Bearer $TOKEN" "$URL" 2>&1)

    RPS=$(echo "$OUT" | grep "Requests/sec" | awk '{print $2}')
    LATENCY=$(echo "$OUT" | grep -m1 "Latency" | awk '{print $2}')
    MAX_LATENCY=$(echo "$OUT" | grep -m1 "Latency" | awk '{print $4}')
    NOW=$(date +%s)

    LATENCY=${LATENCY:-0ms}
    MAX_LATENCY=${MAX_LATENCY:-0ms}
    LAT_MS=$(convert_latency "$LATENCY")
    MAX_LAT_MS=$(convert_latency "$MAX_LATENCY")

    # === QUICK CPU DIFF ===
    read cur_active cur_total < <(get_cpu_usage_snapshot)

    delta_total=$((cur_total - prev_total))
    delta_active=$((cur_active - prev_active))

    if [ "$delta_total" -gt 0 ]; then
        CPU_LOAD=$(echo "scale=2; 100 * $delta_active / $delta_total" | bc)
    else
        CPU_LOAD="0.00"
    fi

    if [[ "$CPU_LOAD" =~ ^\.[0-9]+$ ]]; then
        CPU_LOAD="0$CPU_LOAD"
    fi

    # Update previous snapshot
    PREV_ACTIVE=$cur_active
    PREV_TOTAL=$cur_total

    # === BUILD METRIC JSON ===
    METRIC=$(jq -n \
      --argjson timestamp "$NOW" \
      --argjson rps "${RPS:-0}" \
      --argjson latency "${LAT_MS:-0}" \
      --argjson max_latency "${MAX_LAT_MS:-0}" \
      --argjson cpu "${CPU_LOAD:-0}" \
      '{timestamp: $timestamp, rps: $rps, latency_ms: $latency, max_latency_ms: $max_latency, cpu_percent: $cpu}')

    # === APPEND TO FILE ===
    if [ "$FIRST" = true ]; then
        FIRST=false
        echo "$METRIC" >> "$FINAL_JSON"
    else
        echo ", $METRIC" >> "$FINAL_JSON"
    fi

    echo "[+] $NOW : RPS=$RPS, Lat=$LAT_MS ms, MaxLat=$MAX_LAT_MS ms, CPU=$CPU_LOAD%"
done

echo "]" >> "$FINAL_JSON"
echo "[x] JSON metrics exported to $FINAL_JSON"
