import concurrent.futures
from app.seed import seed_database
from tests.test_booking_concurrency import _setup_admitted_user


def test_high_concurrency_race_condition_single_seat(client, db_session):
    """
    Spawns concurrent requests attempting to hold the exact same seat simultaneously.
    Validates anti-overselling guarantee: exactly 1 request succeeds, all others receive 409 Conflict.
    """
    seed_database(db_session)

    events_res = client.get("/api/v1/events?status=ACTIVE")
    event_id = events_res.json()[0]["event_id"]
    seats_res = client.get(f"/api/v1/events/{event_id}/seats")
    target_seat_id = seats_res.json()[2]["seat_id"]

    # Prepare 5 admitted users
    users = []
    for i in range(5):
        token, adm_token = _setup_admitted_user(client, f"racer{i}@example.com", event_id)
        users.append((token, adm_token))

    def attempt_hold(user_data):
        token, adm_token = user_data
        response = client.post(
            "/api/v1/seats/hold",
            json={
                "event_id": event_id,
                "seat_id": target_seat_id,
                "admission_token": adm_token
            },
            headers={"Authorization": f"Bearer {token}"}
        )
        return response.status_code, response.json()

    # Launch concurrent attempts simultaneously
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as executor:
        results = list(executor.map(attempt_hold, users))

    statuses = [r[0] for r in results]
    success_count = statuses.count(200)
    conflict_count = statuses.count(409)

    # STRICT ANTI-OVERSELLING ASSERTION:
    # Exactly ONE user must succeed in holding the seat
    assert success_count == 1, f"Expected exactly 1 success, got {success_count}. Overselling detected!"
    assert conflict_count == 4, f"Expected 4 conflicts, got {conflict_count}"


def test_high_concurrency_race_condition_multi_seat_atomic(client, db_session):
    """
    Two concurrent requests attempt to hold overlapping sets of seats:
    User A wants [Seat 0, Seat 1]
    User B wants [Seat 1, Seat 2]
    Seat 1 is contested. Exactly one user must successfully acquire their full requested reservation.
    The losing user must fail atomically (HTTP 409 Conflict) and NOT leak a hold on their non-contested seat.
    """
    seed_database(db_session)

    events_res = client.get("/api/v1/events?status=ACTIVE")
    event_id = events_res.json()[0]["event_id"]
    seats_res = client.get(f"/api/v1/events/{event_id}/seats").json()
    s0, s1, s2 = seats_res[0]["seat_id"], seats_res[1]["seat_id"], seats_res[2]["seat_id"]

    token_a, adm_a = _setup_admitted_user(client, "multi_racer_a@example.com", event_id)
    token_b, adm_b = _setup_admitted_user(client, "multi_racer_b@example.com", event_id)

    def attempt_a():
        return client.post("/api/v1/seats/hold", json={
            "event_id": event_id,
            "seat_ids": [s0, s1],
            "admission_token": adm_a
        }, headers={"Authorization": f"Bearer {token_a}"})

    def attempt_b():
        return client.post("/api/v1/seats/hold", json={
            "event_id": event_id,
            "seat_ids": [s1, s2],
            "admission_token": adm_b
        }, headers={"Authorization": f"Bearer {token_b}"})

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        f_a = executor.submit(attempt_a)
        f_b = executor.submit(attempt_b)
        res_a = f_a.result()
        res_b = f_b.result()

    statuses = [res_a.status_code, res_b.status_code]
    assert statuses.count(200) == 1, f"Expected exactly 1 success, got {statuses}"
    assert statuses.count(409) == 1, f"Expected exactly 1 conflict, got {statuses}"

    # Verify that the losing user's non-contested seat was NOT held (atomic all-or-nothing guarantee)
    final_seats = {s["seat_id"]: s for s in client.get(f"/api/v1/events/{event_id}/seats").json()}
    if res_a.status_code == 200:
        # A won [s0, s1]. s2 must remain AVAILABLE.
        assert final_seats[s0]["status"] == "RESERVED"
        assert final_seats[s1]["status"] == "RESERVED"
        assert final_seats[s2]["status"] == "AVAILABLE"
    else:
        # B won [s1, s2]. s0 must remain AVAILABLE.
        assert final_seats[s0]["status"] == "AVAILABLE"
        assert final_seats[s1]["status"] == "RESERVED"
        assert final_seats[s2]["status"] == "RESERVED"

