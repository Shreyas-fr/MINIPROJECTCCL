from app.seed import seed_database


def test_virtual_waiting_room_fifo_and_admission(client, db_session):
    seed_database(db_session)

    # 1. Get active event
    events_res = client.get("/api/v1/events?status=ACTIVE")
    active_events = events_res.json()
    assert len(active_events) > 0
    event_id = active_events[0]["event_id"]

    # 2. Register User 1 & User 2
    u1_res = client.post("/api/v1/auth/register", json={
        "email": "user1@surge.io",
        "full_name": "User One",
        "password": "Password123!",
        "role": "CUSTOMER"
    })
    token1 = u1_res.json()["access_token"]

    u2_res = client.post("/api/v1/auth/register", json={
        "email": "user2@surge.io",
        "full_name": "User Two",
        "password": "Password123!",
        "role": "CUSTOMER"
    })
    token2 = u2_res.json()["access_token"]

    # 3. User 1 joins queue
    q1 = client.post(
        "/api/v1/queue/join",
        json={"event_id": event_id},
        headers={"Authorization": f"Bearer {token1}"}
    )
    assert q1.status_code == 200
    d1 = q1.json()
    assert d1["status"] == "WAITING"
    assert d1["position_ahead"] == 0

    # 4. User 2 joins queue
    q2 = client.post(
        "/api/v1/queue/join",
        json={"event_id": event_id},
        headers={"Authorization": f"Bearer {token2}"}
    )
    assert q2.status_code == 200
    d2 = q2.json()
    assert d2["status"] == "WAITING"
    assert d2["position_ahead"] == 1
    assert d2["queue_number"] > d1["queue_number"]

    # 5. Heartbeat from User 1
    hb = client.post(
        "/api/v1/queue/heartbeat",
        json={"queue_id": d1["queue_id"]},
        headers={"Authorization": f"Bearer {token1}"}
    )
    assert hb.status_code == 200
    assert hb.json()["status"] == "OK"

    # 6. Admin admits next batch of size 1
    admin_login = client.post("/api/v1/auth/login", json={
        "email": "admin@surgegate.internal",
        "password": "AdminPass123!"
    })
    admin_token = admin_login.json()["access_token"]

    admit_res = client.post(
        f"/api/v1/admin/queue/{event_id}/admit?batch_size=1",
        headers={"Authorization": f"Bearer {admin_token}"}
    )
    assert admit_res.status_code == 200
    assert admit_res.json()["admitted_count"] == 1

    # 7. Check User 1 status -> should now be ADMITTED with admission_token
    status1 = client.get(
        f"/api/v1/queue/{event_id}/status",
        headers={"Authorization": f"Bearer {token1}"}
    )
    assert status1.status_code == 200
    st1_data = status1.json()
    assert st1_data["status"] == "ADMITTED"
    assert st1_data["admission_token"] is not None
    assert st1_data["admission_expires_at"] is not None

    # 8. Check User 2 status -> still WAITING, but now position_ahead is 0!
    status2 = client.get(
        f"/api/v1/queue/{event_id}/status",
        headers={"Authorization": f"Bearer {token2}"}
    )
    assert status2.status_code == 200
    st2_data = status2.json()
    assert st2_data["status"] == "WAITING"
    assert st2_data["position_ahead"] == 0

    # 9. Admin checks queue metrics
    metrics = client.get(
        f"/api/v1/admin/queue/{event_id}/metrics",
        headers={"Authorization": f"Bearer {admin_token}"}
    )
    assert metrics.status_code == 200
    m_data = metrics.json()
    assert m_data["waiting_users"] == 1
    assert m_data["active_admitted_users"] == 1

    # 10. User 2 leaves queue
    leave = client.post(
        f"/api/v1/queue/{event_id}/leave",
        headers={"Authorization": f"Bearer {token2}"}
    )
    assert leave.status_code == 200
    assert leave.json()["status"] == "SUCCESS"
