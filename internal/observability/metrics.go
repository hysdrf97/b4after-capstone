package observability

import "github.com/prometheus/client_golang/prometheus"

var (
    // Latency per endpoint
    HttpDuration = prometheus.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "http_request_duration_ms",
            Help:    "Latency per endpoint in milliseconds",
            Buckets: []float64{1, 5, 10, 25, 50, 100, 250, 500, 1000},
        },
        []string{"method", "path", "status"},
    )

    // RPS (request per second)
    HttpRequests = prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Name: "http_requests_total",
            Help: "Total HTTP requests",
        },
        []string{"method", "path", "status"},
    )

    // Request in-flight (berapa request sedang diproses)
    HttpInFlight = prometheus.NewGauge(
        prometheus.GaugeOpts{
            Name: "http_requests_in_flight",
            Help: "Current requests being processed",
        },
    )
)

func Init() {
    prometheus.MustRegister(HttpDuration)
    prometheus.MustRegister(HttpRequests)
    prometheus.MustRegister(HttpInFlight)
}