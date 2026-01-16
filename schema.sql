-- Connect: psql -h localhost -U flowable -d onboarding
-- DROP SCHEMA public CASCADE; CREATE SCHEMA public;

-- ===== 1. MAIN CAF TABLE (Business Data) =====
CREATE TABLE caf (
    id BIGSERIAL PRIMARY KEY,
    caf_ref_no VARCHAR(50) UNIQUE NOT NULL,
    process_instance_id VARCHAR(64) UNIQUE,  -- Links to Flowable ACT_RU_EXECUTION.ID_
    plan_code VARCHAR(20),
    is_usim BOOLEAN NOT NULL DEFAULT false,
    imsi VARCHAR(20),
    permanent_imsi VARCHAR(20),
    pos_hrno VARCHAR(20) NOT NULL,
    zone_code VARCHAR(10) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'RECEIVED',
    is_agent BOOLEAN NOT NULL DEFAULT false,
    current_step INTEGER NOT NULL DEFAULT 1 CHECK (current_step BETWEEN 0 AND 9),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Flowable integration indexes
CREATE INDEX idx_caf_process_instance ON caf(process_instance_id);
CREATE INDEX idx_caf_status_step ON caf(status, current_step);
CREATE INDEX idx_caf_zone ON caf(zone_code);

-- ===== 2. ZONE INTEGRATION CONFIG (Steps 3,5,7,9) =====
CREATE TABLE zone_config (
    zone_code VARCHAR(10) PRIMARY KEY,
    preact_mode VARCHAR(10) NOT NULL CHECK (preact_mode IN ('API', 'DBLINK')),
    tv_mode VARCHAR(10) NOT NULL CHECK (tv_mode IN ('API', 'DBLINK')),
    finalact_mode VARCHAR(10) NOT NULL CHECK (finalact_mode IN ('API', 'DBLINK')),
    commission_mode VARCHAR(10) NOT NULL CHECK (commission_mode IN ('API', 'DBLINK'))
);

-- Production zone data
INSERT INTO zone_config VALUES 
('NORTH', 'API', 'DBLINK', 'API', 'DBLINK'),
('SOUTH', 'DBLINK', 'API', 'DBLINK', 'API'),
('EAST', 'API', 'API', 'API', 'API'),
('WEST', 'DBLINK', 'DBLINK', 'DBLINK', 'API');

-- ===== 3. INTEGRATION OUTBOX (Reliable external calls) =====
CREATE TABLE integration_outbox (
    id BIGSERIAL PRIMARY KEY,
    caf_id BIGINT NOT NULL REFERENCES caf(id) ON DELETE CASCADE,
    process_instance_id VARCHAR(64),  -- Flowable process context
    target VARCHAR(20) NOT NULL CHECK (target IN ('PREACT', 'TV', 'FINALACT', 'COMMISSION')),
    mode VARCHAR(10) NOT NULL CHECK (mode IN ('API', 'DBLINK')),
    correlation_id VARCHAR(100) UNIQUE NOT NULL,
    callback_url VARCHAR(500),
    payload JSONB NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'SENT', 'ACKED', 'FAILED')),
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    last_error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_outbox_pending ON integration_outbox(status) WHERE status = 'PENDING';
CREATE INDEX idx_outbox_caf_target ON integration_outbox(caf_id, target);
CREATE INDEX idx_outbox_correlation ON integration_outbox(correlation_id);

-- ===== 4. CALLBACK ACKNOWLEDGEMENTS (Steps 4,6,8) =====
CREATE TABLE integration_ack (
    id BIGSERIAL PRIMARY KEY,
    correlation_id VARCHAR(100) UNIQUE NOT NULL REFERENCES integration_outbox(correlation_id),
    caf_ref_no VARCHAR(50) NOT NULL REFERENCES caf(caf_ref_no),
    process_instance_id VARCHAR(64),
    target VARCHAR(20) NOT NULL,
    ack_status VARCHAR(20) NOT NULL CHECK (ack_status IN ('SUCCESS', 'FAILED', 'REJECTED')),
    ack_payload JSONB,
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ===== 5. BUSINESS AUDIT TRAIL (Full traceability) =====
CREATE TABLE caf_audit (
    id BIGSERIAL PRIMARY KEY,
    caf_id BIGINT NOT NULL REFERENCES caf(id),
    process_instance_id VARCHAR(64),
    old_status VARCHAR(50),
    new_status VARCHAR(50) NOT NULL,
    step_number INTEGER,
    actor_type VARCHAR(20) NOT NULL,  -- KAFKA, CSC, FLOWABLE, TELCO, CCARE
    actor_id VARCHAR(50),
    flowable_task_id VARCHAR(64),     -- Links to Flowable task
    remarks TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ===== 6. STATUS TRANSITION TRIGGER =====
CREATE OR REPLACE FUNCTION audit_caf_status()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status OR OLD.current_step IS DISTINCT FROM NEW.current_step THEN
        INSERT INTO caf_audit (
            caf_id, process_instance_id, old_status, new_status, 
            step_number, actor_type, actor_id, flowable_task_id, remarks
        ) VALUES (
            NEW.id, NEW.process_instance_id, OLD.status, NEW.status,
            NEW.current_step, 'SYSTEM', current_user, NULL, 'Auto-tracked transition'
        );
    END IF;
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_caf_audit_status
    BEFORE UPDATE ON caf
    FOR EACH ROW EXECUTE FUNCTION audit_caf_status();

-- ===== 7. VIEWS FOR MONITORING =====
CREATE VIEW caf_dashboard AS
SELECT 
    c.*,
    z.preact_mode, z.tv_mode, z.finalact_mode, z.commission_mode,
    COALESCE(outbox_count.pending, 0) as pending_integrations,
    COALESCE(audit_count.total, 0) as audit_entries,
    io.status as outbox_status
FROM caf c
LEFT JOIN zone_config z ON c.zone_code = z.zone_code
LEFT JOIN LATERAL (
    SELECT COUNT(*) as pending 
    FROM integration_outbox io 
    WHERE io.caf_id = c.id AND io.status = 'PENDING'
) outbox_count ON true
LEFT JOIN LATERAL (
    SELECT COUNT(*) as total 
    FROM caf_audit a 
    WHERE a.caf_id = c.id
) audit_count ON true
ORDER BY c.updated_at DESC;

CREATE VIEW pending_integrations AS
SELECT 
    o.*,
    c.caf_ref_no, c.zone_code, c.status,
    z.preact_mode, z.tv_mode
FROM integration_outbox o
JOIN caf c ON o.caf_id = c.id
LEFT JOIN zone_config z ON c.zone_code = z.zone_code
WHERE o.status = 'PENDING' AND o.attempts < 3
ORDER BY o.created_at;

-- ===== 8. WORKER JOB QUEUE (For integration processing) =====
CREATE TABLE worker_jobs (
    id BIGSERIAL PRIMARY KEY,
    outbox_id BIGINT REFERENCES integration_outbox(id),
    scheduled_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status VARCHAR(20) DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'RUNNING', 'SUCCESS', 'FAILED'))
);

-- ===== 9. Flowable Integration Helper Functions =====
CREATE OR REPLACE FUNCTION get_caf_by_process_instance(p_process_id VARCHAR)
RETURNS TABLE (
    caf_id BIGINT, caf_ref_no VARCHAR, status VARCHAR, current_step INTEGER
) AS $$
BEGIN
    RETURN QUERY
    SELECT c.id, c.caf_ref_no, c.status, c.current_step
    FROM caf c WHERE c.process_instance_id = p_process_id;
END;
$$ LANGUAGE plpgsql;

-- ===== 10. SAMPLE DATA FOR TESTING =====
INSERT INTO caf (caf_ref_no, process_instance_id, zone_code, is_agent, status) 
VALUES ('TEST001', 'test-process-1', 'NORTH', true, 'RECEIVED')
ON CONFLICT DO NOTHING;
