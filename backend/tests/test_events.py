from datetime import datetime, timedelta
from app.seed import seed_database


def test_seed_and_list_events(client, db_session):
    # Seed data
    seed_database(db_session)

    # List all events
    response = client.get("/api/v1/events")
    assert response.status_code == 200
    events = response.json()
    assert len(events) >= 3

    # Filter by ACTIVE
    active_res = client.get("/api/v1/events?status=ACTIVE")
    assert active_res.status_code == 200
    active_events = active_res.json()
    assert all(e["status"] == "ACTIVE" for e in active_events)


def test_get_event_detail_and_seats(client, db_session):
    seed_database(db_session)

    # Get one event
    events_res = client.get("/api/v1/events")
    event_id = events_res.json()[0]["event_id"]

    # Detail
    detail_res = client.get(f"/api/v1/events/{event_id}")
    assert detail_res.status_code == 200
    detail = detail_res.json()
    assert detail["event_id"] == event_id
    assert detail["total_capacity"] > 0
    assert detail["min_price_cents"] is not None

    # Seats
    seats_res = client.get(f"/api/v1/events/{event_id}/seats")
    assert seats_res.status_code == 200
    seats = seats_res.json()
    assert len(seats) == detail["total_capacity"]
    assert seats[0]["status"] == "AVAILABLE"
    assert "section" in seats[0]


def test_admin_create_event_and_role_protection(client):
    # Register customer
    cust_res = client.post("/api/v1/auth/register", json={
        "email": "regularuser@example.com",
        "full_name": "Regular User",
        "password": "Password123!",
        "role": "CUSTOMER"
    })
    cust_token = cust_res.json()["access_token"]

    # Register admin
    admin_res = client.post("/api/v1/auth/register", json={
        "email": "masteradmin@example.com",
        "full_name": "Master Admin",
        "password": "AdminPassword123!",
        "role": "ADMIN"
    })
    admin_token = admin_res.json()["access_token"]

    event_payload = {
        "name": "Cloud Expo Flash Concert",
        "description": "Exclusive acoustic performance for developers.",
        "venue": "Innovation Amphitheater",
        "event_timestamp": (datetime.utcnow() + timedelta(days=20)).isoformat(),
        "total_capacity": 20,
        "available_capacity": 20,
        "status": "UPCOMING"
    }

    # Customer attempt -> 403 Forbidden
    cust_attempt = client.post(
        "/api/v1/events",
        json=event_payload,
        headers={"Authorization": f"Bearer {cust_token}"}
    )
    assert cust_attempt.status_code == 403

    # Admin attempt -> 201 Created
    admin_attempt = client.post(
        "/api/v1/events",
        json=event_payload,
        headers={"Authorization": f"Bearer {admin_token}"}
    )
    assert admin_attempt.status_code == 201
    created = admin_attempt.json()
    created_id = created["event_id"]

    # Verify seats were automatically generated
    seats_res = client.get(f"/api/v1/events/{created_id}/seats")
    assert seats_res.status_code == 200
    assert len(seats_res.json()) == 20

    # Admin updates status to ACTIVE
    patch_res = client.patch(
        f"/api/v1/events/{created_id}/status?new_status=ACTIVE",
        headers={"Authorization": f"Bearer {admin_token}"}
    )
    assert patch_res.status_code == 200
    assert patch_res.json()["status"] == "ACTIVE"
