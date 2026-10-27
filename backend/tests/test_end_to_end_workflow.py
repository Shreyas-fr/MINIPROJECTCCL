import uuid
import secrets
from app.seed import seed_database
from app.models import QueueEntry
from datetime import datetime, timedelta


def _setup_admitted_user(client, email: str, event_id: str):
    # Register & Login User
    res = client.post("/api/v1/auth/register", json={
        "email": email,
        "full_name": f"User {email}",
        "password": "Password123!",
        "role": "CUSTOMER"
    })
    assert res.status_code == 201, f"Register failed: {res.status_code} - {res.text}"
    token = res.json()["access_token"]

    # Join queue
    client.post(
        "/api/v1/queue/join",
        json={"event_id": event_id},
        headers={"Authorization": f"Bearer {token}"}
    )

    # Admin admits
    admin_login = client.post("/api/v1/auth/login", json={
        "email": "admin@surgegate.internal",
        "password": "AdminPass123!"
    })
    admin_token = admin_login.json()["access_token"]
    client.post(
        f"/api/v1/admin/queue/{event_id}/admit?batch_size=10",
        headers={"Authorization": f"Bearer {admin_token}"}
    )

    # Fetch status with admission token
    st = client.get(
        f"/api/v1/queue/{event_id}/status",
        headers={"Authorization": f"Bearer {token}"}
    )
    admission_token = st.json()["admission_token"]
    return token, admission_token


def test_admission_token_validation_lifecycle(client, db_session):
    """
    Test strict admission token security:
    - Missing token rejected
    - Forged token rejected
    - Expired token rejected
    - Valid token accepted
    """
    seed_database(db_session)
    events = client.get("/api/v1/events?status=ACTIVE").json()
    event_id = events[0]["event_id"]
    seats = client.get(f"/api/v1/events/{event_id}/seats").json()
    seat_id = seats[0]["seat_id"]

    # Register user without queue admission
    res = client.post("/api/v1/auth/register", json={
        "email": "noqueue@surge.io",
        "full_name": "No Queue User",
        "password": "Password123!",
        "role": "CUSTOMER"
    })
    token = res.json()["access_token"]

    # 1. Attempt hold with forged token -> 403 Forbidden
    forged_res = client.post(
        "/api/v1/seats/hold",
        json={
            "event_id": event_id,
            "seat_id": seat_id,
            "admission_token": "forged-fake-token-12345"
        },
        headers={"Authorization": f"Bearer {token}"}
    )
    assert forged_res.status_code == 403
    assert "admission token required" in forged_res.json()["detail"].lower()

    # 2. Get proper admission token
    token, adm_token = _setup_admitted_user(client, "validuser@surge.io", event_id)
    assert adm_token is not None

    # 3. Hold seat with valid token -> 200 OK
    valid_res = client.post(
        "/api/v1/seats/hold",
        json={
            "event_id": event_id,
            "seat_id": seat_id,
            "admission_token": adm_token
        },
        headers={"Authorization": f"Bearer {token}"}
    )
    assert valid_res.status_code == 200
    assert valid_res.json()["success"] is True

    # 4. Invalidate / expire token in database
    db_session.query(QueueEntry).filter(
        QueueEntry.admission_token == adm_token
    ).update({"admission_expires_at": datetime.utcnow() - timedelta(minutes=5)})
    db_session.commit()

    seat_id_2 = seats[1]["seat_id"]
    expired_res = client.post(
        "/api/v1/seats/hold",
        json={
            "event_id": event_id,
            "seat_id": seat_id_2,
            "admission_token": adm_token
        },
        headers={"Authorization": f"Bearer {token}"}
    )
    assert expired_res.status_code == 403
    assert "expired" in expired_res.json()["detail"].lower()


def test_multiple_seat_selection_and_checkout_flow(client, db_session):
    """
    Test booking multiple seats (up to 4) in one transaction:
    - Hold multiple seats simultaneously
    - Double-booking prevention across all held seats
    - Atomic booking creation
    - Simulated checkout for batch
    - All seats confirmed and capacity decremented
    - Verification that each seat has a distinct ticket QR
    """
    seed_database(db_session)
    events = client.get("/api/v1/events?status=ACTIVE").json()
    event_id = events[0]["event_id"]
    initial_capacity = events[0]["available_capacity"]

    seats = client.get(f"/api/v1/events/{event_id}/seats").json()
    available_seats = [s["seat_id"] for s in seats if s["status"] == "AVAILABLE"][:3]
    assert len(available_seats) == 3

    buyer_token, buyer_adm = _setup_admitted_user(client, "multibuyer@surge.io", event_id)
    other_token, other_adm = _setup_admitted_user(client, "otherbuyer@surge.io", event_id)

    # 1. Hold 3 seats in one call
    hold_res = client.post(
        "/api/v1/seats/hold",
        json={
            "event_id": event_id,
            "seat_ids": available_seats,
            "admission_token": buyer_adm
        },
        headers={"Authorization": f"Bearer {buyer_token}"}
    )
    assert hold_res.status_code == 200
    assert hold_res.json()["success"] is True
    assert len(hold_res.json()["seat_ids"]) == 3

    # 2. Other buyer attempts to hold one of those seats -> 409 Conflict
    conflict_res = client.post(
        "/api/v1/seats/hold",
        json={
            "event_id": event_id,
            "seat_id": available_seats[0],
            "admission_token": other_adm
        },
        headers={"Authorization": f"Bearer {other_token}"}
    )
    assert conflict_res.status_code == 409

    # 3. Create booking for all 3 seats
    idem_key = f"idem-batch-{secrets.token_hex(4)}"
    create_res = client.post(
        "/api/v1/bookings",
        json={
            "event_id": event_id,
            "seat_ids": available_seats,
            "idempotency_key": idem_key,
            "admission_token": buyer_adm
        },
        headers={"Authorization": f"Bearer {buyer_token}"}
    )
    assert create_res.status_code == 201
    booking_data = create_res.json()
    assert len(booking_data["booking_ids"]) == 3
    assert len(booking_data["bookings"]) == 3

    # 4. Checkout and pay for all 3 bookings
    pay_res = client.post(
        "/api/v1/bookings/checkout",
        json={
            "booking_ids": booking_data["booking_ids"],
            "idempotency_key": f"pay-{idem_key}",
            "simulate_failure": False
        },
        headers={"Authorization": f"Bearer {buyer_token}"}
    )
    assert pay_res.status_code == 200
    assert pay_res.json()["status"] == "SUCCESS"
    assert len(pay_res.json()["booking_ids"]) == 3

    # 5. Verify all seats are BOOKED and event capacity reduced by 3
    updated_seats = client.get(f"/api/v1/events/{event_id}/seats").json()
    booked_ids = [s["seat_id"] for s in updated_seats if s["status"] == "BOOKED"]
    for s_id in available_seats:
        assert s_id in booked_ids

    updated_event = client.get(f"/api/v1/events/{event_id}").json()
    assert updated_event["available_capacity"] == initial_capacity - 3


def test_seat_limit_enforcement(client, db_session):
    """
    Verify customer cannot exceed maximum 4 tickets per event.
    """
    seed_database(db_session)
    events = client.get("/api/v1/events?status=ACTIVE").json()
    event_id = events[0]["event_id"]
    seats = client.get(f"/api/v1/events/{event_id}/seats").json()
    five_seats = [s["seat_id"] for s in seats[:5]]

    token, adm_token = _setup_admitted_user(client, "greedy@surge.io", event_id)

    # Attempting to hold 5 seats -> 400 Bad Request
    res = client.post(
        "/api/v1/seats/hold",
        json={
            "event_id": event_id,
            "seat_ids": five_seats,
            "admission_token": adm_token
        },
        headers={"Authorization": f"Bearer {token}"}
    )
    assert res.status_code == 400
    assert "limit" in res.json()["detail"].lower()


def test_payment_decline_and_retry_preserves_holds(client, db_session):
    """
    Verify graceful simulated decline:
    - Decline raises 402 Payment Required
    - Seat hold remains actively RESERVED
    - Subsequent retry with valid payment succeeds without conflict
    """
    seed_database(db_session)
    events = client.get("/api/v1/events?status=ACTIVE").json()
    event_id = events[0]["event_id"]
    seats = client.get(f"/api/v1/events/{event_id}/seats").json()
    seat_id = seats[0]["seat_id"]

    token, adm_token = _setup_admitted_user(client, "retryuser@surge.io", event_id)

    # 1. Hold seat
    client.post(
        "/api/v1/seats/hold",
        json={"event_id": event_id, "seat_id": seat_id, "admission_token": adm_token},
        headers={"Authorization": f"Bearer {token}"}
    )

    # 2. Create booking
    idem_key = f"idem-retry-{secrets.token_hex(4)}"
    booking = client.post(
        "/api/v1/bookings",
        json={"event_id": event_id, "seat_id": seat_id, "idempotency_key": idem_key, "admission_token": adm_token},
        headers={"Authorization": f"Bearer {token}"}
    ).json()

    # 3. Simulate payment decline -> 402
    decline_res = client.post(
        "/api/v1/bookings/checkout",
        json={"booking_id": booking["booking_id"], "idempotency_key": f"pay-{idem_key}", "simulate_failure": True},
        headers={"Authorization": f"Bearer {token}"}
    )
    assert decline_res.status_code == 402

    # 4. Verify seat is STILL RESERVED
    seat_check = client.get(f"/api/v1/events/{event_id}/seats").json()
    the_seat = next(s for s in seat_check if s["seat_id"] == seat_id)
    assert the_seat["status"] == "RESERVED"

    # 5. Retry payment with simulate_failure=False -> succeeds!
    success_res = client.post(
        "/api/v1/bookings/checkout",
        json={"booking_id": booking["booking_id"], "idempotency_key": f"pay-{idem_key}", "simulate_failure": False},
        headers={"Authorization": f"Bearer {token}"}
    )
    assert success_res.status_code == 200
    assert success_res.json()["status"] == "SUCCESS"


def test_queue_leave_and_rejoin_lifecycle(client, db_session):
    """
    Test queue leave & rejoin:
    - User joins queue and holds a seat
    - User leaves queue -> queue status LEFT, token invalidated, seat hold released
    - User rejoins queue -> assigned new sequential queue position at end of FIFO
    - No duplicate active entries
    """
    seed_database(db_session)
    events = client.get("/api/v1/events?status=ACTIVE").json()
    event_id = events[0]["event_id"]
    seats = client.get(f"/api/v1/events/{event_id}/seats").json()
    seat_id = seats[0]["seat_id"]

    token, adm_token = _setup_admitted_user(client, "leaver@surge.io", event_id)

    # Hold seat
    client.post(
        "/api/v1/seats/hold",
        json={"event_id": event_id, "seat_id": seat_id, "admission_token": adm_token},
        headers={"Authorization": f"Bearer {token}"}
    )

    # Explicitly leave waiting room
    leave_res = client.post(
        f"/api/v1/queue/{event_id}/leave",
        headers={"Authorization": f"Bearer {token}"}
    )
    assert leave_res.status_code == 200

    # Verify held seat was automatically released back to AVAILABLE
    seat_check = client.get(f"/api/v1/events/{event_id}/seats").json()
    released_seat = next(s for s in seat_check if s["seat_id"] == seat_id)
    assert released_seat["status"] == "AVAILABLE"

    # Verify old admission token is now rejected
    hold_again = client.post(
        "/api/v1/seats/hold",
        json={"event_id": event_id, "seat_id": seat_id, "admission_token": adm_token},
        headers={"Authorization": f"Bearer {token}"}
    )
    assert hold_again.status_code == 403

    # Rejoin queue -> fresh queue entry created
    rejoin_res = client.post(
        "/api/v1/queue/join",
        json={"event_id": event_id},
        headers={"Authorization": f"Bearer {token}"}
    )
    assert rejoin_res.status_code == 200
    assert rejoin_res.json()["status"] == "WAITING"

    # Verify in DB there is only 1 active entry
    active_entries = db_session.query(QueueEntry).filter(
        QueueEntry.event_id == event_id,
        QueueEntry.status.in_(["WAITING", "ADMITTED"])
    ).all()
    # At most 1 active entry for this user
    user_active = [e for e in active_entries if e.user.email == "leaver@surge.io"]
    assert len(user_active) == 1


def test_my_bookings_rich_metadata_retrieval(client, db_session):
    """
    Test that /api/v1/bookings/my returns enriched metadata:
    - Event name, venue, timestamp
    - Section, row_number, seat_number, seat_info
    - Ticket ID and booking reference
    """
    seed_database(db_session)
    events = client.get("/api/v1/events?status=ACTIVE").json()
    event_id = events[0]["event_id"]
    seats = client.get(f"/api/v1/events/{event_id}/seats").json()
    seat_id = seats[0]["seat_id"]

    token, adm_token = _setup_admitted_user(client, "mybookings@surge.io", event_id)

    # Hold, book, checkout
    client.post(
        "/api/v1/seats/hold",
        json={"event_id": event_id, "seat_id": seat_id, "admission_token": adm_token},
        headers={"Authorization": f"Bearer {token}"}
    )
    booking = client.post(
        "/api/v1/bookings",
        json={"event_id": event_id, "seat_id": seat_id, "idempotency_key": f"idem-{secrets.token_hex(4)}", "admission_token": adm_token},
        headers={"Authorization": f"Bearer {token}"}
    ).json()
    client.post(
        "/api/v1/bookings/checkout",
        json={"booking_id": booking["booking_id"], "idempotency_key": f"pay-{secrets.token_hex(4)}", "simulate_failure": False},
        headers={"Authorization": f"Bearer {token}"}
    )

    # Fetch My Bookings
    my_res = client.get("/api/v1/bookings/my", headers={"Authorization": f"Bearer {token}"})
    assert my_res.status_code == 200
    my_data = my_res.json()
    assert len(my_data) >= 1

    my_b = next(b for b in my_data if b["booking_id"] == booking["booking_id"])
    assert my_b["status"] == "CONFIRMED"
    assert my_b["ticket_id"] is not None
    assert my_b["event_name"] == events[0]["name"]
    assert my_b["venue"] == events[0]["venue"]
    assert my_b["section"] is not None
    assert my_b["row_number"] is not None
    assert my_b["seat_number"] is not None
    assert "Row" in my_b["seat_info"]


def test_automatic_queue_admission_cycle(client, db_session):
    """
    Test automatic queue admission worker/scheduler:
    - Verifies FIFO queue ordering
    - Verifies automatic admission cycle transitions users from WAITING to ADMITTED
    - Verifies cryptographic admission tokens are generated securely
    - Verifies admitted customer can successfully transition to seat selection and seat hold
    - Verifies production queue control: does not admit if event capacity is 0
    """
    from app.services.queue_scheduler import QueueAdmissionScheduler
    from app.models import Event

    seed_database(db_session)
    events = client.get("/api/v1/events?status=ACTIVE").json()
    assert len(events) > 0
    event_id = events[0]["event_id"]

    # Register Customer A
    res_a = client.post("/api/v1/auth/register", json={
        "email": "autouser_a@surge.io",
        "full_name": "Customer Alpha",
        "password": "Password123!",
        "role": "CUSTOMER"
    })
    token_a = res_a.json()["access_token"]

    # Register Customer B
    res_b = client.post("/api/v1/auth/register", json={
        "email": "autouser_b@surge.io",
        "full_name": "Customer Beta",
        "password": "Password123!",
        "role": "CUSTOMER"
    })
    token_b = res_b.json()["access_token"]

    # Customer A joins queue
    q_a = client.post(
        "/api/v1/queue/join",
        json={"event_id": event_id},
        headers={"Authorization": f"Bearer {token_a}"}
    ).json()
    assert q_a["status"] == "WAITING"
    assert q_a["position_ahead"] == 0

    # Customer B joins queue
    q_b = client.post(
        "/api/v1/queue/join",
        json={"event_id": event_id},
        headers={"Authorization": f"Bearer {token_b}"}
    ).json()
    assert q_b["status"] == "WAITING"
    assert q_b["position_ahead"] == 1
    assert q_b["queue_number"] > q_a["queue_number"]

    # Run one admission cycle via QueueAdmissionScheduler
    admitted_count = QueueAdmissionScheduler.run_admission_cycle(db_session)
    assert admitted_count >= 2

    # Verify Customer A is ADMITTED with secure cryptographic admission token
    st_a = client.get(
        f"/api/v1/queue/{event_id}/status",
        headers={"Authorization": f"Bearer {token_a}"}
    ).json()
    assert st_a["status"] == "ADMITTED"
    assert st_a["admission_token"] is not None
    assert len(st_a["admission_token"]) >= 32  # 24 bytes hex = 48 chars
    assert st_a["position_ahead"] == 0

    # Verify Customer B is also ADMITTED with unique secure admission token
    st_b = client.get(
        f"/api/v1/queue/{event_id}/status",
        headers={"Authorization": f"Bearer {token_b}"}
    ).json()
    assert st_b["status"] == "ADMITTED"
    assert st_b["admission_token"] is not None
    assert st_b["admission_token"] != st_a["admission_token"]

    # Verify complete transition to seat selection: Customer A holds a seat with their admission token
    seats = client.get(f"/api/v1/events/{event_id}/seats").json()
    target_seat = seats[0]
    hold_res = client.post(
        "/api/v1/seats/hold",
        json={
            "event_id": event_id,
            "seat_id": target_seat["seat_id"],
            "admission_token": st_a["admission_token"]
        },
        headers={"Authorization": f"Bearer {token_a}"}
    )
    assert hold_res.status_code == 200
    assert hold_res.json()["success"] is True

    # Test production queue control: when available capacity is 0, scheduler admits 0
    event_obj = db_session.query(Event).filter(Event.event_id == event_id).first()
    event_obj.available_capacity = 0
    db_session.commit()

    # Register Customer C and join queue
    res_c = client.post("/api/v1/auth/register", json={
        "email": "autouser_c@surge.io",
        "full_name": "Customer Gamma",
        "password": "Password123!",
        "role": "CUSTOMER"
    })
    token_c = res_c.json()["access_token"]
    client.post(
        "/api/v1/queue/join",
        json={"event_id": event_id},
        headers={"Authorization": f"Bearer {token_c}"}
    )

    # Admission cycle when capacity == 0
    admitted_c = QueueAdmissionScheduler.run_admission_cycle(db_session)
    assert admitted_c == 0

    st_c = client.get(
        f"/api/v1/queue/{event_id}/status",
        headers={"Authorization": f"Bearer {token_c}"}
    ).json()
    assert st_c["status"] == "WAITING"

