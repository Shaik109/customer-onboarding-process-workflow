package main

import (
    "bytes"
    "context"
    "encoding/json"
    "fmt"
    "io"
    "log"
    "net/http"
    "strings"
    "time"

    "github.com/gin-gonic/gin"
    "github.com/segmentio/kafka-go"
    "gorm.io/driver/postgres"
    "gorm.io/gorm"
)

type FlowableService struct {
    BaseURL string
    DB      *gorm.DB
}

// Flowable Delegate Service (called by BPMN ServiceTasks)
type OnboardingDelegate struct {
    db *gorm.DB
}

func (d *OnboardingDelegate) Step1ProcessKafkaCAF(execution *FlowableExecution) {
    cafData := execution.Variables["cafData"].(map[string]interface{})
    
    // Same logic as before but sets process variables
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
    
    if isUsim {
        caf.PermanentImsi = sql.NullString{String: "IMSI-MOCK", Valid: true}
    } else {
        caf.Imsi = sql.NullString{String: cafData["imsi"].(string), Valid: true}
    }
    
    d.db.Where("caf_ref_no = ?", caf.CafRefNo).FirstOrCreate(&caf)
    
    // Set Flowable process variables
    execution.Variables["cafId"] = caf.ID
    execution.Variables["cafRefNo"] = caf.CafRefNo
}

func main() {
    // PostgreSQL
    db, _ := gorm.Open(postgres.Open("host=localhost user=flowable password=flowable dbname=onboarding port=5432"), &gorm.Config{})
    db.AutoMigrate(&Caf{}, &ZoneConfig{}, &IntegrationOutbox{})

    // Flowable REST Client
    flowableSvc := &FlowableService{
        BaseURL: "http://localhost:8081/flowable-rest/service",
        DB:      db,
    }

    // Kafka Consumer -> Start Flowable Process
    go func() {
        r := kafka.NewReader(kafka.ReaderConfig{
            Brokers: []string{"localhost:9092"},
            Topic:   "caf-topic",
            GroupID: "caf-group",
        })
        defer r.Close()

        for {
            msg, err := r.ReadMessage(context.Background())
            if err != nil {
                continue
            }

            var cafData map[string]interface{}
            json.Unmarshal(msg.Value, &cafData)
            
            // START FLOWABLE PROCESS
            processVars := map[string]interface{}{
                "cafData": cafData,
                "businessKey": cafData["caf_ref_no"],
            }
            
            instanceID, err := flowableSvc.StartProcess("cafOnboarding", processVars)
            if err != nil {
                log.Printf("Failed to start Flowable process: %v", err)
                continue
            }
            
            log.Printf("✅ Flowable Process Started: %s for CAF %s", instanceID, cafData["caf_ref_no"])
        }
    }()

    // HTTP API for CSC Approval & Callbacks
    r := gin.Default()
    
    // CSC Approval (completes Flowable UserTask)
    r.POST("/caf/:ref/approve", func(c *gin.Context) {
        ref := c.Param("ref")
        var req struct{ Approved bool; User string }
        c.BindJSON(&req)
        
        // Complete Flowable task
        taskID, _ := flowableSvc.GetTaskForCAF(ref)
        if taskID != "" {
            vars := map[string]interface{}{"approved": req.Approved}
            flowableSvc.CompleteTask(taskID, vars)
        }
        
        c.JSON(200, gin.H{"message": "CSC Approval processed"})
    })

    // External Callbacks (send Flowable Signals)
    r.POST("/callback/:target/:corr", func(c *gin.Context) {
        target := c.Param("target")
        corr := c.Param("corr")
        var req struct{ CafRefNo string; AckStatus string }
        c.BindJSON(&req)
        
        // Send signal to Flowable
        signalName := fmt.Sprintf("%sAckSignal", strings.ToUpper(target))
        flowableSvc.SignalProcess(req.CafRefNo, signalName, gin.H{
            "ackStatus": req.AckStatus,
            "cafRefNo":  req.CafRefNo,
        })
        
        c.JSON(200, gin.H{"message": fmt.Sprintf("%s ACK received", target)})
    })

    r.Run(":3000")
}

// Flowable REST API Calls
func (f *FlowableService) StartProcess(processKey string, vars map[string]interface{}) (string, error) {
    payload := map[string]interface{}{
        "processDefinitionKey": processKey,
        "variables":            vars,
    }
    
    body, _ := json.Marshal(payload)
    resp, err := http.Post(f.BaseURL+"/runtime/process-instances", "application/json", bytes.NewBuffer(body))
    if err != nil {
        return "", err
    }
    defer resp.Body.Close()
    
    var result map[string]interface{}
    json.NewDecoder(resp.Body).Decode(&result)
    return result["id"].(string), nil
}

func (f *FlowableService) CompleteTask(taskID, vars map[string]interface{}) error {
    payload, _ := json.Marshal(vars)
    _, err := http.Post(fmt.Sprintf("%s/task/%s/complete", f.BaseURL, taskID), 
        "application/json", bytes.NewBuffer(payload))
    return err
}

func (f *FlowableService) SignalProcess(businessKey, signalName string, vars map[string]interface{}) error {
    // Find process instance by business key
    url := fmt.Sprintf("%s/runtime/process-instances?businessKey=%s", f.BaseURL, businessKey)
    resp, _ := http.Get(url)
    defer resp.Body.Close()
    
    // Send signal
    signalPayload := map[string]interface{}{
        "signalName": signalName,
        "variables":  vars,
    }
    body, _ := json.Marshal(signalPayload)
    
    processInstances, _ := f.getJSON(resp.Body)
    if len(processInstances.([]interface{})) > 0 {
        instanceID := processInstances.([]interface{})[0].(map[string]interface{})["id"].(string)
        http.Post(fmt.Sprintf("%s/runtime/process-instances/%s/signal", f.BaseURL, instanceID),
            "application/json", bytes.NewBuffer(body))
    }
    return nil
}
