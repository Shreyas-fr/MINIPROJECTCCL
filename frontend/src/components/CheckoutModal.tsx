import React, { useState } from 'react';
import { X, CreditCard, ShieldCheck, AlertTriangle, ArrowRight, RefreshCw } from 'lucide-react';
import { EventDetail, Seat, Booking } from '../types';
import { api } from '../services/api';

interface CheckoutModalProps {
  isOpen: boolean;
  event: EventDetail;
  seat: Seat;
  admissionToken: string;
  onClose: () => void;
  onSuccess: (booking: Booking) => void;
}

export const CheckoutModal: React.FC<CheckoutModalProps> = ({
  isOpen,
  event,
  seat,
  admissionToken,
  onClose,
  onSuccess,
}) => {
  const [simulateFailure, setSimulateFailure] = useState(false);
  const [idempotencyKey] = useState(`idem-${Date.now()}-${Math.random().toString(36).substring(2, 7)}`);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (!isOpen) return null;

  const handlePay = async () => {
    setError(null);
    setLoading(true);

    try {
      // 1. Create Booking (Pending Payment)
      const booking = await api.createBooking(
        event.event_id,
        seat.seat_id,
        idempotencyKey,
        admissionToken
      );

      // 2. Process Simulated Checkout
      const paymentRes = await api.checkout(
        booking.booking_id,
        `pay-${idempotencyKey}`,
        simulateFailure
      );

      if (paymentRes.status === 'SUCCESS') {
        booking.status = 'CONFIRMED';
        onSuccess(booking);
      }
    } catch (err: any) {
      setError(err.message || 'Payment processing failed');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-md animate-fade-in">
      <div className="relative w-full max-w-lg rounded-3xl glass-card border border-brand-500/30 p-6 sm:p-8 shadow-2xl">
        <button
          onClick={onClose}
          className="absolute top-4 right-4 p-1.5 rounded-lg text-slate-400 hover:text-white hover:bg-slate-800 transition"
        >
          <X className="w-5 h-5" />
        </button>

        <div className="flex items-center space-x-3 mb-6">
          <div className="w-12 h-12 rounded-2xl bg-brand-500/20 text-brand-400 border border-brand-500/30 flex items-center justify-center">
            <CreditCard className="w-6 h-6" />
          </div>
          <div>
            <h3 className="text-xl font-bold text-white">Simulated Checkout</h3>
            <p className="text-xs text-slate-400 font-mono">SurgeGate Multi-Tier Protection</p>
          </div>
        </div>

        {/* Order Breakdown Card */}
        <div className="p-4 rounded-2xl bg-slate-900/90 border border-slate-800 mb-6 space-y-2 text-xs font-mono">
          <div className="flex justify-between text-slate-300">
            <span className="text-slate-500">Event:</span>
            <span className="font-bold text-white truncate max-w-[240px]">{event.name}</span>
          </div>
          <div className="flex justify-between text-slate-300">
            <span className="text-slate-500">Seat Allocation:</span>
            <span className="text-brand-300 font-bold">
              {seat.section} • Row {seat.row_number}, Seat {seat.seat_number}
            </span>
          </div>
          <div className="flex justify-between text-slate-300">
            <span className="text-slate-500">Admission Pass:</span>
            <span className="text-emerald-400 truncate max-w-[200px]">{admissionToken}</span>
          </div>
          <div className="flex justify-between text-slate-300">
            <span className="text-slate-500">Idempotency Key:</span>
            <span className="text-slate-400 truncate max-w-[200px]">{idempotencyKey}</span>
          </div>
          <div className="pt-2 border-t border-slate-800 flex justify-between text-sm font-bold">
            <span className="text-slate-200">Total Price:</span>
            <span className="text-emerald-400 text-base">
              ${(seat.price_cents / 100).toFixed(2)} USD
            </span>
          </div>
        </div>

        {/* Failure Simulation Toggle */}
        <div className="p-4 rounded-2xl bg-slate-900/60 border border-slate-800 mb-6">
          <label className="flex items-start space-x-3 cursor-pointer">
            <input
              type="checkbox"
              checked={simulateFailure}
              onChange={(e) => setSimulateFailure(e.target.checked)}
              className="mt-1 w-4 h-4 rounded text-brand-500 bg-slate-800 border-slate-700 focus:ring-0"
            />
            <div className="text-xs">
              <span className="font-semibold text-slate-200 flex items-center space-x-1">
                <span>Simulate Payment Decline / Failure</span>
                <AlertTriangle className="w-3.5 h-3.5 text-amber-400" />
              </span>
              <p className="text-[11px] text-slate-400 mt-0.5">
                Enable to demonstrate graceful transaction failure: seat hold remains protected in MySQL for retry within the 5-minute window.
              </p>
            </div>
          </label>
        </div>

        {/* Error alert */}
        {error && (
          <div className="mb-4 p-3 rounded-xl bg-rose-500/10 border border-rose-500/30 text-rose-300 text-xs">
            {error}
          </div>
        )}

        <button
          disabled={loading}
          onClick={handlePay}
          className="w-full py-3.5 rounded-2xl bg-gradient-to-r from-brand-600 via-indigo-600 to-purple-600 hover:opacity-95 text-white font-extrabold text-sm shadow-xl shadow-brand-600/30 transition flex items-center justify-center space-x-2 disabled:opacity-50"
        >
          {loading ? (
            <>
              <RefreshCw className="w-4 h-4 animate-spin" />
              <span>Verifying Idempotency & Securing Seat...</span>
            </>
          ) : (
            <>
              <ShieldCheck className="w-4 h-4" />
              <span>Authorize Payment & Confirm Booking</span>
              <ArrowRight className="w-4 h-4" />
            </>
          )}
        </button>
      </div>
    </div>
  );
};
