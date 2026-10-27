import os
import re
import pytest
from sqlalchemy import create_engine, inspect, select, text
from sqlalchemy.dialects import mysql

from app.core.database import Base, engine as default_engine
from app.models import User, Event, Seat, Booking, Payment, QueueEntry
from app.seed import seed_database
from app.core.init_db import init_db
from app.core.security import verify_password


def get_schema_sql_content() -> str:
    current_dir = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.abspath(os.path.join(current_dir, "..", "..", "schema", "schema.sql")),
        os.path.abspath(os.path.join(current_dir, "..", "schema", "schema.sql")),
        os.path.abspath(os.path.join(current_dir, "schema.sql")),
        "/app/schema/schema.sql",
        "/app/schema.sql",
        "/schema/schema.sql",
    ]
    schema_path = None
    for cand in candidates:
        if os.path.exists(cand):
            schema_path = cand
            break

    if not schema_path:
        raise FileNotFoundError(f"schema.sql not found in any candidate path: {candidates}")

    with open(schema_path, "rb") as f:
        raw_bytes = f.read()

    assert not raw_bytes.startswith(b"\xef\xbb\xbf"), "schema.sql must not contain a UTF-8 BOM"
    return raw_bytes.decode("utf-8")


def parse_tables_and_columns_from_sql(sql_content: str):
    """
    Parses table definitions and their column names from CREATE TABLE statements in SQL.
    """
    tables = {}
    table_pattern = re.compile(r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([`\w]+)\s*\((.*?)\)\s*ENGINE", re.DOTALL | re.IGNORECASE)

    for match in table_pattern.finditer(sql_content):
        table_name = match.group(1).strip("`")
        body = match.group(2)
        columns = set()

        for line in body.split("\n"):
            line = line.strip().rstrip(",")
            if not line or line.startswith("--"):
                continue
            upper_line = line.upper()
            if any(upper_line.startswith(prefix) for prefix in [
                "PRIMARY KEY", "FOREIGN KEY", "UNIQUE KEY", "INDEX", "KEY", "CONSTRAINT", "CHECK"
            ]):
                continue

            # First token is the column name
            col_match = re.match(r"^[`\"]?([a-zA-Z0-9_]+)[`\"]?\s+", line)
            if col_match:
                columns.add(col_match.group(1))

        tables[table_name] = columns
    return tables


def test_schema_sql_has_no_bom():
    content = get_schema_sql_content()
    assert len(content) > 0


def test_schema_sql_matches_all_sqlalchemy_models():
    """
    Ensures schema.sql contains all tables and columns defined in the SQLAlchemy models.
    Catches any schema drift or omissions between application code and DDL.
    """
    sql_content = get_schema_sql_content()
    parsed_tables = parse_tables_and_columns_from_sql(sql_content)

    model_tables = Base.metadata.tables

    for table_name, table_obj in model_tables.items():
        assert table_name in parsed_tables, f"Table '{table_name}' from SQLAlchemy models is missing in schema/schema.sql"

        model_columns = {col.name for col in table_obj.columns}
        schema_columns = parsed_tables[table_name]

        missing_in_schema = model_columns - schema_columns
        assert not missing_in_schema, (
            f"Columns {missing_in_schema} in model table '{table_name}' are missing in schema/schema.sql"
        )


def test_schema_sql_quotes_mysql_reserved_words():
    """
    Ensures MySQL 8 reserved keywords like `row_number` are properly backticked in schema.sql.
    """
    sql_content = get_schema_sql_content()
    # Check that row_number in seats definition is enclosed in backticks
    assert "`row_number` VARCHAR" in sql_content or "`row_number`" in sql_content, (
        "schema.sql must escape MySQL 8 reserved keyword `row_number` with backticks"
    )


def test_model_row_number_is_quoted_in_mysql_dialect():
    """
    Verifies that the Seat model quotes row_number so queries compile safely under MySQL.
    """
    compiled_stmt = str(select(Seat.row_number).compile(dialect=mysql.dialect()))
    assert "`row_number`" in compiled_stmt, (
        f"Seat.row_number was not compiled with backticks: {compiled_stmt}"
    )


def test_seed_database_idempotent_multi_run(db_session):
    """
    Verifies that running seed_database multiple times is completely idempotent
    and does not produce duplicate key errors or corrupt existing data.
    """
    # 1st run
    seed_database(db_session)

    initial_users_count = db_session.query(User).count()
    initial_events_count = db_session.query(Event).count()
    initial_seats_count = db_session.query(Seat).count()

    assert initial_users_count == 3
    assert initial_events_count == 3
    assert initial_seats_count == 130

    # Verify admin password hashing
    admin = db_session.query(User).filter(User.email == "admin@surgegate.internal").first()
    assert admin is not None
    assert admin.role == "ADMIN"
    assert verify_password("AdminPass123!", admin.password_hash)

    # 2nd run
    seed_database(db_session)

    # Counts must remain identical
    assert db_session.query(User).count() == initial_users_count
    assert db_session.query(Event).count() == initial_events_count
    assert db_session.query(Seat).count() == initial_seats_count


def test_init_db_self_healing_missing_columns():
    """
    Verifies that init_db detects missing columns on existing legacy tables
    and heals the database schema without error.
    """
    # Create a fresh isolated in-memory engine
    test_engine = create_engine("sqlite:///:memory:")

    # Create older partial schema missing password_hash and role in users
    with test_engine.begin() as conn:
        conn.execute(text(
            "CREATE TABLE users ("
            "user_id VARCHAR(36) PRIMARY KEY, "
            "email VARCHAR(255) NOT NULL UNIQUE, "
            "full_name VARCHAR(255) NOT NULL, "
            "created_at DATETIME"
            ")"
        ))
        conn.execute(text(
            "CREATE TABLE bookings ("
            "booking_id VARCHAR(36) PRIMARY KEY, "
            "booking_ref VARCHAR(32) NOT NULL UNIQUE, "
            "idempotency_key VARCHAR(128) NOT NULL UNIQUE, "
            "user_id VARCHAR(36) NOT NULL, "
            "event_id VARCHAR(36) NOT NULL, "
            "seat_id VARCHAR(36) NOT NULL, "
            "total_amount_cents INT NOT NULL, "
            "status VARCHAR(20)"
            ")"
        ))

    # Run init_db on the partial database
    init_db(test_engine)

    # Inspect healed tables
    inspector = inspect(test_engine)
    user_cols = {c["name"] for c in inspector.get_columns("users")}
    assert "password_hash" in user_cols
    assert "role" in user_cols

    booking_cols = {c["name"] for c in inspector.get_columns("bookings")}
    assert "ticket_id" in booking_cols
    assert "ticket_s3_url" in booking_cols

    # Ensure queue_entries table was created
    assert "queue_entries" in inspector.get_table_names()
    assert "alembic_version" in inspector.get_table_names()


def test_live_database_schema_parity():
    """
    If running against MySQL, verifies that the active database contains all models,
    all required columns, and the alembic_version stamp.
    """
    try:
        inspector = inspect(default_engine)
        active_tables = set(inspector.get_table_names())
    except Exception:
        pytest.skip("Default database engine not reachable in this test environment")

    # If connected to MySQL or configured database
    if "users" in active_tables:
        user_cols = {c["name"] for c in inspector.get_columns("users")}
        assert "password_hash" in user_cols
        assert "role" in user_cols

    if "bookings" in active_tables:
        booking_cols = {c["name"] for c in inspector.get_columns("bookings")}
        assert "ticket_id" in booking_cols
        assert "ticket_s3_url" in booking_cols

    if "seats" in active_tables:
        seat_cols = {c["name"] for c in inspector.get_columns("seats")}
        assert "row_number" in seat_cols

    assert "queue_entries" in active_tables
    assert "alembic_version" in active_tables
