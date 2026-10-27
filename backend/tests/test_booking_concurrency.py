import uuid
from app.seed import seed_database


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


def test_seat_hold_and_double_booking_prevention(client, db_session):
    seed_database(db_session)

    # 1. Get an active event and first available seat
    events_res = client.get("/api/v1/events?status=ACTIVE")
    event_id = events_res.json()[0]["event_id"]

    seats_res = client.get(f"/api/v1/events/{event_id}/seats")
    seat_id = seats_res.json()[0]["seat_id"]

    # 2. Setup two admitted users
    token1, adm_token1 = _setup_admitted_user(client, "buyer1@example.com", event_id)
    token2, adm_token2 = _setup_admitted_user(client, "buyer2@example.com", event_id)

    # 3. Buyer 1 reserves the seat
    hold_res1 = client.post(
        "/api/v1/seats/hold",
        json={
            "event_id": event_id,
            "seat_id": seat_id,
            "admission_token": adm_token1
        },
        headers={"Authorization": f"Bearer {token1}"}
    )
    assert hold_res1.status_code == 200
    assert hold_res1.json()["success"] is True
    assert hold_res1.json()["status"] == "RESERVED"

    # 4. Buyer 2 attempts to reserve the EXACT SAME seat concurrently -> 409 Conflict
    hold_res2 = client.post(
        "/api/v1/seats/hold",
        json={
            "event_id": event_id,
            "seat_id": seat_id,
            "admission_token": adm_token2
        },
        headers={"Authorization": f"Bearer {token2}"}
    )
    assert hold_res2.status_code == 409
    assert "currently reserved by another customer" in hold_res2.json()["detail"]


def test_booking_idempotency_and_checkout_lifecycle(client, db_session):
    seed_database(db_session)

    events_res = client.get("/api/v1/events?status=ACTIVE")
    evt = events_res.json()[0]
    event_id = evt["event_id"]
    initial_available = evt["available_capacity"]

    seats_res = client.get(f"/api/v1/events/{event_id}/seats")
    seat_id = seats_res.json()[1]["seat_id"]

    token, adm_token = _setup_admitted_user(client, "checkout@example.com", event_id)

    # 1. Hold seat
    hold_res = client.post(
        "/api/v1/seats/hold",
        json={
            "event_id": event_id,
            "seat_id": seat_id,
            "admission_token": adm_token
        },
        headers={"Authorization": f"Bearer {token}"}
    )
    assert hold_res.status_code == 200

    # 2. Create booking with idempotency key
    idempotency_key = f"idem-key-{uuid.uuid4().hex}"
    booking_res = client.post(
        "/api/v1/bookings",
        json={
            "event_id": event_id,
            "seat_id": seat_id,
            "idempotency_key": idempotency_key,
            "admission_token": adm_token
        },
        headers={"Authorization": f"Bearer {token}"}
    )
    assert booking_res.status_code == 201
    booking_data = booking_res.json()
    booking_id = booking_data["booking_id"]
    assert booking_data["status"] == "PENDING_PAYMENT"

    # 3. Test booking idempotency: re-submit exact same request
    dup_booking = client.post(
        "/api/v1/bookings",
        json={
            "event_id": event_id,
            "seat_id": seat_id,
            "idempotency_key": idempotency_key,
            "admission_token": adm_token
        },
        headers={"Authorization": f"Bearer {token}"}
    )
    assert dup_booking.status_code in [200, 201]
    assert dup_booking.json()["booking_id"] == booking_id

    # 4. Simulate payment failure first
    pay_key = f"pay-key-{uuid.uuid4().hex}"
    fail_res = client.post(
        "/api/v1/bookings/checkout",
        json={
            "booking_id": booking_id,
            "idempotency_key": pay_key,
            "simulate_failure": True
        },
        headers={"Authorization": f"Bearer {token}"}
    )
    assert fail_res.status_code == 402

    # 5. Successful payment checkout
    pay_success_key = f"pay-key-success-{uuid.uuid4().hex}"
    success_res = client.post(
        "/api/v1/bookings/checkout",
        json={
            "booking_id": booking_id,
            "idempotency_key": pay_success_key,
            "simulate_failure": False
        },
        headers={"Authorization": f"Bearer {token}"}
    )
    assert success_res.status_code == 200
    assert success_res.json()["status"] == "SUCCESS"

    # 6. Verify booking is now CONFIRMED
    my_bookings = client.get(
        "/api/v1/bookings/my",
        headers={"Authorization": f"Bearer {token}"}
    )
    assert my_bookings.status_code == 200
    assert any(b["booking_id"] == booking_id and b["status"] == "CONFIRMED" for b in my_bookings.json())

    # 7. Verify seat is permanently BOOKED and cannot be reserved by anyone
    hold_attempt = client.post(
        "/api/v1/seats/hold",
        json={
            "event_id": event_id,
            "seat_id": seat_id,
            "admission_token": adm_token
        },
        headers={"Authorization": f"Bearer {token}"}
    )
    assert hold_attempt.status_code == 409
    assert "already permanently booked" in hold_attempt.json()["detail"]

    # 8. Verify event capacity was decremented
    updated_evt = client.get(f"/api/v1/events/{event_id}").json()
    assert updated_evt["available_capacity"] == initial_available - 1
