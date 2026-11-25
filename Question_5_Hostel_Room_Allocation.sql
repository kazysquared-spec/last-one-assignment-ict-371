DROP VIEW IF EXISTS v_room_occupancy;

DROP PROCEDURE IF EXISTS pr_refresh_occupancy();
DROP PROCEDURE IF EXISTS pr_allocate_room(INT, INT, DATE);

DROP FUNCTION IF EXISTS trg_check_allocation();
DROP FUNCTION IF EXISTS fn_free_beds(INT);

DROP TABLE IF EXISTS occupancy_snapshot CASCADE;
DROP TABLE IF EXISTS allocations CASCADE;
DROP TABLE IF EXISTS rooms CASCADE;
DROP TABLE IF EXISTS students CASCADE;

CREATE TABLE students (
    student_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(30) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    room_number VARCHAR(20) UNIQUE NOT NULL,
    capacity INT NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    room_id INT NOT NULL REFERENCES rooms(room_id),
    allocated_on DATE NOT NULL,
    released_on DATE,
    status VARCHAR(10) NOT NULL
        CHECK (status IN ('ACTIVE', 'ENDED')),
    CHECK (
        (status = 'ACTIVE' AND released_on IS NULL)
        OR
        (status = 'ENDED' AND released_on IS NOT NULL)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id INT NOT NULL REFERENCES rooms(room_id),
    occupied_beds INT NOT NULL CHECK (occupied_beds >= 0),
    free_beds INT NOT NULL CHECK (free_beds >= 0),
    PRIMARY KEY (snapshot_date, room_id)
);
CREATE UNIQUE INDEX uq_student_active_allocation
ON allocations (student_id)
WHERE status = 'ACTIVE';

INSERT INTO students (student_number, full_name)
VALUES
    ('MU2024001', 'Charles Chisala'),
    ('MU2024002', 'John Banda'),
    ('MU2024003', 'Peter Phiri'),
    ('MU2024004', 'Mary Zulu');

INSERT INTO rooms (room_number, capacity)
VALUES
    ('R101', 2),
    ('R102', 3),
    ('R103', 2);

CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INT;
    v_occupied INT;
BEGIN
    SELECT capacity
      INTO v_capacity
      FROM rooms
     WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Room ID % does not exist', p_room_id;
    END IF;

    SELECT COUNT(*)::INT
      INTO v_occupied
      FROM allocations
     WHERE room_id = p_room_id
       AND status = 'ACTIVE';

    RETURN v_capacity - v_occupied;
END;
$$;

CREATE OR REPLACE FUNCTION trg_check_allocation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INT;
    v_occupied INT;
BEGIN
    SELECT capacity
      INTO v_capacity
      FROM rooms
     WHERE room_id = NEW.room_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Room ID % does not exist', NEW.room_id;
    END IF;

    IF NEW.status = 'ACTIVE' THEN
        SELECT COUNT(*)::INT
          INTO v_occupied
          FROM allocations
         WHERE room_id = NEW.room_id
           AND status = 'ACTIVE'
           AND allocation_id IS DISTINCT FROM NEW.allocation_id;

        IF v_occupied >= v_capacity THEN
            RAISE EXCEPTION
                'Room % has reached its maximum capacity',
                NEW.room_id;
        END IF;
        IF EXISTS (
            SELECT 1
              FROM allocations
             WHERE student_id = NEW.student_id
               AND status = 'ACTIVE'
               AND allocation_id IS DISTINCT FROM NEW.allocation_id
        ) THEN
            RAISE EXCEPTION
                'Student % already has an ACTIVE allocation',
                NEW.student_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocation_validation
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_check_allocation();

CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id INT,
    p_room_id INT,
    p_allocated_on DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date cannot be NULL';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM students WHERE student_id = p_student_id
    ) THEN
        RAISE EXCEPTION 'Student ID % does not exist', p_student_id;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM rooms WHERE room_id = p_room_id
    ) THEN
        RAISE EXCEPTION 'Room ID % does not exist', p_room_id;
    END IF;

    IF EXISTS (
        SELECT 1
          FROM allocations
         WHERE student_id = p_student_id
           AND status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION
            'Student % already has an ACTIVE allocation',
            p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % has no available beds', p_room_id;
    END IF;

    INSERT INTO allocations (
        student_id,
        room_id,
        allocated_on,
        released_on,
        status
    )
    VALUES (
        p_student_id,
        p_room_id,
        p_allocated_on,
        NULL,
        'ACTIVE'
    );

    RAISE NOTICE 'Room allocated successfully';
END;
$$;

CALL pr_allocate_room(1, 1, CURRENT_DATE);
CALL pr_allocate_room(2, 1, CURRENT_DATE);
CALL pr_allocate_room(3, 2, CURRENT_DATE);
INSERT INTO allocations (
    student_id, room_id, allocated_on, released_on, status
)
VALUES (
    4, 3, CURRENT_DATE - 30, CURRENT_DATE - 5, 'ENDED'
);

SELECT room_id, room_number, fn_free_beds(room_id) AS free_beds
FROM rooms
ORDER BY room_id;

CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT
    r.room_id,
    r.room_number,
    r.capacity,
    COUNT(a.allocation_id)::INT AS occupied_beds,
    (r.capacity - COUNT(a.allocation_id))::INT AS free_beds
FROM rooms AS r
LEFT JOIN allocations AS a
       ON a.room_id = r.room_id
      AND a.status = 'ACTIVE'
GROUP BY
    r.room_id,
    r.room_number,
    r.capacity;
SELECT *
FROM v_room_occupancy
ORDER BY room_number;

CREATE INDEX idx_allocations_active_room
ON allocations (room_id)
WHERE status = 'ACTIVE';
SELECT allocation_id, student_id, room_id, allocated_on
FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';
EXPLAIN
SELECT allocation_id, student_id, room_id, allocated_on
FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';

CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (
        snapshot_date,
        room_id,
        occupied_beds,
        free_beds
    )
    SELECT
        CURRENT_DATE,
        r.room_id,
        COUNT(a.allocation_id)::INT,
        (r.capacity - COUNT(a.allocation_id))::INT
    FROM rooms AS r
    LEFT JOIN allocations AS a
           ON a.room_id = r.room_id
          AND a.status = 'ACTIVE'
    GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id)
    DO UPDATE SET
        occupied_beds = EXCLUDED.occupied_beds,
        free_beds = EXCLUDED.free_beds;
END;
$$;
CALL pr_refresh_occupancy();
SELECT *
FROM occupancy_snapshot
ORDER BY snapshot_date, room_id;
CALL pr_refresh_occupancy();
