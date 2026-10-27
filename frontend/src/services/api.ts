import { 
  AuthResponse, 
  EventDetail, 
  Seat, 
  QueueStatus, 
  Booking, 
  PaymentResult, 
  TicketVerification, 
  AdminOverview 
} from '../types';

const API_BASE = '/api/v1';

function getAuthHeader(): Record<string, string> {
  const token = localStorage.getItem('surgegate_token');
  return token ? { Authorization: `Bearer ${token}` } : {};
}

async function handleResponse<T>(res: Response): Promise<T> {
  if (!res.ok) {
    let errDetail = 'Request failed';
    try {
      const data = await res.json();
      errDetail = data.detail || data.message || errDetail;
    } catch {
      errDetail = await res.text() || errDetail;
    }
    throw new Error(errDetail);
  }
  return res.json();
}

export const api = {
  // Auth
  async register(data: { email: string; full_name: string; password: string; role?: string }): Promise<AuthResponse> {
    const res = await fetch(`${API_BASE}/auth/register`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data),
    });
    return handleResponse<AuthResponse>(res);
  },

  async login(data: { email: string; password: string }): Promise<AuthResponse> {
    const res = await fetch(`${API_BASE}/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data),
    });
    return handleResponse<AuthResponse>(res);
  },

  async getMe(): Promise<any> {
    const res = await fetch(`${API_BASE}/auth/me`, {
      headers: { ...getAuthHeader() },
    });
    return handleResponse(res);
  },

  // Events
  async getEvents(status?: string): Promise<EventDetail[]> {
    const url = status ? `${API_BASE}/events?status=${status}` : `${API_BASE}/events`;
    const res = await fetch(url);
    return handleResponse<EventDetail[]>(res);
  },

  async getEventDetail(eventId: string): Promise<EventDetail> {
    const res = await fetch(`${API_BASE}/events/${eventId}`);
    return handleResponse<EventDetail>(res);
  },

  async getEventSeats(eventId: string): Promise<Seat[]> {
    const res = await fetch(`${API_BASE}/events/${eventId}/seats`);
    return handleResponse<Seat[]>(res);
  },

  async updateEventStatus(eventId: string, newStatus: string): Promise<EventDetail> {
    const res = await fetch(`${API_BASE}/events/${eventId}/status?new_status=${newStatus}`, {
      method: 'PATCH',
      headers: { ...getAuthHeader() },
    });
    return handleResponse<EventDetail>(res);
  },

  // Virtual Waiting Room
  async joinQueue(eventId: string): Promise<QueueStatus> {
    const res = await fetch(`${API_BASE}/queue/join`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...getAuthHeader() },
      body: JSON.stringify({ event_id: eventId }),
    });
    return handleResponse<QueueStatus>(res);
  },

  async getQueueStatus(eventId: string): Promise<QueueStatus> {
    const res = await fetch(`${API_BASE}/queue/${eventId}/status`, {
      headers: { ...getAuthHeader() },
    });
    return handleResponse<QueueStatus>(res);
  },

  async sendHeartbeat(queueId: string): Promise<any> {
    const res = await fetch(`${API_BASE}/queue/heartbeat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...getAuthHeader() },
      body: JSON.stringify({ queue_id: queueId }),
    });
    return handleResponse(res);
  },

  // Token Storage Helpers (sessionStorage persistence per event)
  getStoredAdmissionToken(eventId: string): string | null {
    try {
      return sessionStorage.getItem(`surgegate_admission_${eventId}`);
    } catch {
      return null;
    }
  },

  setStoredAdmissionToken(eventId: string, token: string): void {
    try {
      sessionStorage.setItem(`surgegate_admission_${eventId}`, token);
    } catch {
      // Ignored
    }
  },

  clearStoredAdmissionToken(eventId: string): void {
    try {
      sessionStorage.removeItem(`surgegate_admission_${eventId}`);
    } catch {
      // Ignored
    }
  },

  async leaveQueue(eventId: string): Promise<any> {
    this.clearStoredAdmissionToken(eventId);
    const res = await fetch(`${API_BASE}/queue/${eventId}/leave`, {
      method: 'POST',
      headers: { ...getAuthHeader() },
    });
    return handleResponse(res);
  },

  // Seat Reservation (Single or Multiple Seats)
  async holdSeat(eventId: string, seatIdOrIds: string | string[], admissionToken: string): Promise<any> {
    const payload: Record<string, any> = {
      event_id: eventId,
      admission_token: admissionToken,
    };
    if (Array.isArray(seatIdOrIds)) {
      payload.seat_ids = seatIdOrIds;
    } else {
      payload.seat_id = seatIdOrIds;
    }

    const res = await fetch(`${API_BASE}/seats/hold`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...getAuthHeader() },
      body: JSON.stringify(payload),
    });
    return handleResponse(res);
  },

  async holdSeats(eventId: string, seatIds: string[], admissionToken: string): Promise<any> {
    return this.holdSeat(eventId, seatIds, admissionToken);
  },

  async releaseSeat(eventId: string, seatId?: string): Promise<any> {
    const url = seatId 
      ? `${API_BASE}/seats/release?event_id=${eventId}&seat_id=${seatId}`
      : `${API_BASE}/seats/release?event_id=${eventId}`;
    const res = await fetch(url, {
      method: 'POST',
      headers: { ...getAuthHeader() },
    });
    return handleResponse(res);
  },

  // Bookings & Mock Checkout
  async createBooking(
    eventId: string, 
    seatIdOrIds: string | string[], 
    idempotencyKey: string, 
    admissionToken: string
  ): Promise<Booking> {
    const payload: Record<string, any> = {
      event_id: eventId,
      idempotency_key: idempotencyKey,
      admission_token: admissionToken,
    };
    if (Array.isArray(seatIdOrIds)) {
      payload.seat_ids = seatIdOrIds;
    } else {
      payload.seat_id = seatIdOrIds;
    }

    const res = await fetch(`${API_BASE}/bookings`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...getAuthHeader() },
      body: JSON.stringify(payload),
    });
    return handleResponse<Booking>(res);
  },

  async checkout(
    bookingIdOrIds: string | string[], 
    idempotencyKey: string, 
    simulateFailure = false
  ): Promise<PaymentResult> {
    const payload: Record<string, any> = {
      idempotency_key: idempotencyKey,
      simulate_failure: simulateFailure,
      payment_method: 'SIMULATED_CARD',
    };
    if (Array.isArray(bookingIdOrIds)) {
      payload.booking_ids = bookingIdOrIds;
    } else {
      payload.booking_id = bookingIdOrIds;
    }

    const res = await fetch(`${API_BASE}/bookings/checkout`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...getAuthHeader() },
      body: JSON.stringify(payload),
    });
    return handleResponse<PaymentResult>(res);
  },

  async getMyBookings(): Promise<Booking[]> {
    const res = await fetch(`${API_BASE}/bookings/my`, {
      headers: { ...getAuthHeader() },
    });
    return handleResponse<Booking[]>(res);
  },

  // Tickets
  getTicketSvgUrl(bookingRef: string): string {
    return `${API_BASE}/tickets/${bookingRef}`;
  },

  async verifyTicket(ticketIdOrRef: string): Promise<TicketVerification> {
    const res = await fetch(`${API_BASE}/tickets/verify`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ ticket_id_or_ref: ticketIdOrRef }),
    });
    return handleResponse<TicketVerification>(res);
  },

  // Admin
  async getAdminOverview(): Promise<AdminOverview> {
    const res = await fetch(`${API_BASE}/admin/overview`, {
      headers: { ...getAuthHeader() },
    });
    return handleResponse<AdminOverview>(res);
  },

  async getAdminQueueMetrics(eventId: string): Promise<any> {
    const res = await fetch(`${API_BASE}/admin/queue/${eventId}/metrics`, {
      headers: { ...getAuthHeader() },
    });
    return handleResponse(res);
  },

  async admitQueueBatch(eventId: string, batchSize = 5): Promise<any> {
    const res = await fetch(`${API_BASE}/admin/queue/${eventId}/admit?batch_size=${batchSize}`, {
      method: 'POST',
      headers: { ...getAuthHeader() },
    });
    return handleResponse(res);
  },
};
