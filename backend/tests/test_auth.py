def test_customer_registration(client):
    payload = {
        "email": "newcustomer@example.com",
        "full_name": "New Customer",
        "password": "SecurePassword123!",
        "role": "CUSTOMER"
    }
    response = client.post("/api/v1/auth/register", json=payload)
    assert response.status_code == 201
    data = response.json()
    assert "access_token" in data
    assert data["token_type"] == "bearer"
    assert data["user"]["email"] == "newcustomer@example.com"
    assert data["user"]["role"] == "CUSTOMER"


def test_duplicate_email_registration_fails(client):
    payload = {
        "email": "duplicate@example.com",
        "full_name": "Duplicate User",
        "password": "Password123!",
        "role": "CUSTOMER"
    }
    res1 = client.post("/api/v1/auth/register", json=payload)
    assert res1.status_code == 201

    res2 = client.post("/api/v1/auth/register", json=payload)
    assert res2.status_code == 400
    assert "already exists" in res2.json()["detail"]


def test_login_success_and_failure(client):
    # Register user first
    payload = {
        "email": "loginuser@example.com",
        "full_name": "Login User",
        "password": "MySecretPassword123!",
        "role": "CUSTOMER"
    }
    client.post("/api/v1/auth/register", json=payload)

    # Success login
    login_res = client.post("/api/v1/auth/login", json={
        "email": "loginuser@example.com",
        "password": "MySecretPassword123!"
    })
    assert login_res.status_code == 200
    token = login_res.json()["access_token"]
    assert token

    # Failed login with wrong password
    bad_res = client.post("/api/v1/auth/login", json={
        "email": "loginuser@example.com",
        "password": "WrongPassword!"
    })
    assert bad_res.status_code == 401


def test_auth_me_endpoint(client):
    payload = {
        "email": "profile@example.com",
        "full_name": "Profile User",
        "password": "Password123!",
        "role": "CUSTOMER"
    }
    reg = client.post("/api/v1/auth/register", json=payload)
    token = reg.json()["access_token"]

    # Without token -> 401
    unauth = client.get("/api/v1/auth/me")
    assert unauth.status_code == 401

    # With valid token -> 200
    auth = client.get("/api/v1/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert auth.status_code == 200
    user_data = auth.json()
    assert user_data["email"] == "profile@example.com"
    assert user_data["full_name"] == "Profile User"
