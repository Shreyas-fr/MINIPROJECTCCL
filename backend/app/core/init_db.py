import logging
from sqlalchemy import inspect, text, Engine
from app.core.database import engine as default_engine, Base
import app.models  # Ensure all models are registered

logger = logging.getLogger(__name__)


def init_db(engine: Engine = default_engine) -> None:
    """
    Ensures all database tables, columns, indexes, and Alembic version stamp exist.
    Compatible with SQLite (tests) and MySQL 8 (local Docker and AWS RDS).
    Completely idempotent and self-healing for existing databases.
    """
    logger.info("Initializing and validating database schema...")

    # 1. Create missing tables
    Base.metadata.create_all(bind=engine)

    # 2. Inspect existing tables for missing columns (handles legacy schemas)
    inspector = inspect(engine)
    existing_tables = set(inspector.get_table_names())

    with engine.begin() as conn:
        dialect_name = engine.dialect.name.lower()

        # Check 'users' table columns
        if "users" in existing_tables:
            user_cols = {col["name"] for col in inspector.get_columns("users")}
            if "password_hash" not in user_cols:
                logger.info("Adding missing column 'password_hash' to users table")
                conn.execute(text("ALTER TABLE users ADD COLUMN password_hash VARCHAR(255) NULL"))
            if "role" not in user_cols:
                logger.info("Adding missing column 'role' to users table")
                conn.execute(text("ALTER TABLE users ADD COLUMN role VARCHAR(20) NOT NULL DEFAULT 'CUSTOMER'"))

        # Check 'bookings' table columns
        if "bookings" in existing_tables:
            booking_cols = {col["name"] for col in inspector.get_columns("bookings")}
            if "ticket_id" not in booking_cols:
                logger.info("Adding missing column 'ticket_id' to bookings table")
                conn.execute(text("ALTER TABLE bookings ADD COLUMN ticket_id VARCHAR(64) NULL"))
            if "ticket_s3_url" not in booking_cols:
                logger.info("Adding missing column 'ticket_s3_url' to bookings table")
                conn.execute(text("ALTER TABLE bookings ADD COLUMN ticket_s3_url VARCHAR(512) NULL"))

        # 3. Ensure Alembic version is recorded
        if "alembic_version" not in existing_tables:
            logger.info("Creating alembic_version table")
            conn.execute(text(
                "CREATE TABLE IF NOT EXISTS alembic_version ("
                "version_num VARCHAR(32) NOT NULL, "
                "PRIMARY KEY (version_num)"
                ")"
            ))

        # Check if 001_initial_schema is stamped
        res = conn.execute(text("SELECT version_num FROM alembic_version WHERE version_num = '001_initial_schema'")).first()
        if not res:
            logger.info("Stamping database with alembic revision '001_initial_schema'")
            conn.execute(text("INSERT INTO alembic_version (version_num) VALUES ('001_initial_schema')"))

        # 4. If running on MySQL, ensure ReserveSeatAtomic procedure is defined
        if "mysql" in dialect_name:
            proc_check = conn.execute(text(
                "SELECT ROUTINE_NAME FROM INFORMATION_SCHEMA.ROUTINES "
                "WHERE ROUTINE_SCHEMA = DATABASE() AND ROUTINE_NAME = 'ReserveSeatAtomic'"
            )).first()
            if not proc_check:
                logger.info("Defining stored procedure ReserveSeatAtomic on MySQL")
                conn.execute(text("DROP PROCEDURE IF EXISTS ReserveSeatAtomic"))
                conn.execute(text("""
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
                        UPDATE seats
                        SET status = 'RESERVED',
                            reserved_by = p_user_id,
                            reserved_until = DATE_ADD(NOW(), INTERVAL p_lock_duration_seconds SECOND),
                            version = version + 1
                        WHERE seat_id = p_seat_id;

                        SET p_result = 'RESERVATION_SUCCESS';
                        COMMIT;
                    END IF;
                END
                """))

    logger.info("Database schema verification and initialization completed successfully.")
