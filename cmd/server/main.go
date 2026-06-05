package main

import (
    "log"
    "os"

    "github.com/joho/godotenv"
    "project1/internal/api"
    "project1/db"
    "project1/internal/observability"

)

func main() {
	// 1. Load .env
	if err := godotenv.Load(); err != nil {
		log.Println("No .env file, using system env")
	}

	// 2. Init Prometheus metrics
	observability.Init()

	// 3. Init structured logger (Zap)
	observability.InitLogger()
	defer observability.Logger.Sync()

	// 4. Connect DB
	db.Connect()

	// 5. Setup router & jalankan
	r := api.SetupRouter()

	port := os.Getenv("APP_PORT")
	if port == "" {
		port = "8080"
	}

	r.Run(":" + port)
}