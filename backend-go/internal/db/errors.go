package db

import "errors"

// ErrNotFound is returned when an update or delete targets a row that does not exist.
var ErrNotFound = errors.New("db: record not found")
