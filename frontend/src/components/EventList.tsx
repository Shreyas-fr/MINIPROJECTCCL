import React from 'react';
import { Calendar, MapPin, Users, ArrowRight, ShieldCheck, Sparkles } from 'lucide-react';
import { EventDetail } from '../types';

interface EventListProps {
  events: EventDetail[];
  loading: boolean;
  onSelectEvent: (event: EventDetail) => void;
}

export const EventList: React.FC<EventListProps> = ({ events, loading, onSelectEvent }) => {
  if (loading) {
    return (
      <div className="grid grid-cols-1 md:grid-cols-3 gap-6 animate-pulse">
        {[1, 2, 3].map((i) => (
          <div key={i} className="h-80 rounded-2xl bg-slate-900/60 border border-slate-800"></div>
        ))}
      </div>
    );
  }

  const formatPrice = (cents?: number) => {
    if (!cents) return '$0';
    return `$${(cents / 100).toFixed(0)}`;
  };

  const formatDate = (dateStr: string) => {
    try {
      const d = new Date(dateStr);
      return d.toLocaleDateString('en-US', {
        month: 'short',
        day: 'numeric',
        year: 'numeric',
        hour: '2-digit',
        minute: '2-digit',
      });
    } catch {
      return dateStr;
    }
  };

  return (
    <div>
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 mb-6">
        <div>
          <h2 className="text-2xl font-bold text-white flex items-center space-x-2">
            <span>High-Demand Flash Sales</span>
            <Sparkles className="w-5 h-5 text-amber-400" />
          </h2>
          <p className="text-xs text-slate-400 mt-0.5">
            Real-time capacity managed by edge virtual queues and MySQL row-level lock serialization
          </p>
        </div>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
        {events.map((evt) => {
          const isFlashLive = evt.status === 'ACTIVE';
          const isSoldOut = evt.status === 'SOLD_OUT' || evt.available_capacity === 0;
          const pctAvailable = Math.round((evt.available_capacity / evt.total_capacity) * 100);

          return (
            <div
              key={evt.event_id}
              className={`glass-card rounded-2xl border transition-all duration-300 flex flex-col justify-between overflow-hidden group ${
                isFlashLive
                  ? 'border-brand-500/40 hover:border-brand-400 shadow-lg shadow-brand-500/10'
                  : 'border-slate-800/80 hover:border-slate-700'
              }`}
            >
              <div className="p-6">
                {/* Status Badge */}
                <div className="flex items-center justify-between mb-4">
                  <span
                    className={`inline-flex items-center space-x-1.5 px-3 py-1 rounded-full text-xs font-bold font-mono ${
                      isSoldOut
                        ? 'bg-rose-500/20 text-rose-300 border border-rose-500/30'
                        : isFlashLive
                        ? 'bg-emerald-500/20 text-emerald-300 border border-emerald-500/30 animate-pulse'
                        : 'bg-indigo-500/20 text-indigo-300 border border-indigo-500/30'
                    }`}
                  >
                    <span className={`w-2 h-2 rounded-full ${isSoldOut ? 'bg-rose-400' : isFlashLive ? 'bg-emerald-400' : 'bg-indigo-400'}`}></span>
                    <span>{isSoldOut ? 'SOLD OUT' : isFlashLive ? 'FLASH SALE LIVE' : 'UPCOMING'}</span>
                  </span>

                  <span className="text-xs font-mono font-bold text-brand-300 bg-brand-500/10 px-2.5 py-1 rounded-lg border border-brand-500/20">
                    {formatPrice(evt.min_price_cents)} - {formatPrice(evt.max_price_cents)}
                  </span>
                </div>

                {/* Event Title */}
                <h3 className="text-xl font-bold text-white mb-2 group-hover:text-brand-300 transition-colors">
                  {evt.name}
                </h3>

                <p className="text-xs text-slate-300 line-clamp-2 mb-4 leading-relaxed">
                  {evt.description || 'Exclusive ticket release with strict queue admission controls.'}
                </p>

                {/* Event Metadata */}
                <div className="space-y-2 text-xs text-slate-400 pt-2 border-t border-slate-800/80 font-mono">
                  <div className="flex items-center space-x-2">
                    <Calendar className="w-3.5 h-3.5 text-brand-400 shrink-0" />
                    <span>{formatDate(evt.event_timestamp)}</span>
                  </div>
                  <div className="flex items-center space-x-2">
                    <MapPin className="w-3.5 h-3.5 text-brand-400 shrink-0" />
                    <span className="truncate">{evt.venue}</span>
                  </div>
                  <div className="flex items-center space-x-2">
                    <Users className="w-3.5 h-3.5 text-brand-400 shrink-0" />
                    <span>
                      {evt.available_capacity} / {evt.total_capacity} seats available ({pctAvailable}%)
                    </span>
                  </div>
                </div>

                {/* Capacity Progress Bar */}
                <div className="w-full bg-slate-800 rounded-full h-1.5 mt-3 overflow-hidden">
                  <div
                    className={`h-full transition-all duration-500 ${
                      pctAvailable < 20 ? 'bg-rose-500' : pctAvailable < 50 ? 'bg-amber-400' : 'bg-brand-500'
                    }`}
                    style={{ width: `${pctAvailable}%` }}
                  ></div>
                </div>
              </div>

              {/* Action Button */}
              <div className="p-4 bg-slate-900/60 border-t border-slate-800/80">
                <button
                  disabled={isSoldOut}
                  onClick={() => onSelectEvent(evt)}
                  className={`w-full py-2.5 px-4 rounded-xl font-semibold text-xs transition flex items-center justify-center space-x-2 ${
                    isSoldOut
                      ? 'bg-slate-800 text-slate-500 cursor-not-allowed'
                      : isFlashLive
                      ? 'bg-gradient-to-r from-brand-600 to-indigo-600 hover:opacity-95 text-white shadow-lg shadow-brand-600/30'
                      : 'bg-slate-800 hover:bg-slate-700 text-slate-200'
                  }`}
                >
                  <ShieldCheck className="w-4 h-4" />
                  <span>
                    {isSoldOut
                      ? 'Event Sold Out'
                      : isFlashLive
                      ? 'Enter Virtual Waiting Room'
                      : 'View Seat Map Preview'}
                  </span>
                  {!isSoldOut && <ArrowRight className="w-4 h-4 ml-1" />}
                </button>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
};
