import React, { useEffect, useState } from 'react';
import { Ticket, RefreshCw } from 'lucide-react';
import { Booking } from '../types';
import { api } from '../services/api';
import { useAuth } from '../context/AuthContext';

interface MyBookingsViewProps {
  onViewTicket: (booking: Booking) => void;
}

export const MyBookingsView: React.FC<MyBookingsViewProps> = ({ onViewTicket }) => {
  const { isAuthenticated } = useAuth();
  const [bookings, setBookings] = useState<Booking[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!isAuthenticated) {
      setLoading(false);
      return;
    }

    api.getMyBookings()
      .then((data) => {
        setBookings(data);
        setLoading(false);
      })
      .catch(() => {
        setLoading(false);
      });
  }, [isAuthenticated]);

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
      <div className="py-20 flex justify-center">
        <RefreshCw className="w-8 h-8 text-brand-400 animate-spin" />
      </div>
    );
  }

  if (bookings.length === 0) {
    return (
      <div className="max-w-xl mx-auto py-16 text-center">
        <div className="w-16 h-16 rounded-2xl bg-slate-900 border border-slate-800 text-slate-500 mx-auto flex items-center justify-center mb-4">
          <Ticket className="w-8 h-8" />
        </div>
        <h3 className="text-xl font-bold text-white mb-2">No bookings yet</h3>
        <p className="text-xs text-slate-400">Join a live flash-sale waiting room to reserve your first ticket!</p>
      </div>
    );
  }

  return (
    <div className="max-w-4xl mx-auto py-8 px-4 animate-fade-in">
      <div className="mb-6">
        <h2 className="text-2xl font-bold text-white">My E-Tickets & Passes</h2>
        <p className="text-xs text-slate-400 mt-1">Confirmed flash-sale bookings and verified SVG passes</p>
      </div>

      <div className="space-y-4">
        {bookings.map((b) => (
          <div
            key={b.booking_id}
            className="glass-card rounded-2xl p-6 border border-slate-800 flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4"
          >
            <div className="space-y-2">
              <div className="flex items-center space-x-2">
                <span className="font-mono text-xs font-bold text-brand-300 bg-brand-500/10 px-2.5 py-0.5 rounded-lg border border-brand-500/20">
                  {b.booking_ref}
                </span>
                <span
                  className={`px-2.5 py-0.5 rounded-full text-[11px] font-mono font-bold ${
                    b.status === 'CONFIRMED'
                      ? 'bg-emerald-500/20 text-emerald-300 border border-emerald-500/30'
                      : 'bg-amber-500/20 text-amber-300'
                  }`}
                >
                  {b.status}
                </span>
              </div>

              <div className="text-xs font-mono text-slate-400">
                Created: {b.created_at ? new Date(b.created_at).toLocaleString() : 'Just now'} • Total: ${(b.total_amount_cents / 100).toFixed(2)} USD
              </div>
            </div>

            <button
              onClick={() => onViewTicket(b)}
              className="px-4 py-2 rounded-xl bg-brand-600 hover:bg-brand-500 text-white font-semibold text-xs transition shadow-md shadow-brand-600/30 flex items-center space-x-1.5"
            >
              <Ticket className="w-4 h-4" />
              <span>View E-Ticket & QR</span>
            </button>
          </div>
        ))}
      </div>
    </div>
  );
};
