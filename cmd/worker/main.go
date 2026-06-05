package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"

	"project1/internal/model"

	"github.com/jmoiron/sqlx"
	_ "github.com/lib/pq"
	amqp "github.com/rabbitmq/amqp091-go"
)

func main() {
	// Connect PostgreSQL
	dsn := fmt.Sprintf(
		"host=%s port=5432 user=%s password=%s dbname=%s sslmode=disable",
		os.Getenv("DB_HOST"),
		os.Getenv("DB_USER"),
		os.Getenv("DB_PASSWORD"),
		os.Getenv("DB_NAME"),
	)
	db, err := sqlx.Connect("postgres", dsn)
	if err != nil {
		log.Fatal("Worker: failed to connect to database:", err)
	}
	defer db.Close()
	log.Println("Worker: database connected!")

	// Connect RabbitMQ
	conn, err := amqp.Dial(os.Getenv("RABBITMQ_URL"))
	if err != nil {
		log.Fatal("Worker: failed to connect to RabbitMQ:", err)
	}
	defer conn.Close()

	ch, err := conn.Channel()
	if err != nil {
		log.Fatal("Worker: failed to open channel:", err)
	}
	defer ch.Close()

	// Declare queue (idempotent)
	_, err = ch.QueueDeclare("transactions", true, false, false, false, nil)
	if err != nil {
		log.Fatal("Worker: failed to declare queue:", err)
	}

	// Set prefetch — proses 1 pesan per VU
	ch.Qos(1, 0, false)

	msgs, err := ch.Consume("transactions", "worker", false, false, false, false, nil)
	if err != nil {
		log.Fatal("Worker: failed to consume:", err)
	}

	log.Println("Worker: waiting for messages...")

	for msg := range msgs {
		var tx model.Transaction
		if err := json.Unmarshal(msg.Body, &tx); err != nil {
			log.Println("Worker: failed to parse message:", err)
			msg.Nack(false, false)
			continue
		}

		_, err := db.Exec(
			`INSERT INTO transactions(user_id, type, amount, status) VALUES($1, $2, $3, $4)`,
			tx.UserID, tx.Type, tx.Amount, tx.Status,
		)
		if err != nil {
			log.Println("Worker: failed to insert transaction:", err)
			msg.Nack(false, true) // requeue
			continue
		}

		msg.Ack(false)
		log.Printf("Worker: transaction saved — user_id=%d type=%s amount=%.0f\n",
			tx.UserID, tx.Type, tx.Amount)
	}
}
