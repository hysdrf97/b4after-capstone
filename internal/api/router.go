package api

import (
    "github.com/gin-gonic/gin"
    "github.com/prometheus/client_golang/prometheus/promhttp"
    "project1/internal/middleware"
)

func SetupRouter() *gin.Engine {
    r := gin.Default()

    // ── Middleware ────────────────────────────────────────
    r.Use(middleware.TraceID())
    r.Use(middleware.MetricsLogger())

    // ── Metrics endpoint untuk Prometheus ────────────────
    r.GET("/metrics", gin.WrapH(promhttp.Handler()))

    // ── Health check ──────────────────────────────────────
    r.GET("/health", HealthCheck)

    // ── API endpoints ─────────────────────────────────────
    r.GET("/users/:id",        GetUser)
    r.GET("/transactions/:id", GetTransaction)
    r.POST("/transactions",    CreateTransaction)

    return r
}
