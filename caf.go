package models

import "time"

type Caf struct {
    ID                uint      `gorm:"primaryKey"`
    CafRefNo          string    `gorm:"unique"`
    Status            string
    ZoneCode          string
    PlanCode          string
    IsUsim            bool
    Imsi              string
    PermanentImsi     string
    PosHrno           string
    ProcessInstanceId string
    CreatedAt         time.Time
    UpdatedAt         time.Time
}

type ZoneConfig struct {
    ZoneCode     string `gorm:"primaryKey"`
    PreactMode   string
    TvMode       string
    FinalactMode string
    CommissionMode string
}
