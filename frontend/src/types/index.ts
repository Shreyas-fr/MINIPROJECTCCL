export interface User {
  user_id: string;
  email: string;
  full_name: string;
  role: 'CUSTOMER' | 'ADMIN';
  created_at?: string;
}

export interface AuthResponse {
  access_token: string;
  token_type: string;
  user: User;
}

export interface Seat {
  seat_id: string;
  event_id: string;
  section: string;
  row_number: string;
  seat_number: string;
  price_cents: number;
  status: 'AVAILABLE' | 'RESERVED' | 'BOOKED';
  reserved_by?: string | null;
  reserved_until?: string | null;
  version: number;
}

export interface EventDetail {
  event_id: string;
  name: string;
  description?: string;
  venue: string;
  event_timestamp: string;
  total_capacity: number;
  available_capacity: number;
  status: 'UPCOMING' | 'ACTIVE' | 'SOLD_OUT' | 'COMPLETED';
  min_price_cents?: number;
  max_price_cents?: number;
  seats?: Seat[];
  created_at?: string;
  updated_at?: string;
}

export interface QueueStatus {
  queue_id: string;
  event_id: string;
  status: 'WAITING' | 'ADMITTED' | 'EXPIRED' | 'LEFT';
  queue_number: number;
  position_ahead: number;
  estimated_wait_seconds: number;
  admission_token?: string | null;
  admission_expires_at?: string | null;
  total_waiting: number;
}

export interface Booking {
  booking_id: string;
  booking_ref: string;
  idempotency_key: string;
  user_id: string;
  event_id: string;
  seat_id: string;
  total_amount_cents: number;
  status: 'PENDING_PAYMENT' | 'CONFIRMED' | 'CANCELLED' | 'EXPIRED';
  ticket_id?: string | null;
  ticket_s3_url?: string | null;
  created_at?: string;
  updated_at?: string;
  event_name?: string;
  venue?: string;
  event_timestamp?: string;
  seat_info?: string;
  section?: string;
  row_number?: string;
  seat_number?: string;
  booking_ids?: string[];
  bookings?: Booking[];
}

export interface PaymentResult {
  payment_id: string;
  transaction_ref: string;
  booking_id: string;
  amount_cents: number;
  status: string;
  message: string;
  booking_ids?: string[];
}

export interface TicketVerification {
  is_valid: boolean;
  ticket_id: string;
  booking_ref: string;
  event_name: string;
  event_timestamp: string;
  venue: string;
  section: string;
  row_number: string;
  seat_number: string;
  attendee_name: string;
  status: string;
}

export interface AdminOverview {
  total_events: number;
  active_flash_sales: number;
  total_registered_users: number;
  total_bookings: number;
  confirmed_bookings: number;
  total_revenue_cents: number;
  active_seat_holds: number;
  timestamp: string;
}
