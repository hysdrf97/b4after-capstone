# B4 After — Infrastruktur Hybrid Cloud
**Capstone Project | CIMB Niaga | Topik B.4: Exploding User Data Scalabilities**

Cloud Infrastructure Engineer: **Firda Aisyah** (235150307111031)

---

## Gambaran Arsitektur

```
Internet / Load Tester (k6/JMeter)
           │
           ▼
    ┌─────────────┐
    │    NGINX     │  ← Load Balancer + Rate Limiter
    │  Port: 80    │
    └──────┬──────┘
           │ least_conn routing
    ┌──────┴──────────────────────┐
    │                             │
    ▼                             ▼
┌────────┐   (scale out)   ┌────────────────┐
│ api-1  │ ──────────────► │ api-2 / api-3  │
│ (lokal)│                 │ (cloud replica) │
└───┬────┘                 └───────┬────────┘
    │                              │
    ├──────────────────────────────┤
    │                              │
    ▼                              ▼
┌──────────┐              ┌──────────────┐
│ Redis    │              │  RabbitMQ    │
│ (Cache)  │              │  (Async MQ)  │
└──────────┘              └──────────────┘
    │
    ▼
┌─────────────────────────────────┐
│  PostgreSQL Primary  (Write)     │
│  PostgreSQL Replica  (Read)      │
└─────────────────────────────────┘
    │
    ▼
┌──────────────────────────┐
│  Prometheus + Grafana     │
│  Node Exporter + cAdvisor │
└──────────────────────────┘
```

---

## Cara Menjalankan

### 1. Pastikan Docker sudah terinstall
```bash
docker --version
docker compose version
```

### 2. Jalankan infrastruktur
```bash
chmod +x manage.sh scripts/autoscaler.sh
./manage.sh start
```

### 3. Cek status
```bash
./manage.sh status
```

### 4. Akses dashboard
| Layanan    | URL                        | Login              |
|------------|----------------------------|--------------------|
| API        | http://localhost:80        | -                  |
| Grafana    | http://localhost:3000      | admin / admin123   |
| Prometheus | http://localhost:9090      | -                  |
| RabbitMQ   | http://localhost:15672     | b4after / b4after_secret |

---

## Simulasi Auto-Scaling

### Manual (untuk demo/presentasi)
```bash
# Scale out ke 2 instance
./manage.sh scale-out 2

# Scale out ke 3 instance (beban maksimal)
./manage.sh scale-out 3

# Scale in kembali ke 1
./manage.sh scale-in
```

### Otomatis (jalankan bersamaan dengan load test)
```bash
./manage.sh autoscale
```

---

## Threshold Auto-Scaler

| Kondisi       | Metrik           | Aksi        |
|---------------|------------------|-------------|
| Scale OUT     | CPU > 70%        | +1 instance |
| Scale OUT     | Memory > 80%     | +1 instance |
| Scale OUT     | RPS > 500/detik  | +1 instance |
| Scale IN      | CPU < 30% AND    | -1 instance |
|               | Memory < 40% AND |             |
|               | RPS < 100/detik  |             |

---

## Struktur File

```
infra-b4after/
├── docker-compose.yml       ← Semua service didefinisikan di sini
├── manage.sh                ← Script manajemen mudah
├── nginx/
│   └── nginx.conf           ← Load balancer + rate limiter
├── postgres/
│   ├── init.sql             ← Inisialisasi database + dummy data
│   └── primary.conf         ← Konfigurasi PostgreSQL primary
├── prometheus/
│   ├── prometheus.yml       ← Konfigurasi scraping metrics
│   └── alert_rules.yml      ← Aturan alert otomatis
├── grafana/
│   └── provisioning/        ← Auto-setup datasource Grafana
└── scripts/
    └── autoscaler.sh        ← Script auto-scaling utama
```

---

## Komponen yang Dibangun Firda (Cloud Infra Engineer)

| Komponen              | File                          | Fungsi                                     |
|-----------------------|-------------------------------|--------------------------------------------|
| Docker Compose        | `docker-compose.yml`          | Mendefinisikan & mengorkestrasi semua service |
| Load Balancer         | `nginx/nginx.conf`            | Distribusi traffic + rate limiting          |
| Auto-Scaler           | `scripts/autoscaler.sh`       | Scale out/in otomatis berdasarkan threshold |
| Monitoring            | `prometheus/prometheus.yml`   | Kumpulkan metrics dari semua service        |
| Alert Rules           | `prometheus/alert_rules.yml`  | Trigger alert saat beban tinggi             |
| Database Config       | `postgres/primary.conf`       | Optimasi PostgreSQL + replikasi             |
| Management Script     | `manage.sh`                   | Shortcut command untuk tim                 |

---

## Integrasi dengan Anggota Lain

- **Akwila (Backend)** → Build image API di folder `./api/`, expose `/metrics` endpoint
- **Destyanaraira (System Analyst)** → Threshold di `autoscaler.sh` bisa disesuaikan
- **Salma (Network Eng.)** → Konfigurasi jaringan di `docker-compose.yml` bagian `networks`
- **Andhika (PM)** → Lihat hasil monitoring di Grafana dashboard
