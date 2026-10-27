import React, { useEffect, useState } from 'react';
import { 
  ShieldAlert, 
  Lock, 
  Clock, 
  ArrowRight, 
  Check, 
  RefreshCw, 
  Unlock
} from 'lucide-react';
import { EventDetail, Seat } from '../types';
import { api } from '../services/api';
import { useAuth } from '../context/AuthContext';

interface SeatMapProps {
  event: EventDetail;
  admissionToken?: string | null;
  onProceedToCheckout: (seat: Seat) => void;
  onBackToQueue?: () => void;
}

export const SeatMap: React.FC<SeatMapProps> = ({
  event,
  admissionToken,
  onProceedToCheckout,
}) => {
  const { user } = useAuth();
  const [seats, setSeats] = useState<Seat[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedSeat, setSelectedSeat] = useState<Seat | null>(null);
  const [heldSeat, setHeldSeat] = useState<Seat | null>(null);
  const [secondsRemaining, setSecondsRemaining] = useState<number>(0);
  const [holding, setHolding] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchSeats = async () => {
    try {
      const data = await api.getEventSeats(event.event_id);
      setSeats(data);

      // Check if user already holds a seat
      if (user) {
        const myHeld = data.find(
          (s) => s.status === 'RESERVED' && s.reserved_by === user.user_id
        );
        if (myHeld) {
          setHeldSeat(myHeld);
          setSelectedSeat(myHeld);
          if (myHeld.reserved_until) {
            const diff = Math.max(0, Math.floor((new Date(myHeld.reserved_until).getTime() - Date.now()) / 1000));
            setSecondsRemaining(diff);
          }
        }
      }
    } catch (err: any) {
      setError(err.message || 'Failed to load seats');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchSeats();
    const interval = setInterval(fetchSeats, 4000);
    return () => clearInterval(interval);
  }, [event.event_id, user?.user_id]);

  // Countdown timer for 5-minute seat hold
  useEffect(() => {
    if (secondsRemaining <= 0) {
      if (heldSeat) {
        setHeldSeat(null);
        setSelectedSeat(null);
      }
      return;
    }
    const timer = setInterval(() => {
      setSecondsRemaining((prev) => Math.max(0, prev - 1));
    }, 1000);
    return () => clearInterval(timer);
  }, [secondsRemaining, heldSeat]);

  const handleHoldSeat = async (seat: Seat) => {
    if (!admissionToken) {
      setError('Queue admission token required. Please enter through the virtual waiting room.');
      return;
    }
    setError(null);
    setHolding(true);
    try {
      const res = await api.holdSeat(event.event_id, seat.seat_id, admissionToken);
      setHeldSeat(seat);
      setSecondsRemaining(res.hold_duration_seconds || 300);
      await fetchSeats();
    } catch (err: any) {
      setError(err.message || 'Seat could not be locked. It may have just been claimed by another user.');
      await fetchSeats();
    } finally {
      setHolding(false);
    }
  };

  const handleReleaseSeat = async () => {
    if (!heldSeat) return;
    try {
      await api.releaseSeat(event.event_id, heldSeat.seat_id);
      setHeldSeat(null);
      setSelectedSeat(null);
      setSecondsRemaining(0);
      await fetchSeats();
    } catch (err: any) {
      setError(err.message || 'Failed to release seat');
    }
  };

  // Group seats by section
  const sections: { [key: string]: Seat[] } = {};
  seats.forEach((seat) => {
    if (!sections[seat.section]) sections[seat.section] = [];
    sections[seat.section].push(seat);
  });

  const formatTimer = (sec: number) => {
    const m = Math.floor(sec / 60);
    const s = sec % 60;
    return `${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
  };

  return (
    <div className="max-w-6xl mx-auto py-6 px-4 animate-fade-in">
      {/* Top Banner */}
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4 mb-6">
        <div>
          <div className="flex items-center space-x-2">
            <h2 className="text-2xl font-bold text-white">{event.name}</h2>
            <span className="px-2.5 py-0.5 rounded-full text-xs font-mono bg-brand-500/20 text-brand-300 border border-brand-500/30">
              Interactive Arena Map
            </span>
          </div>
          <p className="text-xs text-slate-400 mt-1 font-mono">{event.venue}</p>
        </div>

        {/* Legend */}
        <div className="flex flex-wrap items-center gap-3 text-xs font-mono bg-slate-900/80 px-4 py-2 rounded-xl border border-slate-800">
          <div className="flex items-center space-x-1.5">
            <span className="w-3 h-3 rounded-md bg-emerald-500/20 border border-emerald-500"></span>
            <span className="text-slate-300">Available</span>
          </div>
          <div className="flex items-center space-x-1.5">
            <span className="w-3 h-3 rounded-md bg-amber-500/30 border border-amber-500"></span>
            <span className="text-slate-300">Held (5-min lock)</span>
          </div>
          <div className="flex items-center space-x-1.5">
            <span className="w-3 h-3 rounded-md bg-slate-800 border border-slate-700"></span>
            <span className="text-slate-500">Booked</span>
          </div>
        </div>
      </div>

      {/* Error alert */}
      {error && (
        <div className="mb-6 p-4 rounded-2xl bg-rose-500/10 border border-rose-500/30 text-rose-300 text-xs flex items-center justify-between">
          <div className="flex items-center space-x-2">
            <ShieldAlert className="w-4 h-4 text-rose-400 shrink-0" />
            <span>{error}</span>
          </div>
          <button
            onClick={() => setError(null)}
            className="text-xs underline hover:text-white"
          >
            Dismiss
          </button>
        </div>
      )}

      {/* Held Seat Countdown Banner */}
      {heldSeat && (
        <div className="mb-6 p-4 rounded-2xl bg-gradient-to-r from-amber-500/20 via-orange-500/20 to-brand-500/20 border border-amber-500/40 flex flex-col sm:flex-row items-center justify-between gap-4 shadow-lg shadow-amber-500/10">
          <div className="flex items-center space-x-3 text-center sm:text-left">
            <div className="w-10 h-10 rounded-xl bg-amber-500/20 text-amber-400 flex items-center justify-center font-bold">
              <Clock className="w-5 h-5 animate-spin" />
            </div>
            <div>
              <div className="text-sm font-bold text-white flex items-center space-x-2">
                <span>Atomic Hold Secured: Section {heldSeat.section}, Row {heldSeat.row_number}, Seat {heldSeat.seat_number}</span>
                <span className="px-2 py-0.5 rounded text-[11px] bg-amber-500/30 text-amber-300 font-mono">
                  ${(heldSeat.price_cents / 100).toFixed(0)}
                </span>
              </div>
              <p className="text-xs text-amber-200/80">
                Exclusive reservation expires in <strong className="font-mono text-white text-sm">{formatTimer(secondsRemaining)}</strong>. Complete checkout now.
              </p>
            </div>
          </div>

          <div className="flex items-center space-x-2 w-full sm:w-auto">
            <button
              onClick={handleReleaseSeat}
              className="px-3 py-2 rounded-xl bg-slate-900/80 hover:bg-slate-900 text-slate-300 text-xs font-semibold border border-slate-700 transition flex items-center space-x-1"
            >
              <Unlock className="w-3.5 h-3.5" />
              <span>Release</span>
            </button>
            <button
              onClick={() => onProceedToCheckout(heldSeat)}
              className="flex-1 sm:flex-initial px-5 py-2.5 rounded-xl bg-gradient-to-r from-emerald-500 to-teal-600 hover:from-emerald-400 hover:to-teal-500 text-white text-xs font-bold shadow-lg shadow-emerald-500/20 transition flex items-center justify-center space-x-1.5"
            >
              <span>Confirm & Pay</span>
              <ArrowRight className="w-4 h-4" />
            </button>
          </div>
        </div>
      )}

      {/* Stage Visualizer */}
      <div className="glass-card rounded-3xl p-6 sm:p-10 border border-slate-800 text-center mb-8 relative">
        <div className="w-3/4 mx-auto py-3 rounded-2xl bg-gradient-to-b from-brand-600/30 to-transparent border-t-2 border-brand-500 text-brand-300 text-xs font-mono font-bold tracking-widest uppercase mb-12 shadow-lg shadow-brand-500/10">
          STAGE / PERFORMANCE PLATFORM
        </div>

        {loading ? (
          <div className="py-20 flex justify-center items-center">
            <RefreshCw className="w-8 h-8 text-brand-400 animate-spin" />
          </div>
        ) : (
          <div className="space-y-10">
            {Object.keys(sections).map((sectionName) => {
              const secSeats = sections[sectionName];
              return (
                <div key={sectionName} className="space-y-3">
                  <div className="flex items-center justify-between max-w-xl mx-auto px-2">
                    <span className="text-xs font-bold text-slate-300 uppercase tracking-wider font-mono">
                      {sectionName}
                    </span>
                    <span className="text-xs text-brand-400 font-mono font-semibold">
                      ${(secSeats[0]?.price_cents / 100).toFixed(0)} / seat
                    </span>
                  </div>

                  {/* Seat Grid */}
                  <div className="flex flex-wrap justify-center gap-2 max-w-2xl mx-auto p-4 rounded-2xl bg-slate-950/60 border border-slate-900">
                    {secSeats.map((seat) => {
                      const isBooked = seat.status === 'BOOKED';
                      const isHeldByMe = seat.status === 'RESERVED' && user && seat.reserved_by === user.user_id;
                      const isHeldByOther = seat.status === 'RESERVED' && (!user || seat.reserved_by !== user.user_id);
                      const isSelected = selectedSeat?.seat_id === seat.seat_id;

                      let seatClasses = 'bg-emerald-500/10 border-emerald-500/40 text-emerald-300 hover:bg-emerald-500/30 hover:border-emerald-400';
                      if (isBooked) {
                        seatClasses = 'bg-slate-900 border-slate-800 text-slate-600 cursor-not-allowed opacity-40';
                      } else if (isHeldByMe) {
                        seatClasses = 'bg-amber-500/30 border-amber-400 text-white shadow-lg shadow-amber-500/20 scale-105';
                      } else if (isHeldByOther) {
                        seatClasses = 'bg-rose-500/20 border-rose-500/40 text-rose-300 cursor-not-allowed';
                      } else if (isSelected) {
                        seatClasses = 'bg-brand-500 border-brand-400 text-white scale-110 shadow-lg shadow-brand-500/30';
                      }

                      return (
                        <button
                          key={seat.seat_id}
                          disabled={isBooked || isHeldByOther}
                          onClick={() => setSelectedSeat(seat)}
                          title={`${seat.section} • Row ${seat.row_number} Seat ${seat.seat_number} • $${(seat.price_cents / 100).toFixed(0)} • Status: ${seat.status}`}
                          className={`w-9 h-9 rounded-xl border text-xs font-mono font-semibold transition-all flex items-center justify-center relative ${seatClasses}`}
                        >
                          {isBooked ? (
                            <span className="text-[10px]">✕</span>
                          ) : isHeldByOther ? (
                            <Lock className="w-3.5 h-3.5" />
                          ) : isHeldByMe ? (
                            <Check className="w-4 h-4 text-amber-300" />
                          ) : (
                            <span>{seat.seat_number}</span>
                          )}
                        </button>
                      );
                    })}
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>

      {/* Selected Seat Action Bar (when not yet held) */}
      {selectedSeat && !heldSeat && (
        <div className="fixed bottom-6 left-1/2 -translate-x-1/2 z-30 max-w-lg w-full px-4 animate-fade-in">
          <div className="glass-card rounded-2xl p-4 border border-brand-500/40 shadow-2xl flex items-center justify-between gap-4">
            <div>
              <div className="text-xs text-slate-400 font-mono">SELECTED SEAT</div>
              <div className="text-sm font-bold text-white">
                {selectedSeat.section} • Row {selectedSeat.row_number}, Seat {selectedSeat.seat_number}
              </div>
              <div className="text-xs font-mono text-emerald-400 font-bold">
                ${(selectedSeat.price_cents / 100).toFixed(0)} USD
              </div>
            </div>

            <button
              disabled={holding}
              onClick={() => handleHoldSeat(selectedSeat)}
              className="py-2.5 px-5 rounded-xl bg-gradient-to-r from-brand-600 to-indigo-600 hover:opacity-95 text-white font-bold text-xs shadow-lg shadow-brand-600/30 transition flex items-center space-x-1.5 disabled:opacity-50"
            >
              {holding ? (
                <>
                  <RefreshCw className="w-3.5 h-3.5 animate-spin" />
                  <span>Locking...</span>
                </>
              ) : (
                <>
                  <Lock className="w-3.5 h-3.5" />
                  <span>Hold for 5 Mins</span>
                </>
              )}
            </button>
          </div>
        </div>
      )}
    </div>
  );
};
