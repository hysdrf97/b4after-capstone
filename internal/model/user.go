package model

import "time"

type User struct {
    ID        int64     `db:"id"         json:"id"`
    Name      string    `db:"name"       json:"name"`
    Email     string    `db:"email"      json:"email"`
    Balance   float64   `db:"balance"    json:"balance"`
    CreatedAt time.Time `db:"created_at" json:"created_at"`
}