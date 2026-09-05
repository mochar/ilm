---
--- Concepts
---
CREATE TABLE IF NOT EXISTS concept (
    id   BLOB PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS concept_rel (
    parent_id BLOB NOT NULL,
    child_id  BLOB NOT NULL,

    PRIMARY KEY (parent_id, child_id),

    FOREIGN KEY (parent_id) REFERENCES concept(id) ON DELETE CASCADE,
    FOREIGN KEY (child_id) REFERENCES concept(id) ON DELETE CASCADE,

    CHECK (parent_id != child_id)
);

-- Index to speed up queries looking for a concept's parents
CREATE INDEX IF NOT EXISTS idx_child_id ON concept_rel(child_id);
