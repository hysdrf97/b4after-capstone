package middleware

import (
    "fmt"
    "time"

    "github.com/gin-gonic/gin"
    "github.com/google/uuid"
    "project1/internal/observability"
    "go.uber.org/zap"
)

// ── Tracing ID ───────────────────────────────────────────
func TraceID() gin.HandlerFunc {
    return func(c *gin.Context) {
        traceID := uuid.New().String()
        c.Set("trace_id", traceID)
        c.Header("X-Trace-ID", traceID) // kirim balik ke client juga
        c.Next()
    }
}

// ── Metrics + Structured Log ─────────────────────────────
func MetricsLogger() gin.HandlerFunc {
    return func(c *gin.Context) {
        start   := time.Now()
        path    := c.FullPath()   // "/users/:id" bukan "/users/123"
        method  := c.Request.Method

        observability.HttpInFlight.Inc()
        c.Next()
        observability.HttpInFlight.Dec()

        duration := float64(time.Since(start).Milliseconds())
        status   := fmt.Sprintf("%d", c.Writer.Status())
        traceID, _ := c.Get("trace_id")

        // Record ke Prometheus
        observability.HttpDuration.WithLabelValues(method, path, status).Observe(duration)
        observability.HttpRequests.WithLabelValues(method, path, status).Inc()

        // Structured log tiap request
        observability.Logger.Info("request",
            zap.String("trace_id", fmt.Sprintf("%v", traceID)),
            zap.String("method",   method),
            zap.String("path",     path),
            zap.String("status",   status),
            zap.Float64("duration_ms", duration),
        )
    }
}