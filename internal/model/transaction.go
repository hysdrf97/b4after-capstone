package model

import "time"

type Transaction struct {
    ID          int64     `db:"id"           json:"id"`
    UserID      int64     `db:"user_id"      json:"user_id"`
    Type        string    `db:"type"         json:"type"`    // "credit" / "debit"
    Amount      float64   `db:"amount"       json:"amount"`
    Status      string    `db:"status"       json:"status"`
    ReferenceID string    `db:"reference_id" json:"reference_id"`
    CreatedAt   time.Time `db:"created_at"   json:"created_at"`
}