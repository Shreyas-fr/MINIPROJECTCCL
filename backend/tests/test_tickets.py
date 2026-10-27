import uuid
from app.seed import seed_database
from app.services.ticket_processor import generate_qr_svg, TicketProcessorService
from app.adapters.storage import LocalStorageAdapter


def test_svg_qr_generator_format():
    svg = generate_qr_svg("TICK-12345", "SG-ABCD", "VIP-A-01")
    assert "<svg" in svg
    assert "SURGEGATE E-TICKET" in svg
    assert "SG-ABCD" in svg
    assert "TICK-12345" in svg
    assert "VIP-A-01" in svg


def test_local_storage_adapter(tmp_path):
    adapter = LocalStorageAdapter(base_dir=str(tmp_path))
    content = "<svg>Test Ticket</svg>"
    url = adapter.save_ticket("SG-TEST-REF", "TICK-TEST-1", content)
    assert "/storage/tickets/SG-TEST-REF/TICK-TEST-1.svg" in url

    retrieved = adapter.get_ticket("SG-TEST-REF", "TICK-TEST-1")
    assert retrieved == content


def test_ticket_generation_retrieval_and_verification(client, db_session):
    seed_database(db_session)

    # 1. Register & Admit customer
    event_res = client.get("/api/v1/events?status=ACTIVE")
    event_id = event_res.json()[0]["event_id"]
    seats_res = client.get(f"/api/v1/events/{event_id}/seats")
    seat_id = seats_res.json()[0]["seat_id"]

    reg = client.post("/api/v1/auth/register", json={
        "email": "ticketuser@example.com",
        "full_name": "Ticket Attendee",
        "password": "Password123!",
        "role": "CUSTOMER"
    })
    token = reg.json()["access_token"]

    # Join queue & admit
    client.post("/api/v1/queue/join", json={"event_id": event_id}, headers={"Authorization": f"Bearer {token}"})
    admin_login = client.post("/api/v1/auth/login", json={"email": "admin@surgegate.internal", "password": "AdminPass123!"})
    client.post(f"/api/v1/admin/queue/{event_id}/admit?batch_size=5", headers={"Authorization": f"Bearer {admin_login.json()['access_token']}"})

    adm_token = client.get(f"/api/v1/queue/{event_id}/status", headers={"Authorization": f"Bearer {token}"}).json()["admission_token"]

    # 2. Hold seat & Book
    client.post("/api/v1/seats/hold", json={"event_id": event_id, "seat_id": seat_id, "admission_token": adm_token}, headers={"Authorization": f"Bearer {token}"})
    booking_res = client.post("/api/v1/bookings", json={
        "event_id": event_id,
        "seat_id": seat_id,
        "idempotency_key": "ticket-flow-idem-key",
        "admission_token": adm_token
    }, headers={"Authorization": f"Bearer {token}"})
    booking_id = booking_res.json()["booking_id"]
    booking_ref = booking_res.json()["booking_ref"]

    # 3. Checkout
    checkout_res = client.post("/api/v1/bookings/checkout", json={
        "booking_id": booking_id,
        "idempotency_key": "pay-ticket-key",
        "simulate_failure": False
    }, headers={"Authorization": f"Bearer {token}"})
    assert checkout_res.status_code == 200

    # 4. Fetch Ticket SVG
    ticket_svg_res = client.get(f"/api/v1/tickets/{booking_ref}")
    assert ticket_svg_res.status_code == 200
    assert ticket_svg_res.headers["content-type"] == "image/svg+xml"
    assert "SURGEGATE E-TICKET" in ticket_svg_res.text
    assert booking_ref in ticket_svg_res.text

    # 5. Verify Ticket at Gate
    verify_res = client.post("/api/v1/tickets/verify", json={"ticket_id_or_ref": booking_ref})
    assert verify_res.status_code == 200
    v_data = verify_res.json()
    assert v_data["is_valid"] is True
    assert v_data["booking_ref"] == booking_ref
    assert v_data["attendee_name"] == "Ticket Attendee"
    assert v_data["status"] == "CONFIRMED"

    # 6. Verify non-existent ticket
    invalid_verify = client.post("/api/v1/tickets/verify", json={"ticket_id_or_ref": "SG-FAKE-REF"})
    assert invalid_verify.status_code == 200
    assert invalid_verify.json()["is_valid"] is False
