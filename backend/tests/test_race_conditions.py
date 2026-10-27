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
