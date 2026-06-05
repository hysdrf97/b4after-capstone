package api

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"time"

	"project1/db"
	"project1/internal/model"

	"github.com/gin-gonic/gin"
	amqp "github.com/rabbitmq/amqp091-go"
)

func GetUser(c *gin.Context) {
	id := c.Param("id")
	ctx := context.Background()
	cacheKey := "user:" + id

	cached, err := db.RedisClient.Get(ctx, cacheKey).Result()
	if err == nil {
		var user model.User
		json.Unmarshal([]byte(cached), &user)
		c.Header("X-Cache", "HIT")
		c.JSON(http.StatusOK, user)
		return
	}

	// ✅ Pakai Replica untuk READ
	readDB := db.DBReplica
	if readDB == nil {
		readDB = db.DB
	}

	var user model.User
	err = readDB.Get(&user, "SELECT * FROM users WHERE id=$1", id)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "User not found"})
		return
	}

	data, _ := json.Marshal(user)
	db.RedisClient.Set(ctx, cacheKey, data, 60*time.Second)
	c.Header("X-Cache", "MISS")
	c.JSON(http.StatusOK, user)
}

func GetTransaction(c *gin.Context) {
	id := c.Param("id")
	ctx := context.Background()
	cacheKey := "transaction:" + id

	cached, err := db.RedisClient.Get(ctx, cacheKey).Result()
	if err == nil {
		var tx model.Transaction
		json.Unmarshal([]byte(cached), &tx)
		c.Header("X-Cache", "HIT")
		c.JSON(http.StatusOK, tx)
		return
	}

	// ✅ Pakai Replica untuk READ
	readDB := db.DBReplica
	if readDB == nil {
		readDB = db.DB
	}

	var tx model.Transaction
	err = readDB.Get(&tx, "SELECT * FROM transactions WHERE id=$1", id)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "Transaction not found"})
		return
	}

	data, _ := json.Marshal(tx)
	db.RedisClient.Set(ctx, cacheKey, data, 60*time.Second)
	c.Header("X-Cache", "MISS")
	c.JSON(http.StatusOK, tx)
}

func CreateTransaction(c *gin.Context) {
	var tx model.Transaction
	if err := c.ShouldBindJSON(&tx); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	if tx.Type != "credit" && tx.Type != "debit" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "type must be 'credit' or 'debit'"})
		return
	}

	tx.Status = "pending"
	body, _ := json.Marshal(tx)

	err := db.RabbitCh.Publish(
		"", "transactions", false, false,
		amqp.Publishing{
			ContentType: "application/json",
			Body:        body,
		},
	)
	if err != nil {
		// ✅ Fallback INSERT tetap pakai Primary (write)
		db.DB.Exec(
			`INSERT INTO transactions(user_id, type, amount, status) VALUES($1, $2, $3, $4)`,
			tx.UserID, tx.Type, tx.Amount, tx.Status,
		)
	}

	c.JSON(http.StatusCreated, gin.H{"message": "Transaction created"})
}

func HealthCheck(c *gin.Context) {
	c.JSON(200, gin.H{
		"status":      "ok",
		"instance_id": os.Getenv("INSTANCE_ID"),
	})
}
