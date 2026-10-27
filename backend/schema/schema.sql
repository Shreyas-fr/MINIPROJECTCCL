-- ==============================================================================
-- SurgeGate Database Schema (MySQL 8.0+)
-- Designed for High-Concurrency Flash Sales with Row-Level Locking & Anti-Overselling
-- ==============================================================================

CREATE DATABASE IF NOT EXISTS surgegate CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE surgegate;

-- ------------------------------------------------------------------------------
-- 1. Users Table (Authentication & Role-Based Access)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
    user_id VARCHAR(36) PRIMARY KEY,
    email VARCHAR(255) NOT NULL UNIQUE,
    full_name VARCHAR(255) NOT NULL,
    password_hash VARCHAR(255) NULL,
    role VARCHAR(20) NOT NULL DEFAULT 'CUSTOMER',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_users_email (email)
) ENGINE=InnoDB;

-- ------------------------------------------------------------------------------
-- 2. Events Table
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS events (
    event_id VARCHAR(36) PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    venue VARCHAR(255) NOT NULL,
    event_timestamp DATETIME NOT NULL,
    total_capacity INT NOT NULL,
    available_capacity INT NOT NULL,
    status ENUM('UPCOMING', 'ACTIVE', 'SOLD_OUT', 'COMPLETED') DEFAULT 'UPCOMING',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT chk_capacity CHECK (available_capacity >= 0)
) ENGINE=InnoDB;

-- ------------------------------------------------------------------------------
-- 3. Seat Tiers & Inventory (Row-Level Locking with Optimistic Version Counter)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS seats (
    seat_id VARCHAR(36) PRIMARY KEY,
    event_id VARCHAR(36) NOT NULL,
    section VARCHAR(50) NOT NULL,
    `row_number` VARCHAR(20) NOT NULL,
    seat_number VARCHAR(20) NOT NULL,
    price_cents INT NOT NULL,
    -- Status progression: AVAILABLE -> RESERVED -> BOOKED
    status ENUM('AVAILABLE', 'RESERVED', 'BOOKED') DEFAULT 'AVAILABLE',
    -- Reservation lock metadata to enable expiration cleanup
    reserved_by VARCHAR(36) NULL,
    reserved_until DATETIME NULL,
    version INT NOT NULL DEFAULT 1, -- Optimistic locking counter
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FOREIGN KEY (event_id) REFERENCES events(event_id) ON DELETE CASCADE,
    -- STRICT CONSTRAINT: A seat can only exist once per event/section/row/seat_num
    UNIQUE KEY uq_event_seat (event_id, section, `row_number`, seat_number),
    INDEX idx_seat_status_lookup (event_id, status, reserved_until)
) ENGINE=InnoDB;

-- ------------------------------------------------------------------------------
-- 4. Bookings Table (Enforces One Booking Per Reserved Seat & Idempotency)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bookings (
    booking_id VARCHAR(36) PRIMARY KEY,
    booking_ref VARCHAR(32) NOT NULL UNIQUE, -- Human-friendly reference: SG-ABCD1234
    idempotency_key VARCHAR(128) NOT NULL UNIQUE, -- Prevents duplicate payment/order submission
    user_id VARCHAR(36) NOT NULL,
    event_id VARCHAR(36) NOT NULL,
    seat_id VARCHAR(36) NOT NULL,
    total_amount_cents INT NOT NULL,
    status ENUM('PENDING_PAYMENT', 'CONFIRMED', 'CANCELLED', 'EXPIRED') DEFAULT 'PENDING_PAYMENT',
    ticket_id VARCHAR(64) NULL,
    ticket_s3_url VARCHAR(512) NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(user_id),
    FOREIGN KEY (event_id) REFERENCES events(event_id),
    FOREIGN KEY (seat_id) REFERENCES seats(seat_id),
    -- STRICT CONSTRAINT: Prevents multiple confirmed bookings for the same seat
    UNIQUE KEY uq_active_seat_booking (seat_id, status),
    INDEX idx_bookings_booking_ref (booking_ref),
    INDEX idx_bookings_idempotency_key (idempotency_key)
) ENGINE=InnoDB;

-- ------------------------------------------------------------------------------
-- 5. Payments (Simulated Idempotent Transactions)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS payments (
    payment_id VARCHAR(36) PRIMARY KEY,
    booking_id VARCHAR(36) NOT NULL,
    transaction_ref VARCHAR(64) NOT NULL UNIQUE,
    amount_cents INT NOT NULL,
    currency VARCHAR(3) DEFAULT 'USD',
    payment_status ENUM('INITIATED', 'SUCCESS', 'FAILED') DEFAULT 'INITIATED',
    payment_method VARCHAR(50) DEFAULT 'SIMULATED_CARD',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (booking_id) REFERENCES bookings(booking_id),
    INDEX idx_payments_transaction_ref (transaction_ref)
) ENGINE=InnoDB;

-- ------------------------------------------------------------------------------
-- 6. Durable Virtual Waiting Room (Queue Entries)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS queue_entries (
    queue_id VARCHAR(36) PRIMARY KEY,
    event_id VARCHAR(36) NOT NULL,
    user_id VARCHAR(36) NOT NULL,
    queue_number INT NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'WAITING',
    admission_token VARCHAR(128) NULL UNIQUE,
    joined_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_heartbeat DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    admitted_at DATETIME NULL,
    admission_expires_at DATETIME NULL,
    FOREIGN KEY (event_id) REFERENCES events(event_id) ON DELETE CASCADE,
    FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE,
    INDEX idx_queue_event_status_num (event_id, status, queue_number),
    INDEX idx_queue_entries_event_id (event_id),
    INDEX idx_queue_entries_user_id (user_id),
    INDEX idx_queue_entries_admission_token (admission_token)
) ENGINE=InnoDB;

-- ------------------------------------------------------------------------------
-- 7. Alembic Migration Version Tracking
-- Ensures compatibility with both schema.sql direct execution and Alembic migrations
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS alembic_version (
    version_num VARCHAR(32) NOT NULL,
    PRIMARY KEY (version_num)
) ENGINE=InnoDB;

INSERT INTO alembic_version (version_num)
SELECT '001_initial_schema'
WHERE NOT EXISTS (SELECT 1 FROM alembic_version WHERE version_num = '001_initial_schema');

-- ------------------------------------------------------------------------------
-- 8. High-Concurrency Reservation Demonstration Procedure
-- Demonstrates row-level pessimistic locking (SELECT FOR UPDATE) with lock timeout
-- ------------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS ReserveSeatAtomic;
DELIMITER //
CREATE PROCEDURE ReserveSeatAtomic(
    IN p_event_id VARCHAR(36),
    IN p_seat_id VARCHAR(36),
    IN p_user_id VARCHAR(36),
    IN p_lock_duration_seconds INT,
    OUT p_result VARCHAR(50)
)
BEGIN
    DECLARE v_current_status VARCHAR(20);
    DECLARE v_reserved_until DATETIME;

    START TRANSACTION;

    -- Pessimistic row-level lock on the target seat
    SELECT status, reserved_until INTO v_current_status, v_reserved_until
    FROM seats
    WHERE seat_id = p_seat_id AND event_id = p_event_id
    FOR UPDATE;

    IF v_current_status IS NULL THEN
        SET p_result = 'SEAT_NOT_FOUND';
        ROLLBACK;
    ELSEIF v_current_status = 'BOOKED' THEN
        SET p_result = 'ALREADY_BOOKED';
        ROLLBACK;
    ELSEIF v_current_status = 'RESERVED' AND v_reserved_until > NOW() THEN
        SET p_result = 'CURRENTLY_LOCKED_BY_ANOTHER_USER';
        ROLLBACK;
    ELSE
        -- Seat is either AVAILABLE or previously reserved lock has expired!
        UPDATE seats
        SET status = 'RESERVED',
            reserved_by = p_user_id,
            reserved_until = DATE_ADD(NOW(), INTERVAL p_lock_duration_seconds SECOND),
            version = version + 1
        WHERE seat_id = p_seat_id;

        SET p_result = 'RESERVATION_SUCCESS';
        COMMIT;
    END IF;
END //
DELIMITER ;
