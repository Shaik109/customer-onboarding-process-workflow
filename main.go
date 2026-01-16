package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/lib/pq"
	"github.com/segmentio/kafka-go"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
)

type Caf struct {
	ID             uint           `gorm:"primaryKey" json:"id"`
	CafRefNo       string         `gorm:"unique;not null" json:"caf_ref_no"`
	PlanCode       string         `json:"plan_code"`
	IsUsim         bool           `json:"is_usim"`
	Imsi           sql.NullString `json:"imsi"`
	PermanentImsi  sql.NullString `json:"permanent_imsi"`
	PosHrno        string         `json:"pos_hrno"`
	ZoneCode       string         `json:"zone_code"`
	Status         string         `json:"status"`
	IsAgent        bool           `json:"is_agent"`
	CurrentStep    int            `json:"current_step"`
	CreatedAt      time.Time      `json:"created_at"`
	UpdatedAt      time.Time      `json:"updated_at"`
}

type ZoneConfig struct {
	ZoneCode       string `gorm:"primaryKey" json:"zone_code"`
	PreactMode     string `json:"preact_mode"`
	TvMode         string `json:"tv_mode"`
	FinalactMode   string `json:"finalact_mode"`
	CommissionMode string `json:"commission_mode"`
}

type IntegrationOutbox struct {
	ID            uint      `gorm:"primaryKey" json:"id"`
	CafID         uint      `json:"caf_id"`
	Target        string    `json:"target"`
	Mode          string    `json:"mode"`
	CorrelationID string    `gorm:"unique" json:"correlation_id"`
	Payload       string    `json:"payload"`
	Status        string    `json:"status"`
	Attempts      int       `json:"attempts"`
	CreatedAt     time.Time `json:"created_at"`
}

type OnboardingService struct {
	DB *gorm.DB
}

func NewOnboardingService() *OnboardingService {
	dsn := "host=localhost user=flowable password=flowable dbname=onboarding port=5432 sslmode=disable"
	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{})
	if err != nil {
		panic("Failed to connect database")
	}

	// Auto migrate
	db.AutoMigrate(&Caf{}, &ZoneConfig{}, &IntegrationOutbox{})

	// Seed zone config
	var count int64
	db.Model(&ZoneConfig{}).Count(&count)
	if count == 0 {
		db.Create(&ZoneConfig{ZoneCode: "NORTH", PreactMode: "API", TvMode: "DBLINK", FinalactMode: "API", CommissionMode: "DBLINK"})
		db.Create(&ZoneConfig{ZoneCode: "SOUTH", PreactMode: "DBLINK", TvMode: "API", FinalactMode: "DBLINK", CommissionMode: "API"})
	}

	return &OnboardingService{DB: db}
}

// ===== STEP 1: Kafka CAF Processing =====
func (s *OnboardingService) Step1ProcessKafkaCAF(cafData map[string]interface{}) error {
	planCode := cafData["plan_code"].(string)
	isUsim := strings.Contains(strings.ToUpper(planCode), "USIM")

	caf := Caf{
		CafRefNo:    cafData["caf_ref_no"].(string),
		PlanCode:    planCode,
		IsUsim:      isUsim,
		PosHrno:     cafData["pos_hrno"].(string),
		ZoneCode:    cafData["zone_code"].(string),
		IsAgent:     cafData["is_agent"].(bool),
		Status:      "PENDING_APPROVAL",
		CurrentStep: 1,
	}

	// USIM: PyIOTA API
	if isUsim {
		permanentIMSI := s.mockPyIOTA(planCode)
		caf.PermanentImsi = sql.NullString{String: permanentIMSI, Valid: true}
	} else {
		caf.Imsi = sql.NullString{String: cafData["imsi"].(string), Valid: true}
	}

	// Idempotent insert
	return s.DB.Where("caf_ref_no = ?", caf.CafRefNo).FirstOrCreate(&caf).Error
}

func (s *OnboardingService) mockPyIOTA(planCode string) string {
	// Mock external API
	time.Sleep(100 * time.Millisecond)
	return fmt.Sprintf("IMSI-%s-%d", strings.ReplaceAll(planCode, "PLAN-", ""), time.Now().UnixNano())
}

// ===== STEP 2: CSC Approval =====
func (s *OnboardingService) Step2CSCApproval(cafRefNo string, approved bool, cscUser string) error {
	var caf Caf
	if err := s.DB.Where("caf_ref_no = ?", cafRefNo).First(&caf).Error; err != nil {
		return err
	}

	if !approved {
		caf.Status = "REJECTED"
		caf.CurrentStep = 0
	} else {
		caf.Status = "APPROVED"
		caf.CurrentStep = 2
	}

	return s.DB.Save(&caf).Error
}

// ===== STEP 3: Pre-activation =====
func (s *OnboardingService) Step3PreActivation(cafRefNo string) error {
	var caf Caf
	s.DB.Where("caf_ref_no = ?", cafRefNo).First(&caf)

	var config ZoneConfig
	s.DB.Where("zone_code = ?", caf.ZoneCode).First(&config)

	corrID := fmt.Sprintf("PRE-%s-%d", cafRefNo, time.Now().UnixNano())
	payload := map[string]interface{}{
		"caf_ref_no":  caf.CafRefNo,
		"imsi":        s.getIMSI(caf),
		"zone_code":   caf.ZoneCode,
		"callback_url": fmt.Sprintf("http://localhost:3000/callback/preact/%s", corrID),
	}
	payloadJSON, _ := json.Marshal(payload)

	outbox := IntegrationOutbox{
		CafID:         caf.ID,
		Target:        "PREACT",
		Mode:          config.PreactMode,
		CorrelationID: corrID,
		Payload:       string(payloadJSON),
		Status:        "PENDING",
	}

	caf.Status = "PREACT_SENT"
	caf.CurrentStep = 3

	return s.DB.Transaction(func(tx *gorm.DB) error {
		tx.Create(&outbox)
		return tx.Save(&caf).Error
	})
}

func (s *OnboardingService) getIMSI(caf Caf) string {
	if caf.IsUsim && caf.PermanentImsi.Valid {
		return caf.PermanentImsi.String
	}
	if caf.Imsi.Valid {
		return caf.Imsi.String
	}
	return ""
}

// ===== STEP 4: Pre-activation ACK =====
func (s *OnboardingService) Step4PreActivationAck(corrID, ackStatus, cafRefNo string) error {
	var outbox IntegrationOutbox
	s.DB.Where("correlation_id = ? AND target = ?", corrID, "PREACT").First(&outbox)
	outbox.Status = "ACKED"

	var caf Caf
	s.DB.Where("caf_ref_no = ?", cafRefNo).First(&caf)

	if ackStatus == "SUCCESS" {
		caf.Status = "PREACT_DONE"
		caf.CurrentStep = 4
	} else {
		caf.Status = "PREACT_FAILED"
		caf.CurrentStep = 0
	}

	return s.DB.Transaction(func(tx *gorm.DB) error {
		tx.Save(&outbox)
		return tx.Save(&caf).Error
	})
}

// ===== STEP 5-6: Televerification =====
func (s *OnboardingService) Step5TeleVerification(cafRefNo string) error {
	var caf Caf
	s.DB.Where("caf_ref_no = ?", cafRefNo).First(&caf)

	var config ZoneConfig
	s.DB.Where("zone_code = ?", caf.ZoneCode).First(&config)

	corrID := fmt.Sprintf("TV-%s-%d", cafRefNo, time.Now().UnixNano())
	payload := map[string]interface{}{
		"caf_ref_no": caf.CafRefNo,
		"zone_code":  caf.ZoneCode,
	}
	payloadJSON, _ := json.Marshal(payload)

	outbox := IntegrationOutbox{
		CafID:         caf.ID,
		Target:        "TV",
		Mode:          config.TvMode,
		CorrelationID: corrID,
		Payload:       string(payloadJSON),
		Status:        "PENDING",
	}

	caf.Status = "TV_SENT"
	caf.CurrentStep = 5

	return s.DB.Transaction(func(tx *gorm.DB) error {
		tx.Create(&outbox)
		return tx.Save(&caf).Error
	})
}

func (s *OnboardingService) Step6TeleVerificationAck(corrID, ackStatus, cafRefNo string) error {
	var caf Caf
	s.DB.Where("caf_ref_no = ?", cafRefNo).First(&caf)

	if ackStatus == "SUCCESS" {
		caf.Status = "TV_DONE"
		caf.CurrentStep = 6
	} else {
		caf.Status = "TV_FAILED"
		caf.CurrentStep = 0
	}

	return s.DB.Save(&caf).Error
}

// ===== STEP 7-8: Final Activation =====
func (s *OnboardingService) Step7FinalActivation(cafRefNo string) error {
	var caf Caf
	s.DB.Where("caf_ref_no = ?", cafRefNo).First(&caf)

	var config ZoneConfig
	s.DB.Where("zone_code = ?", caf.ZoneCode).First(&config)

	corrID := fmt.Sprintf("FINAL-%s-%d", cafRefNo, time.Now().UnixNano())
	payload := map[string]interface{}{
		"caf_ref_no": caf.CafRefNo,
		"imsi":       s.getIMSI(caf),
	}
	payloadJSON, _ := json.Marshal(payload)

	outbox := IntegrationOutbox{
		CafID:         caf.ID,
		Target:        "FINALACT",
		Mode:          config.FinalactMode,
		CorrelationID: corrID,
		Payload:       string(payloadJSON),
		Status:        "PENDING",
	}

	caf.Status = "FINALACT_SENT"
	caf.CurrentStep = 7

	return s.DB.Transaction(func(tx *gorm.DB) error {
		tx.Create(&outbox)
		return tx.Save(&caf).Error
	})
}

func (s *OnboardingService) Step8FinalActivationAck(corrID, ackStatus, cafRefNo string) error {
	var caf Caf
	s.DB.Where("caf_ref_no = ?", cafRefNo).First(&caf)

	if ackStatus == "SUCCESS" {
		caf.Status = "FINALACT_DONE"
		caf.CurrentStep = 8
		return s.Step9SancharsoftCommission(cafRefNo)
	}
	caf.Status = "FINALACT_FAILED"
	caf.CurrentStep = 0
	return s.DB.Save(&caf).Error
}

// ===== STEP 9: Sancharsoft Commission =====
func (s *OnboardingService) Step9SancharsoftCommission(cafRefNo string) error {
	var caf Caf
	s.DB.Where("caf_ref_no = ?", cafRefNo).First(&caf)

	if !caf.IsAgent {
		caf.Status = "COMPLETED"
		caf.CurrentStep = 9
		return s.DB.Save(&caf).Error
	}

	var config ZoneConfig
	s.DB.Where("zone_code = ?", caf.ZoneCode).First(&config)

	corrID := fmt.Sprintf("COMM-%s-%d", cafRefNo, time.Now().UnixNano())
	payload := map[string]interface{}{
		"caf_ref_no": caf.CafRefNo,
		"agent":      true,
	}
	payloadJSON, _ := json.Marshal(payload)

	outbox := IntegrationOutbox{
		CafID:         caf.ID,
		Target:        "COMMISSION",
		Mode:          config.CommissionMode,
		CorrelationID: corrID,
		Payload:       string(payloadJSON),
		Status:        "PENDING",
	}

	caf.Status = "COMMISSION_SENT"
	caf.CurrentStep = 9

	return s.DB.Transaction(func(tx *gorm.DB) error {
		tx.Create(&outbox)
		return tx.Save(&caf).Error
	})
}

// ===== HTTP HANDLER =====
type Handler struct {
	service *OnboardingService
}

func (h *Handler) CSCApproval(c *gin.Context) {
	var req struct {
		Approved bool   `json:"approved"`
		User     string `json:"user"`
	}
	cafRefNo := c.Param("caf_ref_no")

	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(400, gin.H{"error": err.Error()})
		return
	}

	if err := h.service.Step2CSCApproval(cafRefNo, req.Approved, req.User); err != nil {
		c.JSON(500, gin.H{"error": err.Error()})
		return
	}

	c.JSON(200, gin.H{"message": "Approval processed", "caf_ref_no": cafRefNo})
}

func (h *Handler) NextStep(c *gin.Context) {
	cafRefNo := c.Param("caf_ref_no")
	
	var caf Caf
	h.service.DB.Where("caf_ref_no = ?", cafRefNo).First(&caf)

	switch caf.CurrentStep {
	case 2: // After approval
		h.service.Step3PreActivation(cafRefNo)
	case 4: // After preact
		h.service.Step5TeleVerification(cafRefNo)
	case 6: // After TV
		h.service.Step7FinalActivation(cafRefNo)
	default:
		c.JSON(400, gin.H{"error": "No next step available"})
		return
	}
	c.JSON(200, gin.H{"message": "Next step triggered"})
}

func (h *Handler) PreActivationAck(c *gin.Context) {
	corrID := c.Param("corr_id")
	var req struct {
		CafRefNo  string `json:"caf_ref_no"`
		AckStatus string `json:"ack_status"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(400, gin.H{"error": err.Error()})
		return
	}
	h.service.Step4PreActivationAck(corrID, req.AckStatus, req.CafRefNo)
	c.JSON(200, gin.H{"message": "Pre-activation ACK received"})
}

func (h *Handler) TeleVerificationAck(c *gin.Context) {
	corrID := c.Param("corr_id")
	var req struct {
		CafRefNo  string `json:"caf_ref_no"`
		AckStatus string `json:"ack_status"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(400, gin.H{"error": err.Error()})
		return
	}
	h.service.Step6TeleVerificationAck(corrID, req.AckStatus, req.CafRefNo)
	c.JSON(200, gin.H{"message": "TV ACK received"})
}

func (h *Handler) FinalActivationAck(c *gin.Context) {
	corrID := c.Param("corr_id")
	var req struct {
		CafRefNo  string `json:"caf_ref_no"`
		AckStatus string `json:"ack_status"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(400, gin.H{"error": err.Error()})
		return
	}
	h.service.Step8FinalActivationAck(corrID, req.AckStatus, req.CafRefNo)
	c.JSON(200, gin.H{"message": "Final activation ACK received"})
}

// ===== MAIN =====
func main() {
	service := NewOnboardingService()
	handler := &Handler{service: service}

	// Kafka Consumer (background)
	go func() {
		r := kafka.NewReader(kafka.ReaderConfig{
			Brokers:  []string{"localhost:9092"},
			Topic:    "caf-topic",
			GroupID:  "caf-group",
			MinBytes: 10e3,
			MaxBytes: 10e6,
		})
		defer r.Close()

		for {
			msg, err := r.ReadMessage(context.Background())
			if err != nil {
				log.Println("Kafka error:", err)
				continue
			}

			var cafData map[string]interface{}
			json.Unmarshal(msg.Value, &cafData)
			if err := service.Step1ProcessKafkaCAF(cafData); err != nil {
				log.Printf("CAF processing failed: %v", err)
			} else {
				log.Printf("✅ Step 1 COMPLETE: CAF %s -> PENDING_APPROVAL", cafData["caf_ref_no"])
			}
		}
	}()

	// HTTP Server
	r := gin.Default()
	r.GET("/health", func(c *gin.Context) { c.JSON(200, gin.H{"status": "OK"}) })
	r.GET("/caf/:caf_ref_no", func(c *gin.Context) {
		var caf Caf
		service.DB.Where("caf_ref_no = ?", c.Param("caf_ref_no")).First(&caf)
		c.JSON(200, caf)
	})
	r.POST("/caf/:caf_ref_no/approve", handler.CSCApproval)
	r.POST("/caf/:caf_ref_no/next", handler.NextStep)
	r.POST("/callback/preact/:corr_id", handler.PreActivationAck)
	r.POST("/callback/tv/:corr_id", handler.TeleVerificationAck)
	r.POST("/callback/final/:corr_id", handler.FinalActivationAck)

	log.Println("🚀 Server starting on :3000")
	r.Run(":3000")
}
