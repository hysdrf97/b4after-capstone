package db

import (
    "fmt"
    "log"
    "os"

    "github.com/jmoiron/sqlx"
    _ "github.com/lib/pq"
    "github.com/redis/go-redis/v9"
    amqp "github.com/rabbitmq/amqp091-go"
)

var DB        *sqlx.DB // Primary — write
var DBReplica *sqlx.DB // Replica — read
var RedisClient *redis.Client
var RabbitMQ *amqp.Connection
var RabbitCh *amqp.Channel

func Connect() {
    // PostgreSQL Primary (write)
    dsnPrimary := fmt.Sprintf(
        "host=%s port=5432 user=%s password=%s dbname=%s sslmode=disable",
        os.Getenv("DB_HOST"),
        os.Getenv("DB_USER"),
        os.Getenv("DB_PASSWORD"),
        os.Getenv("DB_NAME"),
    )
    var err error
    DB, err = sqlx.Connect("postgres", dsnPrimary)
    if err != nil {
        log.Fatal("Failed to connect to primary database:", err)
    }
    DB.SetMaxOpenConns(50)
    DB.SetMaxIdleConns(10)
    log.Println("Primary database connected!")

    // PostgreSQL Replica (read)
    dsnReplica := fmt.Sprintf(
        "host=%s port=5432 user=%s password=%s dbname=%s sslmode=disable",
        os.Getenv("DB_REPLICA_HOST"),
        os.Getenv("DB_USER"),
        os.Getenv("DB_PASSWORD"),
        os.Getenv("DB_NAME"),
    )
    DBReplica, err = sqlx.Connect("postgres", dsnReplica)
    if err != nil {
        log.Println("Warning: failed to connect to replica, falling back to primary:", err)
        DBReplica = DB // fallback ke primary kalau replica tidak tersedia
    } else {
        DBReplica.SetMaxOpenConns(50)
        DBReplica.SetMaxIdleConns(10)
        log.Println("Replica database connected!")
    }

    // Redis
    RedisClient = redis.NewClient(&redis.Options{
        Addr: fmt.Sprintf("%s:%s", os.Getenv("REDIS_HOST"), os.Getenv("REDIS_PORT")),
    })
    log.Println("Redis connected!")

    // RabbitMQ
    RabbitMQ, err = amqp.Dial(os.Getenv("RABBITMQ_URL"))
    if err != nil {
        log.Fatal("Failed to connect to RabbitMQ:", err)
    }
    RabbitCh, err = RabbitMQ.Channel()
    if err != nil {
        log.Fatal("Failed to open RabbitMQ channel:", err)
    }
    _, err = RabbitCh.QueueDeclare("transactions", true, false, false, false, nil)
    if err != nil {
        log.Fatal("Failed to declare queue:", err)
    }
    log.Println("RabbitMQ connected!")
}
