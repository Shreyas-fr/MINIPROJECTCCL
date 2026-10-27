import React, { useEffect, useState } from 'react';
import { Ticket, RefreshCw, Calendar, MapPin, QrCode, ArrowRight } from 'lucide-react';
import { Booking } from '../types';
import { api } from '../services/api';
import { useAuth } from '../context/AuthContext';

interface MyBookingsViewProps {
  onViewTicket: (booking: Booking) => void;
  onNavigateToScanner?: (ref: string) => void;
  onBrowseEvents?: () => void;
}

export const MyBookingsView: React.FC<MyBookingsViewProps> = ({ 
  onViewTicket,
  onNavigateToScanner,
  onBrowseEvents,
}) => {
  const { isAuthenticated } = useAuth();
  const [bookings, setBookings] = useState<Booking[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  const fetchBookings = async () => {
    try {
      const data = await api.getMyBookings();
      setBookings(data);
    } catch {
      // Ignored
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  };

  useEffect(() => {
    if (!isAuthenticated) {
      setLoading(false);
      return;
    }
    fetchBookings();
  }, [isAuthenticated]);

  const handleManualRefresh = () => {
    setRefreshing(true);
    fetchBookings();
  };

  if (!isAuthenticated) {
    return (
      <div className="max-w-xl mx-auto py-16 text-center">
        <div className="w-16 h-16 rounded-2xl bg-brand-500/10 text-brand-400 mx-auto flex items-center justify-center mb-4">
          <Ticket className="w-8 h-8" />
        </div>
        <h3 className="text-xl font-bold text-white mb-2">Sign in to view your bookings</h3>
        <p className="text-xs text-slate-400">Your confirmed tickets and waiting room history are linked to your account.</p>
      </div>
    );
  }

  if (loading) {
    return (
      <div className="py-20 flex flex-col items-center justify-center space-y-3">
        <RefreshCw className="w-8 h-8 text-brand-400 animate-spin" />
        <p className="text-xs text-slate-400 font-mono">Loading your confirmed passes...</p>
      </div>
    );
  }

  if (bookings.length === 0) {
    return (
      <div className="max-w-xl mx-auto py-16 text-center animate-fade-in">
        <div className="w-16 h-16 rounded-2xl bg-slate-900 border border-slate-800 text-slate-500 mx-auto flex items-center justify-center mb-4">
          <Ticket className="w-8 h-8" />
        </div>
        <h3 className="text-xl font-bold text-white mb-2">No bookings yet</h3>
        <p className="text-xs text-slate-400 mb-6">Join a live flash-sale waiting room to reserve your first ticket!</p>
        {onBrowseEvents && (
          <button
            onClick={onBrowseEvents}
            className="px-5 py-2.5 rounded-xl bg-gradient-to-r from-brand-600 to-indigo-600 hover:from-brand-500 hover:to-indigo-500 text-white font-bold text-xs shadow-lg shadow-brand-600/30 transition inline-flex items-center space-x-2"
          >
            <span>Browse Flash-Sale Events</span>
            <ArrowRight className="w-4 h-4" />
          </button>
        )}
      </div>
    );
  }

  return (
    <div className="max-w-4xl mx-auto py-8 px-4 animate-fade-in">
      <div className="flex items-center justify-between mb-6">
        <div>
          <h2 className="text-2xl font-bold text-white">My E-Tickets & Passes</h2>
          <p className="text-xs text-slate-400 mt-1">Confirmed flash-sale bookings and verified SVG passes</p>
        </div>
        <button
          onClick={handleManualRefresh}
          disabled={refreshing}
          className="p-2.5 rounded-xl bg-slate-900 border border-slate-800 hover:border-slate-700 text-slate-300 hover:text-white transition flex items-center space-x-1.5 text-xs font-mono"
        >
          <RefreshCw className={`w-3.5 h-3.5 ${refreshing ? 'animate-spin text-brand-400' : ''}`} />
          <span className="hidden sm:inline">Refresh</span>
        </button>
      </div>

      <div className="space-y-4">
        {bookings.map((b) => (
          <div
            key={b.booking_id}
            className="glass-card rounded-2xl p-6 border border-slate-800/80 hover:border-brand-500/30 transition flex flex-col md:flex-row items-start md:items-center justify-between gap-4"
          >
            <div className="space-y-2 flex-1">
              <div className="flex flex-wrap items-center gap-2">
                <span className="font-mono text-xs font-bold text-brand-300 bg-brand-500/10 px-2.5 py-0.5 rounded-lg border border-brand-500/20">
                  {b.booking_ref}
                </span>
                <span
                  className={`px-2.5 py-0.5 rounded-full text-[11px] font-mono font-bold ${
                    b.status === 'CONFIRMED'
                      ? 'bg-emerald-500/20 text-emerald-300 border border-emerald-500/30'
                      : 'bg-amber-500/20 text-amber-300 border border-amber-500/30'
                  }`}
                >
                  {b.status}
                </span>
                {b.ticket_id && (
                  <span className="font-mono text-[11px] text-slate-400 bg-slate-900 px-2 py-0.5 rounded border border-slate-800">
                    {b.ticket_id}
                  </span>
                )}
              </div>

              {/* Event Name & Venue */}
              <div>
                <h4 className="text-base font-bold text-white">
                  {b.event_name || 'SurgeGate Event'}
                </h4>
                <div className="flex flex-wrap items-center gap-3 text-xs text-slate-400 font-mono mt-1">
                  {b.venue && (
                    <span className="flex items-center space-x-1">
                      <MapPin className="w-3.5 h-3.5 text-brand-400" />
                      <span>{b.venue}</span>
                    </span>
                  )}
                  {b.event_timestamp && (
                    <span className="flex items-center space-x-1">
                      <Calendar className="w-3.5 h-3.5 text-indigo-400" />
                      <span>{new Date(b.event_timestamp).toLocaleDateString()}</span>
                    </span>
                  )}
                  {b.seat_info && (
                    <span className="text-emerald-400 font-semibold bg-emerald-500/10 px-2 py-0.5 rounded">
                      {b.seat_info}
                    </span>
                  )}
                </div>
              </div>

              <div className="text-xs font-mono text-slate-500 pt-1">
                Issued: {b.created_at ? new Date(b.created_at).toLocaleString() : 'Just now'} • Paid: ${(b.total_amount_cents / 100).toFixed(2)} USD
              </div>
            </div>

            {/* Actions */}
            <div className="flex items-center space-x-2 w-full md:w-auto">
              {b.status === 'CONFIRMED' && (
                <>
                  <button
                    onClick={() => onViewTicket(b)}
                    className="flex-1 md:flex-initial px-4 py-2 rounded-xl bg-brand-600 hover:bg-brand-500 text-white font-semibold text-xs transition shadow-md shadow-brand-600/30 flex items-center justify-center space-x-1.5"
                  >
                    <Ticket className="w-4 h-4" />
                    <span>View Pass & QR</span>
                  </button>

                  {onNavigateToScanner && (
                    <button
                      onClick={() => onNavigateToScanner(b.booking_ref)}
                      title="Test Gate Verification"
                      className="p-2 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-300 hover:text-white border border-slate-700 transition"
                    >
                      <QrCode className="w-4 h-4" />
                    </button>
                  )}
                </>
              )}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
};
