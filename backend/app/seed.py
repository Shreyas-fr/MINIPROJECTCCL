from datetime import datetime, timedelta
import uuid
from sqlalchemy.orm import Session
from app.core.database import SessionLocal, engine, Base
from app.core.security import get_password_hash
from app.models import User, Event, Seat, Booking, Payment


def seed_database(db: Session) -> None:
    # 1. Create Default Users
    users_data = [
        {
            "user_id": str(uuid.uuid4()),
            "email": "admin@surgegate.internal",
            "full_name": "SurgeGate Administrator",
            "password": "AdminPass123!",
            "role": "ADMIN"
        },
        {
            "user_id": str(uuid.uuid4()),
            "email": "student@example.edu",
            "full_name": "Alex Morgan",
            "password": "StudentPass123!",
            "role": "CUSTOMER"
        },
        {
            "user_id": str(uuid.uuid4()),
            "email": "attendee@surgegate.internal",
            "full_name": "Jordan Lee",
            "password": "AttendeePass123!",
            "role": "CUSTOMER"
        }
    ]

    created_users = {}
    for u in users_data:
        existing = db.query(User).filter(User.email == u["email"]).first()
        if not existing:
            new_user = User(
                user_id=u["user_id"],
                email=u["email"],
                full_name=u["full_name"],
                password_hash=get_password_hash(u["password"]),
                role=u["role"],
                created_at=datetime.utcnow()
            )
            db.add(new_user)
            db.flush()
            created_users[u["email"]] = new_user
        else:
            created_users[u["email"]] = existing

    # 2. Create Events and Realistic Seat Maps
    events_spec = [
        {
            "name": "Neon Waves Electro-Fest 2026",
            "description": "The premier electronic music festival with immersive lasers, 360-degree spatial audio, and world-class live producers. Strict virtual waiting room in effect for high-demand tier sales.",
            "venue": "Cyber Arena Main Amphitheater, Mumbai",
            "days_ahead": 30,
            "status": "ACTIVE",
            "sections": [
                {"name": "VIP Lounge", "rows": ["VIP-A", "VIP-B"], "seats_per_row": 10, "price_cents": 25000},
                {"name": "Front Center", "rows": ["FC-A", "FC-B"], "seats_per_row": 10, "price_cents": 15000},
                {"name": "General Floor", "rows": ["GA-A", "GA-B"], "seats_per_row": 10, "price_cents": 7500},
            ]
        },
        {
            "name": "National Cyber League Grand Finals 2026",
            "description": "Top 8 collegiate ethical hacking and cyber defense teams clash live on stage in a high-stakes capture-the-flag showdown with live exploit visualizers.",
            "venue": "Metropolis Esports Dome, Bangalore",
            "days_ahead": 45,
            "status": "UPCOMING",
            "sections": [
                {"name": "Courtside Cyberpit", "rows": ["CP-1", "CP-2"], "seats_per_row": 10, "price_cents": 8000},
                {"name": "Grandstand Arena", "rows": ["GS-1", "GS-2"], "seats_per_row": 10, "price_cents": 4500},
            ]
        },
        {
            "name": "TechXelerate Collegiate Cloud & AI Summit",
            "description": "Flagship engineering summit showcasing cloud microservices, reactive high-throughput architectures, and autonomous AI systems.",
            "venue": "Auditorium Alpha, Tech Campus",
            "days_ahead": 14,
            "status": "ACTIVE",
            "sections": [
                {"name": "Delegates Row", "rows": ["DEL-1", "DEL-2"], "seats_per_row": 10, "price_cents": 3500},
                {"name": "Student Gallery", "rows": ["STU-1"], "seats_per_row": 10, "price_cents": 1500},
            ]
        }
    ]

    for spec in events_spec:
        existing_event = db.query(Event).filter(Event.name == spec["name"]).first()
        if existing_event:
            continue

        total_seats = 0
        seats_to_insert = []
        event_id = str(uuid.uuid4())
        event_time = datetime.utcnow() + timedelta(days=spec["days_ahead"])

        for sec in spec["sections"]:
            for row in sec["rows"]:
                for seat_idx in range(1, sec["seats_per_row"] + 1):
                    total_seats += 1
                    seat_num = f"{seat_idx:02d}"
                    seat = Seat(
                        seat_id=str(uuid.uuid4()),
                        event_id=event_id,
                        section=sec["name"],
                        row_number=row,
                        seat_number=seat_num,
                        price_cents=sec["price_cents"],
                        status="AVAILABLE",
                        version=1,
                        created_at=datetime.utcnow()
                    )
                    seats_to_insert.append(seat)

        new_event = Event(
            event_id=event_id,
            name=spec["name"],
            description=spec["description"],
            venue=spec["venue"],
            event_timestamp=event_time,
            total_capacity=total_seats,
            available_capacity=total_seats,
            status=spec["status"],
            created_at=datetime.utcnow()
        )
        db.add(new_event)
        db.flush()

        for s in seats_to_insert:
            db.add(s)

    db.commit()
    print("Database seeding completed successfully.")


if __name__ == "__main__":
    Base.metadata.create_all(bind=engine)
    with SessionLocal() as session:
        seed_database(session)
