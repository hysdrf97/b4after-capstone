#!/bin/bash
# ==============================================================
# AUTO-SCALER - Inti dari Cloud Infrastructure Engineer
# B4 After Capstone - Firda Aisyah
#
# Script ini memantau beban sistem secara real-time dan
# otomatis menambah/mengurangi container API (scale out/in)
# berdasarkan threshold yang ditentukan.
#
# Cara kerja:
# 1. Cek metrics CPU, Memory, dan RPS setiap 15 detik
# 2. Jika beban > threshold UP  → tambah instance API (scale out)
# 3. Jika beban < threshold DOWN → kurangi instance API (scale in)
# ==============================================================

set -euo pipefail

# ============================================================
# KONFIGURASI THRESHOLD
# Sesuaikan nilai ini berdasarkan kapasitas hardware tim
# ============================================================

# Threshold untuk SCALE OUT (tambah instance)
CPU_THRESHOLD_UP=70        # CPU > 70% → scale out
MEMORY_THRESHOLD_UP=80     # Memory > 80% → scale out
RPS_THRESHOLD_UP=500       # Request/detik > 500 → scale out

# Threshold untuk SCALE IN (kurangi instance)
CPU_THRESHOLD_DOWN=30      # CPU < 30% → scale in
MEMORY_THRESHOLD_DOWN=40   # Memory < 40% → scale in
RPS_THRESHOLD_DOWN=100     # Request/detik < 100 → scale in

# Konfigurasi scaling
MIN_INSTANCES=1            # Minimal 1 instance API berjalan
MAX_INSTANCES=3            # Maksimal 3 instance API
COOLDOWN_SECONDS=60        # Jeda minimum antar scaling action
CHECK_INTERVAL=15          # Cek metrics setiap 15 detik

# Prometheus endpoint untuk ambil metrics
PROMETHEUS_URL="http://localhost:9090"

# File untuk tracking state
STATE_FILE="/tmp/autoscaler_state"
LOG_FILE="/var/log/autoscaler.log"

# ============================================================
# WARNA UNTUK OUTPUT
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ============================================================
# FUNGSI LOGGING
# ============================================================
log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        INFO)  echo -e "${GREEN}[${timestamp}] [INFO]${NC} ${message}" | tee -a "$LOG_FILE" ;;
        WARN)  echo -e "${YELLOW}[${timestamp}] [WARN]${NC} ${message}" | tee -a "$LOG_FILE" ;;
        ERROR) echo -e "${RED}[${timestamp}] [ERROR]${NC} ${message}" | tee -a "$LOG_FILE" ;;
        SCALE) echo -e "${CYAN}[${timestamp}] [SCALE]${NC} ${message}" | tee -a "$LOG_FILE" ;;
        *)     echo -e "${BLUE}[${timestamp}] [DEBUG]${NC} ${message}" | tee -a "$LOG_FILE" ;;
    esac
}

# ============================================================
# FUNGSI: Ambil jumlah instance yang sedang berjalan
# ============================================================
get_running_instances() {
    local count=0
    
    # Cek setiap container API apakah running
    for i in 1 2 3; do
        if docker ps --filter "name=b4after-api-${i}" --filter "status=running" | grep -q "b4after-api-${i}"; then
            count=$((count + 1))
        fi
    done
    
    echo $count
}

# ============================================================
# FUNGSI: Ambil metrics CPU container API
# ============================================================
get_cpu_usage() {
    local total_cpu=0
    local count=0
    
    # Ambil CPU usage dari semua container API yang running
    while IFS= read -r line; do
        if [[ $line =~ b4after-api ]]; then
            cpu=$(echo "$line" | awk '{print $3}' | sed 's/%//')
            if [[ -n "$cpu" && "$cpu" != "CPU%" ]]; then
                total_cpu=$(echo "$total_cpu + $cpu" | bc 2>/dev/null || echo "$total_cpu")
                count=$((count + 1))
            fi
        fi
    done < <(docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemPerc}}" 2>/dev/null)
    
    if [[ $count -gt 0 ]]; then
        echo $(echo "scale=1; $total_cpu / $count" | bc 2>/dev/null || echo "0")
    else
        echo "0"
    fi
}

# ============================================================
# FUNGSI: Ambil metrics Memory container API
# ============================================================
get_memory_usage() {
    local total_mem=0
    local count=0
    
    while IFS= read -r line; do
        if [[ $line =~ b4after-api ]]; then
            mem=$(echo "$line" | awk '{print $4}' | sed 's/%//')
            if [[ -n "$mem" && "$mem" != "MEM" ]]; then
                total_mem=$(echo "$total_mem + $mem" | bc 2>/dev/null || echo "$total_mem")
                count=$((count + 1))
            fi
        fi
    done < <(docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" 2>/dev/null)
    
    if [[ $count -gt 0 ]]; then
        echo $(echo "scale=1; $total_mem / $count" | bc 2>/dev/null || echo "0")
    else
        echo "0"
    fi
}

# ============================================================
# FUNGSI: Ambil RPS (Request Per Second) dari Prometheus
# ============================================================
get_rps() {
    # Query Prometheus untuk mendapat RPS dari nginx
    local rps=$(curl -s --max-time 5 \
        "${PROMETHEUS_URL}/api/v1/query?query=rate(nginx_http_requests_total[1m])" \
        2>/dev/null | \
        python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    results = data.get('data', {}).get('result', [])
    if results:
        print(float(results[0]['value'][1]))
    else:
        print(0)
except:
    print(0)
" 2>/dev/null || echo "0")
    
    echo "${rps%.*}"  # Bulatkan ke integer
}

# ============================================================
# FUNGSI: Scale OUT - Tambah instance API
# ============================================================
scale_out() {
    local current=$1
    local reason=$2
    
    if [[ $current -ge $MAX_INSTANCES ]]; then
        log "WARN" "Sudah mencapai MAX instances (${MAX_INSTANCES}). Tidak bisa scale out lagi!"
        return 1
    fi
    
    local next=$((current + 1))
    log "SCALE" "🔺 SCALE OUT: ${current} → ${next} instances | Alasan: ${reason}"
    
    # Tentukan profile Docker Compose berdasarkan target instance
    case $next in
        2)
            log "SCALE" "Mengaktifkan api-2 (cloud replica 1)..."
            docker compose -f /home/claude/infra-b4after/docker-compose.yml \
                --profile scale up -d api-2 2>/dev/null
            ;;
        3)
            log "SCALE" "Mengaktifkan api-3 (cloud replica 2)..."
            docker compose -f /home/claude/infra-b4after/docker-compose.yml \
                --profile scale-max up -d api-3 2>/dev/null
            ;;
    esac
    
    # Reload nginx untuk include server baru
    sleep 5
    docker exec b4after-nginx nginx -s reload 2>/dev/null || true
    
    log "SCALE" "✅ Scale out berhasil! Sekarang berjalan ${next} instance API"
    
    # Simpan timestamp scale terakhir (cooldown)
    echo "$(date +%s)" > "$STATE_FILE"
    
    return 0
}

# ============================================================
# FUNGSI: Scale IN - Kurangi instance API
# ============================================================
scale_in() {
    local current=$1
    local reason=$2
    
    if [[ $current -le $MIN_INSTANCES ]]; then
        log "WARN" "Sudah mencapai MIN instances (${MIN_INSTANCES}). Tidak bisa scale in lagi!"
        return 1
    fi
    
    local next=$((current - 1))
    log "SCALE" "🔻 SCALE IN: ${current} → ${next} instances | Alasan: ${reason}"
    
    # Hentikan instance yang tidak diperlukan (dari yang terbesar)
    case $current in
        3)
            log "SCALE" "Menghentikan api-3..."
            docker stop b4after-api-3 2>/dev/null || true
            ;;
        2)
            log "SCALE" "Menghentikan api-2..."
            docker stop b4after-api-2 2>/dev/null || true
            ;;
    esac
    
    # Reload nginx
    sleep 3
    docker exec b4after-nginx nginx -s reload 2>/dev/null || true
    
    log "SCALE" "✅ Scale in berhasil! Sekarang berjalan ${next} instance API"
    
    echo "$(date +%s)" > "$STATE_FILE"
    
    return 0
}

# ============================================================
# FUNGSI: Cek cooldown period
# Mencegah scaling terlalu sering (flapping)
# ============================================================
is_in_cooldown() {
    if [[ ! -f "$STATE_FILE" ]]; then
        return 1  # Tidak dalam cooldown
    fi
    
    local last_scale=$(cat "$STATE_FILE")
    local now=$(date +%s)
    local elapsed=$((now - last_scale))
    
    if [[ $elapsed -lt $COOLDOWN_SECONDS ]]; then
        local remaining=$((COOLDOWN_SECONDS - elapsed))
        log "DEBUG" "Dalam cooldown period. Sisa: ${remaining}s"
        return 0  # Masih cooldown
    fi
    
    return 1  # Cooldown selesai
}

# ============================================================
# FUNGSI: Print status dashboard ke terminal
# ============================================================
print_dashboard() {
    local instances=$1
    local cpu=$2
    local mem=$3
    local rps=$4
    
    clear
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║       B4 AFTER - AUTO-SCALER DASHBOARD                    ║${NC}"
    echo -e "${BLUE}║       Capstone CIMB Niaga - Cloud Infrastructure          ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  🕐 Waktu    : $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "  🖥️  Instances: ${GREEN}${instances}${NC} / ${MAX_INSTANCES} aktif"
    echo ""
    echo -e "${YELLOW}  ┌─ METRICS SAAT INI ─────────────────────────────┐${NC}"
    
    # CPU dengan indikator warna
    if (( $(echo "$cpu > $CPU_THRESHOLD_UP" | bc -l 2>/dev/null || echo 0) )); then
        echo -e "${YELLOW}  │ CPU Usage   : ${RED}${cpu}%${NC} ${RED}⚠ TINGGI (>${CPU_THRESHOLD_UP}%)${NC}"
    elif (( $(echo "$cpu < $CPU_THRESHOLD_DOWN" | bc -l 2>/dev/null || echo 0) )); then
        echo -e "${YELLOW}  │${NC} CPU Usage   : ${GREEN}${cpu}%${NC} (rendah)"
    else
        echo -e "${YELLOW}  │${NC} CPU Usage   : ${CYAN}${cpu}%${NC} (normal)"
    fi
    
    # Memory
    if (( $(echo "$mem > $MEMORY_THRESHOLD_UP" | bc -l 2>/dev/null || echo 0) )); then
        echo -e "${YELLOW}  │${NC} Memory      : ${RED}${mem}%${NC} ${RED}⚠ TINGGI (>${MEMORY_THRESHOLD_UP}%)${NC}"
    else
        echo -e "${YELLOW}  │${NC} Memory      : ${CYAN}${mem}%${NC}"
    fi
    
    # RPS
    if [[ $rps -gt $RPS_THRESHOLD_UP ]]; then
        echo -e "${YELLOW}  │${NC} RPS         : ${RED}${rps} req/s${NC} ${RED}⚠ TINGGI (>${RPS_THRESHOLD_UP})${NC}"
    else
        echo -e "${YELLOW}  │${NC} RPS         : ${CYAN}${rps} req/s${NC}"
    fi
    
    echo -e "${YELLOW}  └────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${YELLOW}  ┌─ THRESHOLD KONFIGURASI ────────────────────────┐${NC}"
    echo -e "${YELLOW}  │${NC} Scale OUT jika CPU > ${CPU_THRESHOLD_UP}% atau MEM > ${MEMORY_THRESHOLD_UP}% atau RPS > ${RPS_THRESHOLD_UP}"
    echo -e "${YELLOW}  │${NC} Scale IN  jika CPU < ${CPU_THRESHOLD_DOWN}% dan MEM < ${MEMORY_THRESHOLD_DOWN}% dan RPS < ${RPS_THRESHOLD_DOWN}"
    echo -e "${YELLOW}  │${NC} Cooldown  : ${COOLDOWN_SECONDS}s | Check interval: ${CHECK_INTERVAL}s"
    echo -e "${YELLOW}  └────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  📋 Log: tail -f ${LOG_FILE}"
    echo -e "  ⛔ Stop: Ctrl+C"
}

# ============================================================
# FUNGSI: Inisialisasi - cek semua dependency
# ============================================================
init() {
    log "INFO" "Memulai B4 After Auto-Scaler..."
    log "INFO" "Memeriksa dependency..."
    
    # Cek docker
    if ! command -v docker &>/dev/null; then
        log "ERROR" "Docker tidak ditemukan! Install Docker dulu."
        exit 1
    fi
    
    # Cek bc (kalkulator)
    if ! command -v bc &>/dev/null; then
        log "WARN" "bc tidak ditemukan, menginstall..."
        apt-get install -y bc 2>/dev/null || true
    fi
    
    # Buat log directory
    mkdir -p "$(dirname $LOG_FILE)" 2>/dev/null || LOG_FILE="/tmp/autoscaler.log"
    
    log "INFO" "✅ Inisialisasi selesai"
    log "INFO" "Threshold UP  : CPU>${CPU_THRESHOLD_UP}% | MEM>${MEMORY_THRESHOLD_UP}% | RPS>${RPS_THRESHOLD_UP}"
    log "INFO" "Threshold DOWN: CPU<${CPU_THRESHOLD_DOWN}% | MEM<${MEMORY_THRESHOLD_DOWN}% | RPS<${RPS_THRESHOLD_DOWN}"
}

# ============================================================
# MAIN LOOP - Jantung dari autoscaler
# ============================================================
main() {
    init
    
    log "INFO" "🚀 Autoscaler mulai berjalan. Monitoring setiap ${CHECK_INTERVAL} detik..."
    
    while true; do
        # Ambil semua metrics
        current_instances=$(get_running_instances)
        cpu_usage=$(get_cpu_usage)
        mem_usage=$(get_memory_usage)
        rps=$(get_rps)
        
        # Tampilkan dashboard
        print_dashboard "$current_instances" "$cpu_usage" "$mem_usage" "$rps"
        
        # Cek apakah dalam cooldown
        if is_in_cooldown; then
            log "DEBUG" "Cooldown aktif, skip scaling check"
            sleep $CHECK_INTERVAL
            continue
        fi
        
        # --------------------------------------------------------
        # KEPUTUSAN SCALING
        # --------------------------------------------------------
        
        # Kondisi Scale OUT (prioritas utama - lindungi layanan)
        should_scale_out=false
        scale_reason=""
        
        if (( $(echo "$cpu_usage > $CPU_THRESHOLD_UP" | bc -l 2>/dev/null || echo 0) )); then
            should_scale_out=true
            scale_reason="CPU tinggi: ${cpu_usage}%"
        fi
        
        if (( $(echo "$mem_usage > $MEMORY_THRESHOLD_UP" | bc -l 2>/dev/null || echo 0) )); then
            should_scale_out=true
            scale_reason="${scale_reason} | Memory tinggi: ${mem_usage}%"
        fi
        
        if [[ $rps -gt $RPS_THRESHOLD_UP ]]; then
            should_scale_out=true
            scale_reason="${scale_reason} | RPS tinggi: ${rps}"
        fi
        
        # Kondisi Scale IN (hemat resource saat sepi)
        should_scale_in=false
        
        if (( $(echo "$cpu_usage < $CPU_THRESHOLD_DOWN" | bc -l 2>/dev/null || echo 0) )) && \
           (( $(echo "$mem_usage < $MEMORY_THRESHOLD_DOWN" | bc -l 2>/dev/null || echo 0) )) && \
           [[ $rps -lt $RPS_THRESHOLD_DOWN ]]; then
            should_scale_in=true
        fi
        
        # Eksekusi keputusan
        if [[ "$should_scale_out" == "true" ]]; then
            scale_out "$current_instances" "$scale_reason"
        elif [[ "$should_scale_in" == "true" && $current_instances -gt $MIN_INSTANCES ]]; then
            scale_in "$current_instances" "Beban rendah (CPU:${cpu_usage}% MEM:${mem_usage}% RPS:${rps})"
        else
            log "INFO" "Beban normal. Instances: ${current_instances} | CPU: ${cpu_usage}% | MEM: ${mem_usage}% | RPS: ${rps}"
        fi
        
        sleep $CHECK_INTERVAL
    done
}

# ============================================================
# HANDLE CTRL+C dengan graceful
# ============================================================
trap 'log "INFO" "Autoscaler dihentikan."; exit 0' INT TERM

# Jalankan
main
