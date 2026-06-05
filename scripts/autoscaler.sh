#!/bin/bash
set -euo pipefail

# --- CONFIGURATION ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"

CPU_THRESHOLD_UP="${CPU_THRESHOLD_UP:-70}"
MEMORY_THRESHOLD_UP="${MEMORY_THRESHOLD_UP:-80}"
RPS_THRESHOLD_UP="${RPS_THRESHOLD_UP:-500}"
CPU_THRESHOLD_DOWN="${CPU_THRESHOLD_DOWN:-30}"
MEMORY_THRESHOLD_DOWN="${MEMORY_THRESHOLD_DOWN:-40}"
RPS_THRESHOLD_DOWN="${RPS_THRESHOLD_DOWN:-100}"

MIN_INSTANCES=1
MAX_INSTANCES=3
COOLDOWN_SECONDS=60
CHECK_INTERVAL=15
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
STATE_FILE="/tmp/b4after_autoscaler_state"
LOG_FILE="/tmp/b4after_autoscaler.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- FUNCTIONS ---

log() {
    local level=$1; shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case $level in
        INFO)  echo -e "${GREEN}[${timestamp}] [INFO]${NC}  ${message}" | tee -a "$LOG_FILE" ;;
        WARN)  echo -e "${YELLOW}[${timestamp}] [WARN]${NC}  ${message}" | tee -a "$LOG_FILE" ;;
        ERROR) echo -e "${RED}[${timestamp}] [ERROR]${NC} ${message}" | tee -a "$LOG_FILE" ;;
        SCALE) echo -e "${CYAN}[${timestamp}] [SCALE]${NC} ${message}" | tee -a "$LOG_FILE" ;;
        DEBUG) echo -e "${BLUE}[${timestamp}] [DEBUG]${NC} ${message}" | tee -a "$LOG_FILE" ;;
    esac
}

get_running_instances() {
    local count=0
    for i in 1 2 3; do
        if docker ps --filter "name=b4after-api-${i}" --filter "status=running" --format "{{.Names}}" 2>/dev/null | grep -q "b4after-api-${i}"; then
            count=$((count + 1))
        fi
    done
    echo "$count"
}

get_cpu_usage() {
    local total_cpu=0
    local count=0
    while IFS= read -r line; do
        cpu=$(echo "$line" | awk '{gsub(/%/,"",$2); print $2}')
        if [[ -n "$cpu" && "$cpu" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            total_cpu=$(echo "$total_cpu + $cpu" | bc -l 2>/dev/null || echo "$total_cpu")
            count=$((count + 1))
        fi
    done < <(docker stats --no-stream --format "{{.Name}} {{.CPUPerc}}" 2>/dev/null | grep "b4after-api")
    if [[ $count -gt 0 ]]; then
        echo "$(echo "scale=1; $total_cpu / $count" | bc 2>/dev/null || echo "0")"
    else
        echo "0"
    fi
}

get_memory_usage() {
    local total_mem=0
    local count=0
    while IFS= read -r line; do
        mem=$(echo "$line" | awk '{gsub(/%/,"",$2); print $2}')
        if [[ -n "$mem" && "$mem" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            total_mem=$(echo "$total_mem + $mem" | bc -l 2>/dev/null || echo "$total_mem")
            count=$((count + 1))
        fi
    done < <(docker stats --no-stream --format "{{.Name}} {{.MemPerc}}" 2>/dev/null | grep "b4after-api")
    if [[ $count -gt 0 ]]; then
        echo "$(echo "scale=1; $total_mem / $count" | bc 2>/dev/null || echo "0")"
    else
        echo "0"
    fi
}

get_rps() {
    local rps=0
    if command -v curl &>/dev/null; then
        rps=$(curl -s --max-time 5 "${PROMETHEUS_URL}/api/v1/query?query=sum(rate(http_requests_total%5B1m%5D))" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    results = data.get('data', {}).get('result', [])
    if results:
        print(int(float(results[0]['value'][1])))
    else:
        print(0)
except:
    print(0)
" 2>/dev/null || echo "0")
    fi
    echo "${rps:-0}"
}

scale_out() {
    local current=$1 reason=$2
    if [[ $current -ge $MAX_INSTANCES ]]; then
        log "WARN" "Sudah di MAX_INSTANCES ($MAX_INSTANCES)." ; return 1
    fi
    local next=$((current + 1))
    log "SCALE" "▲ SCALE OUT: $current -> $next | Alasan: $reason"
    case $next in
  	2) docker compose -f "$COMPOSE_FILE" up -d api-2 ;;
  	3) docker compose -f "$COMPOSE_FILE" up -d api-3 ;;
    esac
    # case $next in
        # 2) docker compose -f "$COMPOSE_FILE" up -d api-2 2>&1 | tee -a "$LOG_FILE" ;;
        # 3) docker compose -f "$COMPOSE_FILE" up -d api-3 2>&1 | tee -a "$LOG_FILE" ;;
    # esac
    sleep 10
    docker exec b4after-nginx nginx -s reload 2>/dev/null || true
    log "SCALE" "✅ Scale out selesai! Instance aktif: ${next}/${MAX_INSTANCES}"
    echo "$(date +%s)" > "$STATE_FILE"
}

scale_in() {
    local current=$1 reason=$2
    if [[ $current -le $MIN_INSTANCES ]]; then
        log "WARN" "Sudah di MIN_INSTANCES ($MIN_INSTANCES)." ; return 1
    fi
    local next=$((current - 1))
    log "SCALE" "▼ SCALE IN: $current -> $next | Alasan: $reason"
    case $current in
        3) docker stop b4after-api-3 2>/dev/null || true ;;
        2) docker stop b4after-api-2 2>/dev/null || true ;;
    esac
    sleep 5
    docker exec b4after-nginx nginx -s reload 2>/dev/null || true
    log "SCALE" "✅ Scale in selesai! Instance aktif: ${next}/${MAX_INSTANCES}"
    echo "$(date +%s)" > "$STATE_FILE"
}

is_in_cooldown() {
    if [[ ! -f "$STATE_FILE" ]]; then return 1; fi
    local last_scale elapsed
    last_scale=$(cat "$STATE_FILE")
    elapsed=$(( $(date +%s) - last_scale ))
    if [[ $elapsed -lt $COOLDOWN_SECONDS ]]; then
        log "DEBUG" "Cooldown aktif. Sisa: $((COOLDOWN_SECONDS - elapsed))s"
        return 0
    fi
    return 1
}

print_dashboard() {
    local instances=$1 cpu=$2 mem=$3 rps=$4
    clear
    echo -e "${BOLD}${BLUE}"
    echo "    ╔══════════════════════════════════════════════════════════════╗"
    echo "    ║          B4 AFTER - AUTO-SCALER MONITORING DASHBOARD         ║"
    echo "    ║                   Capstone CIMB Niaga                        ║"
    echo "    ╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  🕒 Waktu       : $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "  🖥️  Instances   : ${GREEN}${BOLD}${instances}${NC} / ${MAX_INSTANCES} aktif"
    echo ""
    echo -e "  ${YELLOW}┌── METRICS REAL-TIME ──────────────────────────────────────────┐${NC}"
    echo -e "  ${YELLOW}│${NC} CPU Usage   : ${cpu}%"
    echo -e "  ${YELLOW}│${NC} Memory      : ${mem}%"
    echo -e "  ${YELLOW}│${NC} RPS         : ${rps} req/s"
    echo -e "  ${YELLOW}└───────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  ${YELLOW}┌── THRESHOLD ──────────────────────────────────────────────────┐${NC}"
    echo -e "  ${YELLOW}│${NC} Scale OUT : CPU>${CPU_THRESHOLD_UP}% | RAM>${MEMORY_THRESHOLD_UP}% | RPS>${RPS_THRESHOLD_UP}"
    echo -e "  ${YELLOW}│${NC} Scale IN  : CPU<${CPU_THRESHOLD_DOWN}% | RAM<${MEMORY_THRESHOLD_DOWN}% | RPS<${RPS_THRESHOLD_DOWN}"
    echo -e "  ${YELLOW}│${NC} Cooldown  : ${COOLDOWN_SECONDS}s | Interval: ${CHECK_INTERVAL}s"
    echo -e "  ${YELLOW}└───────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  📋 Log      : tail -f ${LOG_FILE}"
    echo -e "  📊 Grafana  : http://localhost:3000"
    echo -e "  🛑 Stop     : Ctrl+C"
}

init() {
    log "INFO" "B4 After Auto-Scaler - Memulai..."
    if ! command -v docker &>/dev/null; then log "ERROR" "Docker tidak ditemukan!" ; exit 1; fi
    if ! command -v bc &>/dev/null; then sudo apt-get install -y bc 2>/dev/null || true; fi
    if [[ ! -f "$COMPOSE_FILE" ]]; then log "ERROR" "docker-compose.yml tidak ditemukan di: $COMPOSE_FILE" ; exit 1; fi
    log "INFO" "Compose file : $COMPOSE_FILE"
    log "INFO" "Prometheus   : $PROMETHEUS_URL"
    log "INFO" "Autoscaler siap. Monitor setiap ${CHECK_INTERVAL} detik..."
}

main() {
    init
    while true; do
        current_instances=$(get_running_instances)
        cpu_usage=$(get_cpu_usage)
        mem_usage=$(get_memory_usage)
        rps=$(get_rps)

        print_dashboard "$current_instances" "$cpu_usage" "$mem_usage" "$rps"

        if is_in_cooldown; then
            sleep "$CHECK_INTERVAL"
            continue
        fi

        should_scale_out=false
        scale_reason=""
        if (( $(echo "$cpu_usage > $CPU_THRESHOLD_UP" | bc -l 2>/dev/null || echo 0) )); then
            should_scale_out=true; scale_reason="CPU tinggi: ${cpu_usage}%"
        fi
        if (( $(echo "$mem_usage > $MEMORY_THRESHOLD_UP" | bc -l 2>/dev/null || echo 0) )); then
            should_scale_out=true; scale_reason="${scale_reason:+$scale_reason | }Memory tinggi: ${mem_usage}%"
        fi
        if [[ $rps -gt $RPS_THRESHOLD_UP ]]; then
            should_scale_out=true; scale_reason="${scale_reason:+$scale_reason | }RPS tinggi: ${rps}"
        fi

        should_scale_in=false
        if (( $(echo "$cpu_usage < $CPU_THRESHOLD_DOWN" | bc -l 2>/dev/null || echo 0) )) && \
           (( $(echo "$mem_usage < $MEMORY_THRESHOLD_DOWN" | bc -l 2>/dev/null || echo 0) )) && \
           [[ $rps -lt $RPS_THRESHOLD_DOWN ]]; then
            should_scale_in=true
        fi

        if [[ "$should_scale_out" == "true" ]]; then
            scale_out "$current_instances" "$scale_reason"
        elif [[ "$should_scale_in" == "true" && $current_instances -gt $MIN_INSTANCES ]]; then
            scale_in "$current_instances" "Beban rendah - CPU:${cpu_usage}% MEM:${mem_usage}% RPS:${rps}"
        else
            log "INFO" "Normal. Instances: ${current_instances} | CPU: ${cpu_usage}% | MEM: ${mem_usage}% | RPS: ${rps}"
        fi

        sleep "$CHECK_INTERVAL"
    done
}

trap 'echo ""; log "INFO" "Autoscaler dihentikan."; exit 0' INT TERM

main
