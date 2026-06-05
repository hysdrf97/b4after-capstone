#!/bin/bash
# ==============================================================
# B4 After - Management Script
# Script pembantu untuk menjalankan & mengelola infrastruktur
# Firda Aisyah - Cloud Infrastructure Engineer
# ==============================================================

set -euo pipefail

COMPOSE_FILE="$(dirname "$0")/docker-compose.yml"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║   B4 After - Hybrid Cloud Infrastructure         ║"
    echo "║   Capstone CIMB Niaga | Firda Aisyah             ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

cmd_start() {
    print_header
    echo -e "${GREEN}▶ Menjalankan infrastruktur dasar (1 API instance)...${NC}"
    docker compose -f "$COMPOSE_FILE" up -d \
        nginx api-1 postgres-primary postgres-replica \
        redis rabbitmq prometheus grafana node-exporter cadvisor
    echo ""
    echo -e "${GREEN}✅ Infrastruktur berjalan!${NC}"
    print_urls
}

cmd_stop() {
    echo -e "${RED}■ Menghentikan semua service...${NC}"
    docker compose -f "$COMPOSE_FILE" --profile scale --profile scale-max down
    echo -e "${GREEN}✅ Semua service dihentikan${NC}"
}

cmd_scale_out() {
    local target=${1:-2}
    echo -e "${YELLOW}🔺 Scale OUT ke ${target} instances...${NC}"
    case $target in
        2) docker compose -f "$COMPOSE_FILE" --profile scale up -d api-2 ;;
        3) docker compose -f "$COMPOSE_FILE" --profile scale --profile scale-max up -d api-2 api-3 ;;
        *) echo "Target tidak valid. Gunakan 2 atau 3"; exit 1 ;;
    esac
    docker exec b4after-nginx nginx -s reload 2>/dev/null || true
    echo -e "${GREEN}✅ Scale out selesai!${NC}"
}

cmd_scale_in() {
    echo -e "${YELLOW}🔻 Scale IN ke 1 instance...${NC}"
    docker stop b4after-api-2 2>/dev/null || true
    docker stop b4after-api-3 2>/dev/null || true
    docker exec b4after-nginx nginx -s reload 2>/dev/null || true
    echo -e "${GREEN}✅ Scale in selesai!${NC}"
}

cmd_status() {
    print_header
    echo -e "${CYAN}Status Container:${NC}"
    docker compose -f "$COMPOSE_FILE" --profile scale --profile scale-max ps
    echo ""
    echo -e "${CYAN}Resource Usage:${NC}"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" \
        2>/dev/null | grep -E "b4after|NAME" || echo "Tidak ada container berjalan"
}

cmd_autoscale() {
    echo -e "${CYAN}🤖 Menjalankan Auto-Scaler...${NC}"
    bash "$(dirname "$0")/scripts/autoscaler.sh"
}

cmd_logs() {
    local service=${1:-""}
    if [[ -n "$service" ]]; then
        docker compose -f "$COMPOSE_FILE" --profile scale --profile scale-max logs -f "$service"
    else
        docker compose -f "$COMPOSE_FILE" --profile scale --profile scale-max logs -f
    fi
}

print_urls() {
    echo ""
    echo -e "${CYAN}╔═══ AKSES LAYANAN ══════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC} 🌐 API Gateway  : http://localhost:80              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} 📊 Grafana      : http://localhost:3000             ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}    Login        : admin / admin123                  ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} 📈 Prometheus   : http://localhost:9090             ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC} 🐰 RabbitMQ     : http://localhost:15672            ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}    Login        : b4after / b4after_secret          ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Endpoint API:${NC}"
    echo "  POST /api/v1/transactions   → Buat transaksi (write-heavy)"
    echo "  GET  /api/v1/balance/:id    → Cek saldo (read-heavy, cached)"
    echo "  GET  /api/v1/status/:txnId  → Status transaksi"
    echo "  GET  /health                → Health check"
}

# ============================================================
# MAIN - Parse command
# ============================================================
case "${1:-help}" in
    start)      cmd_start ;;
    stop)       cmd_stop ;;
    status)     cmd_status ;;
    scale-out)  cmd_scale_out "${2:-2}" ;;
    scale-in)   cmd_scale_in ;;
    autoscale)  cmd_autoscale ;;
    logs)       cmd_logs "${2:-}" ;;
    urls)       print_urls ;;
    *)
        print_header
        echo "Penggunaan: $0 <command>"
        echo ""
        echo "Commands:"
        echo "  start          Jalankan semua service (1 API instance)"
        echo "  stop           Hentikan semua service"
        echo "  status         Lihat status & resource usage"
        echo "  scale-out [n]  Tambah instance (2 atau 3)"
        echo "  scale-in       Kurangi ke 1 instance"
        echo "  autoscale      Jalankan auto-scaler otomatis"
        echo "  logs [service] Lihat logs (opsional: nama service)"
        echo "  urls           Tampilkan URL akses"
        ;;
esac
