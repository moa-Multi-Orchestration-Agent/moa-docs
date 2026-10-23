-- MOA 물리 스키마 (PostgreSQL 16)
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

-- ===== 열거형 =====
CREATE TYPE member_role   AS ENUM ('owner','admin','maker','viewer');
CREATE TYPE block_role    AS ENUM ('system','memory','knowledge','tool','history','user','summary');
CREATE TYPE run_status    AS ENUM ('queued','running','waiting_approval','succeeded','failed','canceled');
CREATE TYPE run_trigger   AS ENUM ('editor','api','schedule','slash','market');
CREATE TYPE invoke_mode   AS ENUM ('sync','async');
CREATE TYPE memory_kind   AS ENUM ('long','episodic');
CREATE TYPE mcp_transport AS ENUM ('stdio','sse','http');
CREATE TYPE approval_status AS ENUM ('pending','approved','rejected','expired');
CREATE TYPE license_type  AS ENUM ('clone','api_sub');
CREATE TYPE purchase_status AS ENUM ('pending','paid','refunded','failed');
CREATE TYPE budget_scope  AS ENUM ('workspace','agent','endpoint');

-- 공통: updated_at 자동 갱신
CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END $$ LANGUAGE plpgsql;

-- ===== 계정·권한 =====
CREATE TABLE users (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email         CITEXT NOT NULL UNIQUE,
  display_name  TEXT NOT NULL,
  password_hash TEXT,                              -- 소셜 전용 계정은 NULL
  oauth_provider TEXT,
  oauth_subject  TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (oauth_provider, oauth_subject)
);

CREATE TABLE workspaces (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug       CITEXT NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9][a-z0-9-]{2,39}$'),
  name       TEXT NOT NULL,
  plan       TEXT NOT NULL DEFAULT 'free',
  settings   JSONB NOT NULL DEFAULT '{}'::jsonb,   -- compress_threshold 등
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE memberships (
  workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role         member_role NOT NULL DEFAULT 'maker',
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, user_id)
);
CREATE INDEX ix_memberships_user ON memberships(user_id);
-- 워크스페이스당 owner는 정확히 1명
CREATE UNIQUE INDEX ux_memberships_one_owner ON memberships(workspace_id) WHERE role = 'owner';

-- ===== 연동 =====
CREATE TABLE credentials (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  provider     TEXT NOT NULL,
  label        TEXT NOT NULL,
  ciphertext   BYTEA NOT NULL,
  nonce        BYTEA NOT NULL CHECK (octet_length(nonce) = 12),
  wrapped_dek  BYTEA NOT NULL,
  key_version  INT NOT NULL,
  purposes     TEXT[] NOT NULL DEFAULT '{}',
  created_by   UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, provider, label)
);

CREATE TABLE mcp_servers (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id  UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  transport     mcp_transport NOT NULL,
  command       TEXT,
  url           TEXT,
  credential_id UUID REFERENCES credentials(id) ON DELETE SET NULL,
  allow_tools   TEXT[],
  is_active     BOOLEAN NOT NULL DEFAULT true,
  last_synced_at TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, name),
  CHECK ((transport = 'stdio' AND command IS NOT NULL) OR (transport <> 'stdio' AND url IS NOT NULL))
);

CREATE TABLE mcp_tools (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  server_id     UUID NOT NULL REFERENCES mcp_servers(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  description   TEXT,
  input_schema  JSONB NOT NULL,
  output_schema JSONB,
  annotations   JSONB NOT NULL DEFAULT '{}'::jsonb,
  is_active     BOOLEAN NOT NULL DEFAULT true,
  synced_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (server_id, name)
);

-- ===== 스튜디오 =====
CREATE TABLE workflows (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id       UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  name               TEXT NOT NULL,
  description        TEXT,
  draft              JSONB NOT NULL DEFAULT '{"nodes":[],"edges":[]}'::jsonb,  -- 편집 중 정의
  draft_version      INT NOT NULL DEFAULT 1,                                   -- 낙관적 잠금
  origin_version_id  UUID,                                                     -- 템플릿/마켓 출처
  created_by         UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at         TIMESTAMPTZ
);
CREATE INDEX ix_workflows_ws ON workflows(workspace_id) WHERE deleted_at IS NULL;

CREATE TABLE workflow_versions (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workflow_id UUID NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
  version     INT NOT NULL,
  definition  JSONB NOT NULL,
  def_hash    TEXT NOT NULL,                       -- sha256(canonical json)
  note        TEXT,
  created_by  UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (workflow_id, version)
);
ALTER TABLE workflows ADD CONSTRAINT fk_workflows_origin
  FOREIGN KEY (origin_version_id) REFERENCES workflow_versions(id) ON DELETE SET NULL;

-- 버전은 불변
CREATE OR REPLACE FUNCTION forbid_update() RETURNS trigger AS $$
BEGIN RAISE EXCEPTION 'MOA-WF-010: % is immutable', TG_TABLE_NAME; END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_wfv_immutable BEFORE UPDATE ON workflow_versions
  FOR EACH ROW EXECUTE FUNCTION forbid_update();

CREATE TABLE agents (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id        UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  name                TEXT NOT NULL,
  description         TEXT,
  model               TEXT NOT NULL,
  fallback_models     TEXT[] NOT NULL DEFAULT '{}',
  system_prompt       TEXT NOT NULL DEFAULT '',
  temperature         NUMERIC(3,2) NOT NULL DEFAULT 0.7 CHECK (temperature BETWEEN 0 AND 2),
  memory_enabled      BOOLEAN NOT NULL DEFAULT true,
  primary_workflow_id UUID REFERENCES workflows(id) ON DELETE SET NULL,
  created_by          UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at          TIMESTAMPTZ
);
CREATE INDEX ix_agents_ws ON agents(workspace_id) WHERE deleted_at IS NULL;

CREATE TABLE agent_workflows (
  agent_id    UUID NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  workflow_id UUID NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
  alias       TEXT NOT NULL,                       -- 에이전트가 도구로 부를 이름
  PRIMARY KEY (agent_id, workflow_id),
  UNIQUE (agent_id, alias)
);

CREATE TABLE agent_skills (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id          UUID NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  mcp_tool_id       UUID REFERENCES mcp_tools(id) ON DELETE CASCADE,
  builtin_skill     TEXT,                          -- 'web_search', 'kb_search' 등
  require_approval  BOOLEAN NOT NULL DEFAULT false,
  config            JSONB NOT NULL DEFAULT '{}'::jsonb,
  CHECK ((mcp_tool_id IS NULL) <> (builtin_skill IS NULL))
);
CREATE INDEX ix_agent_skills_agent ON agent_skills(agent_id);

-- ===== 지식 =====
CREATE TABLE knowledge_bases (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id  UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  embed_model   TEXT NOT NULL,
  chunk_size    INT NOT NULL DEFAULT 800,
  chunk_overlap INT NOT NULL DEFAULT 120,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE kb_documents (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  kb_id       UUID NOT NULL REFERENCES knowledge_bases(id) ON DELETE CASCADE,
  filename    TEXT NOT NULL,
  s3_key      TEXT NOT NULL,
  mime        TEXT NOT NULL,
  bytes       BIGINT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','indexing','ready','failed')),
  chunk_count INT NOT NULL DEFAULT 0,
  error       TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_kb_docs_kb ON kb_documents(kb_id);

-- ===== 배포 =====
CREATE TABLE endpoints (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id        UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  slug                CITEXT NOT NULL CHECK (slug ~ '^[a-z0-9][a-z0-9-]{2,62}$'),
  agent_id            UUID NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  workflow_version_id UUID NOT NULL REFERENCES workflow_versions(id),
  mode                invoke_mode NOT NULL DEFAULT 'sync',
  input_schema        JSONB NOT NULL,
  webhook_url         TEXT,
  webhook_secret      TEXT NOT NULL,
  rate_limit_rpm      INT NOT NULL DEFAULT 60 CHECK (rate_limit_rpm > 0),
  is_active           BOOLEAN NOT NULL DEFAULT true,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, slug)
);

CREATE TABLE api_keys (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  name         TEXT NOT NULL,
  prefix       CHAR(8) NOT NULL UNIQUE,
  hash         TEXT NOT NULL,                      -- argon2id
  scopes       TEXT[] NOT NULL DEFAULT '{invoke}',
  last_used_at TIMESTAMPTZ,
  expires_at   TIMESTAMPTZ,
  revoked_at   TIMESTAMPTZ,
  created_by   UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_api_keys_ws ON api_keys(workspace_id) WHERE revoked_at IS NULL;

-- ===== 실행 (월 단위 파티션) =====
CREATE TABLE runs (
  id                  UUID NOT NULL DEFAULT gen_random_uuid(),
  workspace_id        UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  agent_id            UUID REFERENCES agents(id) ON DELETE SET NULL,
  workflow_version_id UUID NOT NULL REFERENCES workflow_versions(id),
  endpoint_id         UUID REFERENCES endpoints(id) ON DELETE SET NULL,
  api_key_id          UUID REFERENCES api_keys(id) ON DELETE SET NULL,
  trigger             run_trigger NOT NULL,
  status              run_status NOT NULL DEFAULT 'queued',
  input               JSONB,
  output              JSONB,
  error_code          TEXT,
  error_detail        JSONB,
  cost_usd            NUMERIC(12,6) NOT NULL DEFAULT 0,
  tokens_in           INT NOT NULL DEFAULT 0,
  tokens_out          INT NOT NULL DEFAULT 0,
  started_at          TIMESTAMPTZ,
  finished_at         TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (id, created_at),
  CHECK (finished_at IS NULL OR started_at IS NULL OR finished_at >= started_at)
) PARTITION BY RANGE (created_at);
CREATE TABLE runs_2026_10 PARTITION OF runs FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE runs_2026_11 PARTITION OF runs FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE runs_2026_12 PARTITION OF runs FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');
CREATE TABLE runs_default PARTITION OF runs DEFAULT;
CREATE INDEX ix_runs_ws_created ON runs(workspace_id, created_at DESC);
CREATE INDEX ix_runs_active ON runs(status) WHERE status IN ('queued','running','waiting_approval');

CREATE TABLE run_steps (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id      UUID NOT NULL,                        -- runs가 파티션이라 FK 대신 애플리케이션 보장
  node_id     TEXT NOT NULL,
  node_type   TEXT NOT NULL,
  attempt     INT NOT NULL DEFAULT 1,
  model       TEXT,
  ok          BOOLEAN,
  input       JSONB,
  output      JSONB,
  error_code  TEXT,
  tokens_in   INT NOT NULL DEFAULT 0,
  tokens_out  INT NOT NULL DEFAULT 0,
  cost_usd    NUMERIC(12,6) NOT NULL DEFAULT 0,
  latency_ms  INT,
  started_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at TIMESTAMPTZ
);
CREATE INDEX ix_run_steps_run ON run_steps(run_id, started_at);

CREATE TABLE approvals (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id      UUID NOT NULL,
  workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  node_id     TEXT NOT NULL,
  summary     JSONB NOT NULL,
  approvers   UUID[] NOT NULL DEFAULT '{}',
  status      approval_status NOT NULL DEFAULT 'pending',
  decided_by  UUID REFERENCES users(id) ON DELETE SET NULL,
  decided_at  TIMESTAMPTZ,
  comment     TEXT,
  expires_at  TIMESTAMPTZ NOT NULL DEFAULT now() + interval '72 hours',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (run_id, node_id)
);
CREATE INDEX ix_approvals_pending ON approvals(workspace_id, expires_at) WHERE status = 'pending';

CREATE TABLE idempotency_keys (
  workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  key          TEXT NOT NULL CHECK (length(key) BETWEEN 8 AND 255),
  request_hash TEXT NOT NULL,
  run_id       UUID NOT NULL,
  response     JSONB,
  expires_at   TIMESTAMPTZ NOT NULL DEFAULT now() + interval '24 hours',
  PRIMARY KEY (workspace_id, key)
);

CREATE TABLE assets_3d (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  run_id      UUID NOT NULL,
  step_id     UUID REFERENCES run_steps(id) ON DELETE SET NULL,
  s3_key      TEXT NOT NULL,
  preview_key TEXT,
  format      TEXT NOT NULL CHECK (format IN ('glb','gltf','blend','fbx','obj')),
  poly_count  INT,
  bytes       BIGINT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ===== 컨텍스트 =====
CREATE TABLE context_sessions (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  agent_id     UUID REFERENCES agents(id) ON DELETE SET NULL,
  run_id       UUID,
  model_family TEXT NOT NULL,
  last_seq     INT NOT NULL DEFAULT 0,
  used_tokens  INT NOT NULL DEFAULT 0,             -- enabled 블록 합계 캐시
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_ctx_sessions_run ON context_sessions(run_id);

CREATE TABLE context_blocks (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id      UUID NOT NULL REFERENCES context_sessions(id) ON DELETE CASCADE,
  seq             INT NOT NULL,
  role            block_role NOT NULL,
  content         TEXT NOT NULL CHECK (length(content) <= 200000),
  token_count     INT NOT NULL CHECK (token_count >= 0),
  pinned          BOOLEAN NOT NULL DEFAULT false,
  enabled         BOOLEAN NOT NULL DEFAULT true,
  priority        SMALLINT NOT NULL DEFAULT 50 CHECK (priority BETWEEN 0 AND 100),
  source_node     TEXT,
  compressed_into UUID REFERENCES context_blocks(id) ON DELETE SET NULL,
  expires_at      TIMESTAMPTZ,
  version         INT NOT NULL DEFAULT 1,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (session_id, seq),
  CHECK (NOT (pinned AND compressed_into IS NOT NULL))   -- 고정 블록은 압축 불가
);
CREATE INDEX ix_ctx_blocks_active ON context_blocks(session_id, seq) WHERE enabled;
CREATE INDEX ix_ctx_blocks_expiry ON context_blocks(expires_at) WHERE enabled AND expires_at IS NOT NULL;
CREATE TRIGGER trg_ctx_blocks_touch BEFORE UPDATE ON context_blocks
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TABLE context_snapshots (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id  UUID NOT NULL REFERENCES context_sessions(id) ON DELETE CASCADE,
  label       TEXT NOT NULL,
  block_count INT NOT NULL,
  body        JSONB,                                -- 1MB 초과 시 NULL + s3_key
  s3_key      TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK ((body IS NULL) <> (s3_key IS NULL))
);

CREATE TABLE compression_logs (
  id               BIGSERIAL PRIMARY KEY,
  session_id       UUID NOT NULL REFERENCES context_sessions(id) ON DELETE CASCADE,
  summary_block_id UUID REFERENCES context_blocks(id) ON DELETE SET NULL,
  source_block_ids UUID[] NOT NULL,
  strategy         TEXT NOT NULL,
  saved_tokens     INT NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE memories (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  agent_id     UUID REFERENCES agents(id) ON DELETE CASCADE,
  kind         memory_kind NOT NULL,
  content      TEXT NOT NULL,
  meta         JSONB NOT NULL DEFAULT '{}'::jsonb,
  indexed_at   TIMESTAMPTZ,                         -- Qdrant 반영 시각
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at   TIMESTAMPTZ
);
CREATE INDEX ix_memories_scope ON memories(workspace_id, agent_id, created_at DESC) WHERE deleted_at IS NULL;

-- ===== 마켓 =====
CREATE OR REPLACE FUNCTION tags_text(text[]) RETURNS text
  LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT coalesce(array_to_string($1, ' '), '') $$;

CREATE TABLE market_products (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  seller_ws      UUID NOT NULL REFERENCES workspaces(id) ON DELETE RESTRICT,
  agent_id       UUID REFERENCES agents(id) ON DELETE SET NULL,
  endpoint_id    UUID REFERENCES endpoints(id) ON DELETE SET NULL,   -- api_sub용
  title          TEXT NOT NULL,
  summary        TEXT NOT NULL,
  category       TEXT NOT NULL,
  tags           TEXT[] NOT NULL DEFAULT '{}',
  readme_md      TEXT CHECK (octet_length(readme_md) <= 65536),
  license_types  license_type[] NOT NULL,
  price_clone_krw   INT CHECK (price_clone_krw >= 0),
  price_api_month_krw INT CHECK (price_api_month_krw >= 0),
  status         TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','in_review','published','suspended')),
  rating_avg     NUMERIC(2,1) NOT NULL DEFAULT 0,
  rating_count   INT NOT NULL DEFAULT 0,
  install_count  INT NOT NULL DEFAULT 0,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  search_tsv     TSVECTOR GENERATED ALWAYS AS
                 (to_tsvector('simple', title || ' ' || summary || ' ' || tags_text(tags))) STORED,
  CHECK (array_length(license_types, 1) >= 1),
  CHECK (NOT ('api_sub' = ANY(license_types)) OR endpoint_id IS NOT NULL)
);
CREATE INDEX ix_market_search ON market_products USING GIN (search_tsv);
CREATE INDEX ix_market_cat ON market_products(category, install_count DESC) WHERE status = 'published';

CREATE TABLE market_versions (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id          UUID NOT NULL REFERENCES market_products(id) ON DELETE CASCADE,
  semver              TEXT NOT NULL CHECK (semver ~ '^\d+\.\d+\.\d+$'),
  bundle              JSONB NOT NULL,                 -- 정리(sanitize)된 agent+workflows
  scan_report         JSONB NOT NULL,
  workflow_version_id UUID REFERENCES workflow_versions(id),
  changelog           TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (product_id, semver)
);

CREATE TABLE purchases (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id   UUID NOT NULL REFERENCES market_products(id) ON DELETE RESTRICT,
  version_id   UUID NOT NULL REFERENCES market_versions(id),
  buyer_ws     UUID NOT NULL REFERENCES workspaces(id) ON DELETE RESTRICT,
  buyer_user   UUID REFERENCES users(id) ON DELETE SET NULL,
  license_type license_type NOT NULL,
  amount_krw   INT NOT NULL CHECK (amount_krw >= 0),
  fee_krw      INT NOT NULL DEFAULT 0,
  status       purchase_status NOT NULL DEFAULT 'pending',
  pg_tx_id     TEXT UNIQUE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  paid_at      TIMESTAMPTZ
);

CREATE TABLE licenses (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id  UUID NOT NULL REFERENCES market_products(id) ON DELETE RESTRICT,
  version_id  UUID NOT NULL REFERENCES market_versions(id),
  buyer_ws    UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  purchase_id UUID NOT NULL REFERENCES purchases(id),
  type        license_type NOT NULL,
  expires_at  TIMESTAMPTZ,                          -- clone은 NULL(영구)
  revoked_at  TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK ((type = 'clone') = (expires_at IS NULL))
);
CREATE UNIQUE INDEX ux_license_clone_once ON licenses(buyer_ws, product_id) WHERE type = 'clone' AND revoked_at IS NULL;

CREATE TABLE reviews (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID NOT NULL REFERENCES market_products(id) ON DELETE CASCADE,
  license_id UUID NOT NULL UNIQUE REFERENCES licenses(id) ON DELETE CASCADE,  -- 라이선스당 1건
  author     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  rating     SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
  body       TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 평점 집계 갱신
CREATE OR REPLACE FUNCTION refresh_rating() RETURNS trigger AS $$
DECLARE pid UUID := COALESCE(NEW.product_id, OLD.product_id);
BEGIN
  UPDATE market_products p SET
    rating_avg = COALESCE((SELECT round(avg(rating)::numeric, 1) FROM reviews WHERE product_id = pid), 0),
    rating_count = (SELECT count(*) FROM reviews WHERE product_id = pid)
  WHERE p.id = pid;
  RETURN NULL;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_reviews_rating AFTER INSERT OR UPDATE OR DELETE ON reviews
  FOR EACH ROW EXECUTE FUNCTION refresh_rating();

-- ===== 과금 =====
CREATE TABLE budgets (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id      UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  scope_type        budget_scope NOT NULL,
  scope_id          UUID NOT NULL,
  monthly_limit_usd NUMERIC(12,2) CHECK (monthly_limit_usd >= 0),
  per_run_limit_usd NUMERIC(12,4) CHECK (per_run_limit_usd >= 0),
  alert_ratio       NUMERIC(3,2) NOT NULL DEFAULT 0.80 CHECK (alert_ratio BETWEEN 0 AND 1),
  UNIQUE (scope_type, scope_id)
);

CREATE TABLE usage_ledger (
  id           BIGSERIAL PRIMARY KEY,
  workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  run_id       UUID NOT NULL,
  step_id      UUID,
  agent_id     UUID,
  endpoint_id  UUID,
  model        TEXT NOT NULL,
  tokens_in    INT NOT NULL,
  tokens_out   INT NOT NULL,
  cost_usd     NUMERIC(12,6) NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_ledger_ws_month ON usage_ledger(workspace_id, created_at);

-- ===== 공통 =====
CREATE TABLE audit_logs (
  id           BIGSERIAL PRIMARY KEY,
  workspace_id UUID,
  actor_user   UUID,
  actor_key    UUID,
  action       TEXT NOT NULL,                       -- 'endpoint.publish' 등
  target_id    UUID,
  meta         JSONB NOT NULL DEFAULT '{}'::jsonb,
  ip           INET,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_audit_ws_time ON audit_logs(workspace_id, created_at DESC);

CREATE TABLE outbox_events (
  id           BIGSERIAL PRIMARY KEY,
  topic        TEXT NOT NULL,
  key          UUID NOT NULL,
  payload      JSONB NOT NULL,
  attempts     INT NOT NULL DEFAULT 0,
  processed_at TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_outbox_pending ON outbox_events(id) WHERE processed_at IS NULL;

-- ===== 공통 트리거 =====
CREATE TRIGGER trg_users_touch      BEFORE UPDATE ON users      FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_workspaces_touch BEFORE UPDATE ON workspaces FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_workflows_touch  BEFORE UPDATE ON workflows  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_agents_touch     BEFORE UPDATE ON agents     FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_endpoints_touch  BEFORE UPDATE ON endpoints  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ===== 행 수준 보안 (테넌트 격리) =====
-- 애플리케이션은 트랜잭션마다 SET LOCAL app.workspace_id = '<uuid>' 를 실행한다.
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['agents','workflows','endpoints','api_keys','runs','credentials',
                           'mcp_servers','knowledge_bases','memories','context_sessions',
                           'approvals','assets_3d','budgets','usage_ledger']
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format($p$CREATE POLICY p_tenant ON %I
                     USING (workspace_id = current_setting('app.workspace_id', true)::uuid)
                     WITH CHECK (workspace_id = current_setting('app.workspace_id', true)::uuid)$p$, t);
  END LOOP;
END $$;

-- ===== 운영 뷰 =====
CREATE VIEW v_monthly_cost AS
SELECT workspace_id, date_trunc('month', created_at) AS month,
       sum(cost_usd) AS cost_usd, sum(tokens_in) AS tokens_in, sum(tokens_out) AS tokens_out
FROM usage_ledger GROUP BY 1, 2;
