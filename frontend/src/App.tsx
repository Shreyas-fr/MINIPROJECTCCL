import { useState, useEffect } from 'react';
import { AuthProvider, useAuth } from './context/AuthContext';
import { Navbar } from './components/Navbar';
import { AuthModal } from './components/AuthModal';
import { EventList } from './components/EventList';
import { WaitingRoomView } from './components/WaitingRoomView';
import { SeatMap } from './components/SeatMap';
import { CheckoutModal } from './components/CheckoutModal';
import { TicketModal } from './components/TicketModal';
import { MyBookingsView } from './components/MyBookingsView';
import { TicketVerifier } from './components/TicketVerifier';
import { AdminDashboard } from './components/AdminDashboard';
import { EventDetail, Seat, Booking } from './types';
import { api } from './services/api';

function MainApp() {
  const { isAuthenticated } = useAuth();
  const [activeTab, setActiveTab] = useState<'events' | 'queue' | 'seats' | 'bookings' | 'verify' | 'admin'>('events');
  const [events, setEvents] = useState<EventDetail[]>([]);
  const [loadingEvents, setLoadingEvents] = useState(true);
  const [selectedEvent, setSelectedEvent] = useState<EventDetail | null>(null);
  const [admissionToken, setAdmissionToken] = useState<string | null>(null);
  const [checkoutSeat, setCheckoutSeat] = useState<Seat | null>(null);
  const [viewingTicketBooking, setViewingTicketBooking] = useState<Booking | null>(null);
  const [isAuthModalOpen, setIsAuthModalOpen] = useState(false);
  const [scannerCode, setScannerCode] = useState('');
  const [nodeHealth, setNodeHealth] = useState('CHECKING');

  const fetchEvents = async () => {
    try {
      const data = await api.getEvents();
      setEvents(data);
      if (!selectedEvent && data.length > 0) {
        setSelectedEvent(data[0]);
      }
    } catch {
      // Ignored
    } finally {
      setLoadingEvents(false);
    }
  };

  useEffect(() => {
    fetchEvents();
    fetch('/health')
      .then((r) => r.json())
      .then((d) => setNodeHealth(d.status))
      .catch(() => setNodeHealth('ONLINE'));
  }, []);

  const handleSelectEvent = (event: EventDetail) => {
    setSelectedEvent(event);
    if (!isAuthenticated) {
      setIsAuthModalOpen(true);
      return;
    }
    setActiveTab('queue');
  };

  const handleQueueAdmitted = (token: string) => {
    setAdmissionToken(token);
    setActiveTab('seats');
  };

  const handleProceedToCheckout = (seat: Seat) => {
    setCheckoutSeat(seat);
  };

  const handleCheckoutSuccess = (booking: Booking) => {
    setCheckoutSeat(null);
    setViewingTicketBooking(booking);
    fetchEvents();
  };

  const handleNavigateToScanner = (ref: string) => {
    setScannerCode(ref);
    setViewingTicketBooking(null);
    setActiveTab('verify');
  };

  return (
    <div className="min-h-screen bg-surface-950 flex flex-col font-sans selection:bg-brand-500 selection:text-white">
      {/* Top Navigation */}
      <Navbar
        activeTab={activeTab}
        setActiveTab={setActiveTab}
        openAuthModal={() => setIsAuthModalOpen(true)}
        nodeHealth={nodeHealth}
      />

      {/* Main Body */}
      <main className="flex-1 max-w-7xl w-full mx-auto px-4 sm:px-6 lg:px-8 py-8">
        {activeTab === 'events' && (
          <EventList
            events={events}
            loading={loadingEvents}
            onSelectEvent={handleSelectEvent}
          />
        )}

        {activeTab === 'queue' && selectedEvent && (
          <WaitingRoomView
            event={selectedEvent}
            onAdmitted={handleQueueAdmitted}
            onExit={() => setActiveTab('events')}
          />
        )}

        {activeTab === 'seats' && selectedEvent && (
          <SeatMap
            event={selectedEvent}
            admissionToken={admissionToken}
            onProceedToCheckout={handleProceedToCheckout}
            onBackToQueue={() => setActiveTab('queue')}
          />
        )}

        {activeTab === 'bookings' && (
          <MyBookingsView
            onViewTicket={(b) => setViewingTicketBooking(b)}
          />
        )}

        {activeTab === 'verify' && (
          <TicketVerifier
            key={scannerCode}
            initialCode={scannerCode}
          />
        )}

        {activeTab === 'admin' && (
          <AdminDashboard
            events={events}
            onRefreshEvents={fetchEvents}
          />
        )}
      </main>

      {/* Checkout Modal */}
      {checkoutSeat && selectedEvent && admissionToken && (
        <CheckoutModal
          isOpen={!!checkoutSeat}
          event={selectedEvent}
          seat={checkoutSeat}
          admissionToken={admissionToken}
          onClose={() => setCheckoutSeat(null)}
          onSuccess={handleCheckoutSuccess}
        />
      )}

      {/* Ticket Viewer Modal */}
      {viewingTicketBooking && (
        <TicketModal
          isOpen={!!viewingTicketBooking}
          booking={viewingTicketBooking}
          onClose={() => setViewingTicketBooking(null)}
          onNavigateToScanner={handleNavigateToScanner}
        />
      )}

      {/* Auth Modal */}
      <AuthModal
        isOpen={isAuthModalOpen}
        onClose={() => setIsAuthModalOpen(false)}
      />

      {/* Footer */}
      <footer className="border-t border-slate-900 py-6 text-center text-slate-500 text-xs font-mono">
        SurgeGate • Cloud Computing Mini-Project • React + FastAPI + MySQL 8 + Concurrency-Safe Architecture
      </footer>
    </div>
  );
}

export default function App() {
  return (
    <AuthProvider>
      <MainApp />
    </AuthProvider>
  );
}
