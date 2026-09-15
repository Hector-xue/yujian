/// 版本化 schema。每个版本一段 SQL，只追加不修改；升级按顺序执行未应用的版本。
const migrations = <int, String>{
  1: '''
CREATE TABLE accounts (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  type TEXT NOT NULL,
  currency TEXT NOT NULL,
  initial_balance_minor INTEGER NOT NULL DEFAULT 0,
  institution TEXT,
  icon TEXT,
  is_archived INTEGER NOT NULL DEFAULT 0,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE categories (
  id TEXT PRIMARY KEY,
  parent_id TEXT REFERENCES categories(id),
  kind TEXT NOT NULL,
  name TEXT NOT NULL,
  icon TEXT,
  is_default INTEGER NOT NULL DEFAULT 0,
  sort_order INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE transactions (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL,
  occurred_at_ms INTEGER NOT NULL,
  tz_offset_min INTEGER NOT NULL,
  currency TEXT NOT NULL,
  merchant TEXT,
  description TEXT,
  category_id TEXT REFERENCES categories(id),
  tags TEXT NOT NULL DEFAULT '[]',
  source TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'confirmed',
  confidence REAL,
  refund_of_id TEXT REFERENCES transactions(id),
  recurring_id TEXT,
  event_fingerprint TEXT,
  metadata TEXT NOT NULL DEFAULT '{}',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX idx_tx_occurred ON transactions(occurred_at_ms);
CREATE INDEX idx_tx_status ON transactions(status);
CREATE INDEX idx_tx_fingerprint ON transactions(event_fingerprint);
CREATE INDEX idx_tx_category ON transactions(category_id);

CREATE TABLE postings (
  id TEXT PRIMARY KEY,
  transaction_id TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts(id),
  amount_minor INTEGER NOT NULL
);
CREATE INDEX idx_posting_account ON postings(account_id);
CREATE INDEX idx_posting_tx ON postings(transaction_id);

CREATE TABLE drafts (
  id TEXT PRIMARY KEY,
  group_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  target_transaction_id TEXT,
  source TEXT NOT NULL,
  session_id TEXT,
  event_fingerprint TEXT,
  possible_duplicate_of TEXT,
  payload TEXT NOT NULL,
  interpreter TEXT,
  model_used TEXT,
  confidence REAL,
  missing_fields TEXT NOT NULL DEFAULT '[]',
  status TEXT NOT NULL DEFAULT 'pending',
  committed_transaction_id TEXT,
  created_at INTEGER NOT NULL,
  resolved_at INTEGER
);
CREATE INDEX idx_draft_status ON drafts(status);
CREATE INDEX idx_draft_group ON drafts(group_id);
CREATE INDEX idx_draft_fingerprint ON drafts(event_fingerprint);

CREATE TABLE audit_log (
  id TEXT PRIMARY KEY,
  at INTEGER NOT NULL,
  actor TEXT NOT NULL,
  action TEXT NOT NULL,
  target_type TEXT NOT NULL,
  target_id TEXT NOT NULL,
  before_json TEXT,
  after_json TEXT,
  draft_id TEXT,
  model_used TEXT,
  interpreter TEXT,
  confirmed_by_user INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_audit_target ON audit_log(target_type, target_id);

CREATE TABLE events (
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  external_id TEXT,
  raw TEXT,
  fingerprint TEXT NOT NULL,
  received_at INTEGER NOT NULL,
  draft_id TEXT
);
CREATE INDEX idx_event_fingerprint ON events(fingerprint);
''',
};
