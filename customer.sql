
-- Database: Flowable_db

-- DROP DATABASE IF EXISTS "Flowable_db";

CREATE DATABASE Flowable_db;
CREATE USER flowable_user WITH PASSWORD 'flowable123';
GRANT ALL PRIVILEGES ON DATABASE flowable_db TO flowable_user;
-- 0) Enums for clear states
CREATE TYPE caf_status AS ENUM (
  'RECEIVED',
  'PENDING_APPROVAL',
  'REJECTED',
  'APPROVED',
  'PREACT_SENT',
  'PREACT_DONE',
  'TV_SENT',
  'TV_DONE',
  'TV_FAILED',
  'FINALACT_SENT',
  'FINALACT_DONE',
  'COMMISSION_SENT',
  'COMPLETED',
  'FAILED'
);

CREATE TYPE integration_mode AS ENUM ('API', 'DBLINK');
CREATE TYPE integration_target AS ENUM ('TELCO_BILLING_PRE', 'CUSTOMER_CARE_TV', 'TELCO_BILLING_FINAL', 'SANCHARSOFT');

-- 1) Zone config (how each zone integrates)
CREATE TABLE zone_integration_config (
  zone_code        text PRIMARY KEY,
  preact_mode       integration_mode NOT NULL,
  tv_mode           integration_mode NOT NULL,
  finalact_mode     integration_mode NOT NULL,
  commission_mode   integration_mode NOT NULL,
  updated_at        timestamptz NOT NULL DEFAULT now()
);

-- 2) CAF master
CREATE TABLE caf (
  caf_id            bigserial PRIMARY KEY,
  caf_ref_no        text NOT NULL UNIQUE,
  plan_code         text NOT NULL,
  is_usim           boolean NOT NULL,
  imsi              text,                 -- from CAF submission (non-USIM)
  permanent_imsi    text,                 -- from PyIOTA (USIM)
  pos_hrno          text NOT NULL,
  zone_code         text NOT NULL,
  status            caf_status NOT NULL DEFAULT 'RECEIVED',
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

-- 3) Workflow audit trail (human approvals + system transitions)
CREATE TABLE caf_audit (
  audit_id          bigserial PRIMARY KEY,
  caf_id            bigint NOT NULL REFERENCES caf(caf_id),
  old_status        caf_status,
  new_status        caf_status NOT NULL,
  actor_type        text NOT NULL,  -- 'SYSTEM'/'CSC_USER'/'CALLBACK'
  actor_id          text,
  remarks           text,
  created_at        timestamptz NOT NULL DEFAULT now()
);

-- 4) Kafka idempotency (dedupe)
CREATE TABLE processed_message (
  subscriber_id     text NOT NULL,
  message_id        text NOT NULL,
  processed_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (subscriber_id, message_id)
);

-- 5) Outbox for outward integrations (API/DB link work)
CREATE TABLE integration_outbox (
  outbox_id         bigserial PRIMARY KEY,
  caf_id            bigint NOT NULL REFERENCES caf(caf_id),
  target            integration_target NOT NULL,
  zone_code         text NOT NULL,
  mode              integration_mode NOT NULL,
  correlation_id    text NOT NULL UNIQUE,         -- used for callback matching
  payload           jsonb NOT NULL,
  status            text NOT NULL DEFAULT 'NEW',   -- NEW/SENT/ERROR/DONE
  attempts          int NOT NULL DEFAULT 0,
  last_error        text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

-- 6) Inward acknowledgements (API callback or remote table sync)
CREATE TABLE integration_ack (
  ack_id            bigserial PRIMARY KEY,
  correlation_id    text NOT NULL UNIQUE,
  target            integration_target NOT NULL,
  caf_ref_no        text NOT NULL,
  ack_status        text NOT NULL,        -- SUCCESS/FAILURE
  ack_payload       jsonb NOT NULL DEFAULT '{}'::jsonb,
  received_at       timestamptz NOT NULL DEFAULT now()
);

-- Helpful indexes
CREATE INDEX caf_status_idx ON caf(status);
CREATE INDEX outbox_status_idx ON integration_outbox(status, target);
-- Utility: update timestamps
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

CREATE TRIGGER caf_set_updated_at
BEFORE UPDATE ON caf
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER outbox_set_updated_at
BEFORE UPDATE ON integration_outbox
FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- 1) Record transitions with audit
CREATE OR REPLACE FUNCTION caf_transition(
  p_caf_id bigint,
  p_new_status caf_status,
  p_actor_type text,
  p_actor_id text DEFAULT NULL,
  p_remarks text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_old caf_status;
BEGIN
  SELECT status INTO v_old FROM caf WHERE caf_id = p_caf_id FOR UPDATE;

  UPDATE caf
     SET status = p_new_status
   WHERE caf_id = p_caf_id;

  INSERT INTO caf_audit(caf_id, old_status, new_status, actor_type, actor_id, remarks)
  VALUES (p_caf_id, v_old, p_new_status, p_actor_type, p_actor_id, p_remarks);
END $$;


-- 2) Create an outbox job and notify workers
CREATE OR REPLACE FUNCTION enqueue_integration(
  p_caf_id bigint,
  p_target integration_target,
  p_mode integration_mode,
  p_payload jsonb,
  p_correlation_id text
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  v_zone text;
  v_outbox_id bigint;
BEGIN
  SELECT zone_code INTO v_zone FROM caf WHERE caf_id = p_caf_id;

  INSERT INTO integration_outbox(caf_id, target, zone_code, mode, payload, correlation_id)
  VALUES (p_caf_id, p_target, v_zone, p_mode, p_payload, p_correlation_id)
  RETURNING outbox_id INTO v_outbox_id;

  -- Wake up integration worker(s)
  PERFORM pg_notify('integration_outbox_new', p_target::text || ':' || p_correlation_id); -- async pub/sub [web:2]

  RETURN v_outbox_id;
END $$;


-- 3) Apply an inbound acknowledgement idempotently
CREATE OR REPLACE FUNCTION apply_ack(
  p_correlation_id text,
  p_target integration_target,
  p_caf_ref_no text,
  p_ack_status text,
  p_ack_payload jsonb DEFAULT '{}'::jsonb
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_caf_id bigint;
BEGIN
  -- idempotent insert (ignore retries)
  INSERT INTO integration_ack(correlation_id, target, caf_ref_no, ack_status, ack_payload)
  VALUES (p_correlation_id, p_target, p_caf_ref_no, p_ack_status, p_ack_payload)
  ON CONFLICT (correlation_id) DO NOTHING;

  SELECT caf_id INTO v_caf_id FROM caf WHERE caf_ref_no = p_caf_ref_no FOR UPDATE;

  IF p_target = 'TELCO_BILLING_PRE' AND p_ack_status = 'SUCCESS' THEN
    PERFORM caf_transition(v_caf_id, 'PREACT_DONE', 'CALLBACK', NULL, 'Pre-activation success');
  ELSIF p_target = 'CUSTOMER_CARE_TV' AND p_ack_status = 'SUCCESS' THEN
    PERFORM caf_transition(v_caf_id, 'TV_DONE', 'CALLBACK', NULL, 'Televerification success');
  ELSIF p_target = 'CUSTOMER_CARE_TV' AND p_ack_status <> 'SUCCESS' THEN
    PERFORM caf_transition(v_caf_id, 'TV_FAILED', 'CALLBACK', NULL, 'Televerification failed');
  ELSIF p_target = 'TELCO_BILLING_FINAL' AND p_ack_status = 'SUCCESS' THEN
    PERFORM caf_transition(v_caf_id, 'FINALACT_DONE', 'CALLBACK', NULL, 'Final activation success');
  END IF;

  PERFORM pg_notify('caf_status_changed', p_caf_ref_no); -- optional reactive pattern [web:2]
END $$;
-- Step 1: Kafka consumer calls this (after parsing message)
-- NOTE: Permanent IMSI fetch from PyIOTA must be done by app layer (HTTP call),
-- then pass the value here. DB should not do HTTP calls directly in core Postgres.
CREATE OR REPLACE FUNCTION kafkasub_caf_upsert(
  p_subscriber_id text,
  p_message_id text,
  p_caf_ref_no text,
  p_plan_code text,
  p_is_usim boolean,
  p_imsi text,
  p_permanent_imsi text,
  p_pos_hrno text,
  p_zone_code text
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  v_caf_id bigint;
BEGIN
  -- Dedupe Kafka message processing (Idempotent Consumer pattern) [page:0]
  INSERT INTO processed_message(subscriber_id, message_id)
  VALUES (p_subscriber_id, p_message_id)
  ON CONFLICT DO NOTHING;

  -- If it already existed, exit safely
  IF NOT FOUND THEN
    SELECT caf_id INTO v_caf_id FROM caf WHERE caf_ref_no = p_caf_ref_no;
    RETURN v_caf_id;
  END IF;

  INSERT INTO caf(caf_ref_no, plan_code, is_usim, imsi, permanent_imsi, pos_hrno, zone_code, status)
  VALUES (
    p_caf_ref_no,
    p_plan_code,
    p_is_usim,
    CASE WHEN p_is_usim THEN NULL ELSE p_imsi END,
    CASE WHEN p_is_usim THEN p_permanent_imsi ELSE NULL END,
    p_pos_hrno,
    p_zone_code,
    'PENDING_APPROVAL'
  )
  RETURNING caf_id INTO v_caf_id;

  INSERT INTO caf_audit(caf_id, old_status, new_status, actor_type, actor_id, remarks)
  VALUES (v_caf_id, NULL, 'PENDING_APPROVAL', 'SYSTEM', p_subscriber_id, 'CAF received from Kafka');

  RETURN v_caf_id;
END $$;


-- Step 2: CSC approval action
CREATE OR REPLACE FUNCTION csc_approve_caf(
  p_caf_ref_no text,
  p_csc_user text,
  p_approved boolean,
  p_remarks text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_caf_id bigint;
BEGIN
  SELECT caf_id INTO v_caf_id FROM caf WHERE caf_ref_no = p_caf_ref_no FOR UPDATE;

  IF p_approved THEN
    PERFORM caf_transition(v_caf_id, 'APPROVED', 'CSC_USER', p_csc_user, p_remarks);
  ELSE
    PERFORM caf_transition(v_caf_id, 'REJECTED', 'CSC_USER', p_csc_user, p_remarks);
  END IF;
END $$;


-- Step 3: enqueue pre-activation outward request
CREATE OR REPLACE FUNCTION start_preactivation(p_caf_ref_no text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_caf caf%ROWTYPE;
  v_cfg zone_integration_config%ROWTYPE;
  v_corr text;
BEGIN
  SELECT * INTO v_caf FROM caf WHERE caf_ref_no = p_caf_ref_no FOR UPDATE;
  IF v_caf.status <> 'APPROVED' THEN
    RAISE EXCEPTION 'CAF must be APPROVED to start preactivation, current=%', v_caf.status;
  END IF;

  SELECT * INTO v_cfg FROM zone_integration_config WHERE zone_code = v_caf.zone_code;
  v_corr := 'PRE-' || v_caf.caf_ref_no || '-' || extract(epoch from clock_timestamp())::bigint;

  PERFORM enqueue_integration(
    v_caf.caf_id,
    'TELCO_BILLING_PRE',
    v_cfg.preact_mode,
    jsonb_build_object(
      'cafRefNo', v_caf.caf_ref_no,
      'imsi', COALESCE(v_caf.permanent_imsi, v_caf.imsi),
      'zone', v_caf.zone_code
    ),
    v_corr
  );

  PERFORM caf_transition(v_caf.caf_id, 'PREACT_SENT', 'SYSTEM', NULL, 'Preactivation enqueued');
END $$;


-- Step 5: enqueue televerification
CREATE OR REPLACE FUNCTION start_televerification(p_caf_ref_no text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_caf caf%ROWTYPE;
  v_cfg zone_integration_config%ROWTYPE;
  v_corr text;
BEGIN
  SELECT * INTO v_caf FROM caf WHERE caf_ref_no = p_caf_ref_no FOR UPDATE;
  IF v_caf.status <> 'PREACT_DONE' THEN
    RAISE EXCEPTION 'CAF must be PREACT_DONE to start televerification, current=%', v_caf.status;
  END IF;

  SELECT * INTO v_cfg FROM zone_integration_config WHERE zone_code = v_caf.zone_code;
  v_corr := 'TV-' || v_caf.caf_ref_no || '-' || extract(epoch from clock_timestamp())::bigint;

  PERFORM enqueue_integration(
    v_caf.caf_id,
    'CUSTOMER_CARE_TV',
    v_cfg.tv_mode,
    jsonb_build_object(
      'cafRefNo', v_caf.caf_ref_no,
      'msisdn', NULL,
      'zone', v_caf.zone_code
    ),
    v_corr
  );

  PERFORM caf_transition(v_caf.caf_id, 'TV_SENT', 'SYSTEM', NULL, 'Televerification enqueued');
END $$;


-- Step 7: enqueue final activation (only if TV_DONE)
CREATE OR REPLACE FUNCTION start_final_activation(p_caf_ref_no text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_caf caf%ROWTYPE;
  v_cfg zone_integration_config%ROWTYPE;
  v_corr text;
BEGIN
  SELECT * INTO v_caf FROM caf WHERE caf_ref_no = p_caf_ref_no FOR UPDATE;
  IF v_caf.status <> 'TV_DONE' THEN
    RAISE EXCEPTION 'CAF must be TV_DONE to start final activation, current=%', v_caf.status;
  END IF;

  SELECT * INTO v_cfg FROM zone_integration_config WHERE zone_code = v_caf.zone_code;
  v_corr := 'FIN-' || v_caf.caf_ref_no || '-' || extract(epoch from clock_timestamp())::bigint;

  PERFORM enqueue_integration(
    v_caf.caf_id,
    'TELCO_BILLING_FINAL',
    v_cfg.finalact_mode,
    jsonb_build_object(
      'cafRefNo', v_caf.caf_ref_no,
      'imsi', COALESCE(v_caf.permanent_imsi, v_caf.imsi),
      'zone', v_caf.zone_code
    ),
    v_corr
  );

  PERFORM caf_transition(v_caf.caf_id, 'FINALACT_SENT', 'SYSTEM', NULL, 'Final activation enqueued');
END $$;


-- Step 9: commission (agent-only; call this only if applicable)
CREATE OR REPLACE FUNCTION start_commission(p_caf_ref_no text, p_is_agent boolean)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_caf caf%ROWTYPE;
  v_cfg zone_integration_config%ROWTYPE;
  v_corr text;
BEGIN
  IF NOT p_is_agent THEN
    RETURN;
  END IF;

  SELECT * INTO v_caf FROM caf WHERE caf_ref_no = p_caf_ref_no FOR UPDATE;
  IF v_caf.status <> 'FINALACT_DONE' THEN
    RAISE EXCEPTION 'CAF must be FINALACT_DONE to start commission, current=%', v_caf.status;
  END IF;

  SELECT * INTO v_cfg FROM zone_integration_config WHERE zone_code = v_caf.zone_code;
  v_corr := 'COM-' || v_caf.caf_ref_no || '-' || extract(epoch from clock_timestamp())::bigint;

  PERFORM enqueue_integration(
    v_caf.caf_id,
    'SANCHARSOFT',
    v_cfg.commission_mode,
    jsonb_build_object('cafRefNo', v_caf.caf_ref_no, 'zone', v_caf.zone_code),
    v_corr
  );

  PERFORM caf_transition(v_caf.caf_id, 'COMMISSION_SENT', 'SYSTEM', NULL, 'Commission enqueued');
END $$;



    