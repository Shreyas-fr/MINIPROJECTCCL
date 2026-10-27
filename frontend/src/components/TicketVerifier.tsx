import React, { useState } from 'react';
import { QrCode, CheckCircle2, XCircle, Search } from 'lucide-react';
import { TicketVerification } from '../types';
import { api } from '../services/api';

interface TicketVerifierProps {
  initialCode?: string;
}

export const TicketVerifier: React.FC<TicketVerifierProps> = ({ initialCode = '' }) => {
  const [code, setCode] = useState(initialCode);
  const [result, setResult] = useState<TicketVerification | null>(null);
  const [loading, setLoading] = useState(false);

  const handleVerify = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!code.trim()) return;

    setLoading(true);
    try {
      const res = await api.verifyTicket(code.trim());
      setResult(res);
    } catch {
      setResult(null);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="max-w-2xl mx-auto py-8 px-4 animate-fade-in">
      <div className="glass-card rounded-3xl p-6 sm:p-10 border border-slate-800 shadow-2xl">
        <div className="text-center mb-8">
          <div className="w-14 h-14 rounded-2xl bg-brand-500/10 text-brand-400 border border-brand-500/20 mx-auto flex items-center justify-center mb-3">
            <QrCode className="w-7 h-7" />
          </div>
          <h2 className="text-2xl font-bold text-white">Venue Turnstile Gate Scanner</h2>
          <p className="text-xs text-slate-400 mt-1">
            Simulate turnstile admission scanning against the SurgeGate relational database
          </p>
        </div>

        <form onSubmit={handleVerify} className="flex gap-2 mb-8">
          <div className="relative flex-1">
            <Search className="absolute left-3.5 top-3 w-4 h-4 text-slate-500" />
            <input
              type="text"
              value={code}
              onChange={(e) => setCode(e.target.value)}
              placeholder="Enter Booking Ref (e.g., SG-1234) or Ticket ID"
              className="w-full pl-10 pr-4 py-2.5 rounded-xl bg-slate-900 border border-slate-700 text-white placeholder-slate-500 text-sm font-mono focus:outline-none focus:border-brand-500 transition"
            />
          </div>
          <button
            type="submit"
            disabled={loading}
            className="px-6 py-2.5 rounded-xl bg-brand-600 hover:bg-brand-500 text-white font-semibold text-xs transition shadow-md shadow-brand-600/30 disabled:opacity-50"
          >
            {loading ? 'Scanning...' : 'Scan Pass'}
          </button>
        </form>

        {result && (
          <div
            className={`p-6 rounded-2xl border transition-all ${
              result.is_valid
                ? 'bg-emerald-500/10 border-emerald-500/40'
                : 'bg-rose-500/10 border-rose-500/40'
            }`}
          >
            <div className="flex items-center space-x-3 mb-4">
              {result.is_valid ? (
                <CheckCircle2 className="w-8 h-8 text-emerald-400 shrink-0" />
              ) : (
                <XCircle className="w-8 h-8 text-rose-400 shrink-0" />
              )}
              <div>
                <span
                  className={`px-2.5 py-0.5 rounded-full text-xs font-mono font-bold ${
                    result.is_valid
                      ? 'bg-emerald-500/20 text-emerald-300'
                      : 'bg-rose-500/20 text-rose-300'
                  }`}
                >
                  {result.is_valid ? 'ADMIT TURNSTILE: VALID PASS' : 'ENTRY DECLINED: INVALID OR UNPAID'}
                </span>
                <div className="text-base font-bold text-white mt-1">
                  {result.attendee_name}
                </div>
              </div>
            </div>

            <div className="grid grid-cols-2 gap-2 text-xs font-mono pt-3 border-t border-slate-800 text-slate-300">
              <div>
                <span className="text-slate-500 block">Event:</span>
                <span className="font-semibold text-white truncate block">{result.event_name}</span>
              </div>
              <div>
                <span className="text-slate-500 block">Venue:</span>
                <span className="font-semibold text-white truncate block">{result.venue}</span>
              </div>
              <div>
                <span className="text-slate-500 block">Booking Ref:</span>
                <span className="font-semibold text-brand-300 block">{result.booking_ref}</span>
              </div>
              <div>
                <span className="text-slate-500 block">Allocated Seat:</span>
                <span className="font-semibold text-emerald-300 block">
                  {result.section} - {result.row_number} - {result.seat_number}
                </span>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
};
