---
--- Concepts
---
CREATE TABLE IF NOT EXISTS concept (
    id   BLOB PRIMARY KEY,
    name TEXT NOT NULL
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

-- Raise an error before insertion if:
-- 1. A cyclical edge is trying to be inserted (e.g. A -> B -> C, and add C -> A)
-- 2. A redundant edge is trying to be inserted (e.g. A -> B -> C, and add A -> C)
CREATE TRIGGER IF NOT EXISTS validate_concept_rel_before_insert
BEFORE INSERT ON concept_rel
FOR EACH ROW
BEGIN
    -- 1. Cycle check: Can we reach NEW.parent_id by going DOWN from NEW.child_id?
    SELECT RAISE(ABORT, 'Cycle detected: adding this relationship creates a loop')
    WHERE EXISTS (
        WITH RECURSIVE descendants(id) AS (
            SELECT NEW.child_id
            UNION
            SELECT cr.child_id FROM concept_rel cr JOIN descendants d ON cr.parent_id = d.id
        )
        SELECT 1 FROM descendants WHERE id = NEW.parent_id
    );

    -- 2. Redundant insert check: Can we reach NEW.child_id by going DOWN from NEW.parent_id?
    SELECT RAISE(ABORT, 'Redundant relationship: an indirect path already exists')
    WHERE EXISTS (
        WITH RECURSIVE path(id) AS (
            SELECT cr.child_id FROM concept_rel cr WHERE cr.parent_id = NEW.parent_id
            UNION
            SELECT cr.child_id FROM concept_rel cr JOIN path p ON cr.parent_id = p.id
        )
        SELECT 1 FROM path WHERE id = NEW.child_id
    );
END;

-- Remove redundant edges after an insertion
-- E.g. A -> B and A -> C, then adding B -> C makes A -> C redundant
CREATE TRIGGER IF NOT EXISTS prune_redundant_concept_rels
AFTER INSERT ON concept_rel
FOR EACH ROW
BEGIN
    DELETE FROM concept_rel
    WHERE rowid IN (
        WITH RECURSIVE
            ancestors(id) AS (
                SELECT NEW.parent_id
                UNION
                SELECT cr.parent_id
                FROM concept_rel cr
                JOIN ancestors a ON cr.child_id = a.id
            ),
            descendants(id) AS (
                SELECT NEW.child_id
                UNION
                SELECT cr.child_id
                FROM concept_rel cr
                JOIN descendants d ON cr.parent_id = d.id
            )
        SELECT cr.rowid
        FROM concept_rel cr
        WHERE cr.parent_id IN (SELECT id FROM ancestors)
          AND cr.child_id IN (SELECT id FROM descendants)
          AND NOT (cr.parent_id = NEW.parent_id AND cr.child_id = NEW.child_id)
    );
END;
