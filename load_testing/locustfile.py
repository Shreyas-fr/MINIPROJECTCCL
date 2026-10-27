import random
import uuid
from locust import HttpUser, task, between


class SurgeGateCustomerUser(HttpUser):
    wait_time = between(0.5, 2.0)

    def on_start(self):
        """Register and authenticate user for the flash sale rush"""
        self.user_email = f"loadtest_{uuid.uuid4().hex[:8]}@example.com"
        self.password = "LoadPass123!"
        self.token = None
        self.headers = {}
        self.admission_token = None
        self.event_id = None
        self.selected_seat_id = None
        self.booking_id = None
        self.booking_ref = None

        res = self.client.post("/api/v1/auth/register", json={
            "email": self.user_email,
            "full_name": f"Tester {self.user_email.split('@')[0]}",
            "password": self.password,
            "role": "CUSTOMER"
        })
        if res.status_code == 201:
            self.token = res.json().get("access_token")
            self.headers = {"Authorization": f"Bearer {self.token}"}

    @task(3)
    def browse_events(self):
        """User browses live events catalog"""
        res = self.client.get("/api/v1/events", name="/api/v1/events")
        if res.status_code == 200:
            events = res.json()
            active_events = [e for e in events if e.get("status") == "ACTIVE"]
            if active_events:
                self.event_id = active_events[0]["event_id"]

    @task(5)
    def enter_waiting_room_and_poll(self):
        """User joins queue and maintains position via heartbeats"""
        if not self.event_id or not self.token:
            return

        # 1. Join Queue
        join_res = self.client.post(
            "/api/v1/queue/join",
            json={"event_id": self.event_id},
            headers=self.headers,
            name="/api/v1/queue/join"
        )
        if join_res.status_code != 200:
            return

        q_data = join_res.json()
        queue_id = q_data.get("queue_id")

        # 2. Heartbeat
        if queue_id:
            self.client.post(
                "/api/v1/queue/heartbeat",
                json={"queue_id": queue_id},
                headers=self.headers,
                name="/api/v1/queue/heartbeat"
            )

        # 3. Poll status
        status_res = self.client.get(
            f"/api/v1/queue/{self.event_id}/status",
            headers=self.headers,
            name="/api/v1/queue/[event_id]/status"
        )
        if status_res.status_code == 200:
            s_data = status_res.json()
            if s_data.get("status") == "ADMITTED":
                self.admission_token = s_data.get("admission_token")

    @task(2)
    def seat_reservation_and_checkout(self):
        """Admitted user selects seats and completes simulated checkout"""
        if not self.event_id or not self.admission_token or not self.token:
            return

        # 1. Fetch available seats
        seats_res = self.client.get(
            f"/api/v1/events/{self.event_id}/seats",
            name="/api/v1/events/[event_id]/seats"
        )
        if seats_res.status_code != 200:
            return

        available_seats = [s for s in seats_res.json() if s.get("status") == "AVAILABLE"]
        if not available_seats:
            return

        target_seat = random.choice(available_seats)
        self.selected_seat_id = target_seat["seat_id"]

        # 2. Attempt atomic hold
        hold_res = self.client.post(
            "/api/v1/seats/hold",
            json={
                "event_id": self.event_id,
                "seat_id": self.selected_seat_id,
                "admission_token": self.admission_token
            },
            headers=self.headers,
            name="/api/v1/seats/hold"
        )

        # Handle 409 Conflict gracefully (Anti-overselling working as expected)
        if hold_res.status_code != 200:
            return

        # 3. Create booking with idempotency key
        idem_key = f"locust-{uuid.uuid4().hex}"
        booking_res = self.client.post(
            "/api/v1/bookings",
            json={
                "event_id": self.event_id,
                "seat_id": self.selected_seat_id,
                "idempotency_key": idem_key,
                "admission_token": self.admission_token
            },
            headers=self.headers,
            name="/api/v1/bookings"
        )

        if booking_res.status_code == 201:
            b_data = booking_res.json()
            self.booking_id = b_data.get("booking_id")
            self.booking_ref = b_data.get("booking_ref")

            # 4. Complete mock checkout
            pay_key = f"pay-{idem_key}"
            pay_res = self.client.post(
                "/api/v1/bookings/checkout",
                json={
                    "booking_id": self.booking_id,
                    "idempotency_key": pay_key,
                    "simulate_failure": False
                },
                headers=self.headers,
                name="/api/v1/bookings/checkout"
            )

            # 5. Fetch QR e-ticket asset
            if pay_res.status_code == 200 and self.booking_ref:
                self.client.get(
                    f"/api/v1/tickets/{self.booking_ref}",
                    name="/api/v1/tickets/[booking_ref]"
                )
