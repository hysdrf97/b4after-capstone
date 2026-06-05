package observability

import "go.uber.org/zap"

var Logger *zap.Logger

func InitLogger() {
    // Production: output JSON (structured)
    Logger, _ = zap.NewProduction()
}