// Listens Kafka → Calls Flowable → Starts process
package main

import (
    "context"
    "encoding/json"
    "github.com/segmentio/kafka-go"
    "your-module/internal/services"
)

func main() {
    r := kafka.NewReader(kafka.ReaderConfig{
        Brokers: []string{"localhost:9092"},
        Topic:   "caf-topic",
        GroupID: "caf-group",
    })
    defer r.Close()
    
    svc := services.NewCafService(db, flowableClient)
    
    for {
        msg, err := r.ReadMessage(context.Background())
        if err != nil { continue }
        
        var cafData map[string]interface{}
        json.Unmarshal(msg.Value, &cafData)
        
        // Delegate to Flowable service task
        svc.TriggerProcessStart(cafData)
    }
}
