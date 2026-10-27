import React, { useEffect, useState } from 'react';
import { 
  LayoutDashboard, 
  DollarSign, 
  Users, 
  Ticket, 
  Lock, 
  Zap, 
  ShieldAlert, 
  RefreshCw, 
  Sliders 
} from 'lucide-react';
import { AdminOverview, EventDetail } from '../types';
import { api } from '../services/api';
import { useAuth } from '../context/AuthContext';

interface AdminDashboardProps {
  events: EventDetail[];
  onRefreshEvents: () => void;
}

export const AdminDashboard: React.FC<AdminDashboardProps> = ({ events, onRefreshEvents }) => {
  const { isAdmin } = useAuth();
  const [overview, setOverview] = useState<AdminOverview | null>(null);
  const [selectedEventId, setSelectedEventId] = useState<string>(events[0]?.event_id || '');
  const [queueMetrics, setQueueMetrics] = useState<any>(null);
  const [actionMessage, setActionMessage] = useState<string | null>(null);

  const fetchTelemetry = async () => {
    try {
      const data = await api.getAdminOverview();
      setOverview(data);
    } catch {
      // Ignored if non-admin
    }
  };

  const fetchQueueMetrics = async (eventId: string) => {
    if (!eventId) return;
    try {
      const m = await api.getAdminQueueMetrics(eventId);
      setQueueMetrics(m);
    } catch {
      // Ignored
    }
  };

  useEffect(() => {
    fetchTelemetry();
    const interval = setInterval(fetchTelemetry, 6000);
    return () => clearInterval(interval);
  }, []);

  useEffect(() => {
    if (selectedEventId) {
      fetchQueueMetrics(selectedEventId);
      const qInterval = setInterval(() => fetchQueueMetrics(selectedEventId), 3000);
      return () => clearInterval(qInterval);
    }
  }, [selectedEventId]);

  const handleBatchAdmit = async (batchSize: number) => {
    if (!selectedEventId) return;
    setActionMessage(null);
    try {
      const res = await api.admitQueueBatch(selectedEventId, batchSize);
      setActionMessage(`✅ Admitted ${res.admitted_count} users into the flash sale!`);
      fetchQueueMetrics(selectedEventId);
      fetchTelemetry();
    } catch (err: any) {
      setActionMessage(`❌ Error: ${err.message}`);
    }
  };

  const handleToggleEventStatus = async (eventId: string, newStatus: string) => {
    try {
      await api.updateEventStatus(eventId, newStatus);
      setActionMessage(`Updated event status to ${newStatus}`);
      onRefreshEvents();
      fetchTelemetry();
    } catch (err: any) {
      setActionMessage(`Failed to update status: ${err.message}`);
    }
  };

  if (!isAdmin) {
    return (
      <div className="max-w-xl mx-auto py-16 text-center animate-fade-in">
        <div className="w-16 h-16 rounded-2xl bg-amber-500/10 text-amber-400 border border-amber-500/20 mx-auto flex items-center justify-center mb-4">
          <ShieldAlert className="w-8 h-8" />
        </div>
        <h3 className="text-xl font-bold text-white mb-2">Administrative Privileges Required</h3>
        <p className="text-xs text-slate-400 mb-6">
          Log in with an administrator account (e.g. <code className="text-brand-300 font-mono">admin@surgegate.internal</code>) to access real-time queue controls and traffic telemetry.
        </p>
      </div>
    );
  }

  return (
    <div className="max-w-7xl mx-auto py-8 px-4 animate-fade-in space-y-8">
      {/* Top Banner */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h2 className="text-2xl font-extrabold text-white flex items-center space-x-2">
            <LayoutDashboard className="w-6 h-6 text-brand-400" />
            <span>Traffic Telemetry & Operator Controls</span>
          </h2>
          <p className="text-xs text-slate-400 mt-1 font-mono">
            SurgeGate Multi-Tier Concurrency & Virtual Waiting Room Management
          </p>
        </div>

        <button
          onClick={() => {
            fetchTelemetry();
            if (selectedEventId) fetchQueueMetrics(selectedEventId);
          }}
          className="px-4 py-2 rounded-xl bg-slate-900 border border-slate-800 hover:border-slate-700 text-xs font-mono text-slate-300 flex items-center space-x-2 transition self-start sm:self-auto"
        >
          <RefreshCw className="w-3.5 h-3.5" />
          <span>Refresh Metrics</span>
        </button>
      </div>

      {/* Action Notification */}
      {actionMessage && (
        <div className="p-3.5 rounded-2xl bg-brand-500/10 border border-brand-500/30 text-brand-300 text-xs font-mono flex items-center justify-between">
          <span>{actionMessage}</span>
          <button onClick={() => setActionMessage(null)} className="text-slate-400 hover:text-white">✕</button>
        </div>
      )}

      {/* KPI Cards */}
      <div className="grid grid-cols-2 md:grid-cols-5 gap-4">
        <div className="glass-card p-5 rounded-2xl border border-slate-800">
          <div className="flex items-center space-x-2 text-slate-400 text-xs mb-1">
            <DollarSign className="w-4 h-4 text-emerald-400" />
            <span>Total Revenue</span>
          </div>
          <div className="text-2xl font-extrabold text-white font-mono">
            ${((overview?.total_revenue_cents || 0) / 100).toLocaleString('en-US', { minimumFractionDigits: 0 })}
          </div>
        </div>

        <div className="glass-card p-5 rounded-2xl border border-slate-800">
          <div className="flex items-center space-x-2 text-slate-400 text-xs mb-1">
            <Ticket className="w-4 h-4 text-brand-400" />
            <span>Confirmed Bookings</span>
          </div>
          <div className="text-2xl font-extrabold text-white font-mono">
            {overview?.confirmed_bookings || 0}
          </div>
        </div>

        <div className="glass-card p-5 rounded-2xl border border-slate-800">
          <div className="flex items-center space-x-2 text-slate-400 text-xs mb-1">
            <Zap className="w-4 h-4 text-amber-400" />
            <span>Active Flash Sales</span>
          </div>
          <div className="text-2xl font-extrabold text-white font-mono">
            {overview?.active_flash_sales || 0}
          </div>
        </div>

        <div className="glass-card p-5 rounded-2xl border border-slate-800">
          <div className="flex items-center space-x-2 text-slate-400 text-xs mb-1">
            <Users className="w-4 h-4 text-sky-400" />
            <span>Registered Users</span>
          </div>
          <div className="text-2xl font-extrabold text-white font-mono">
            {overview?.total_registered_users || 0}
          </div>
        </div>

        <div className="glass-card p-5 rounded-2xl border border-slate-800 col-span-2 md:col-span-1">
          <div className="flex items-center space-x-2 text-slate-400 text-xs mb-1">
            <Lock className="w-4 h-4 text-rose-400" />
            <span>Active Seat Holds</span>
          </div>
          <div className="text-2xl font-extrabold text-white font-mono">
            {overview?.active_seat_holds || 0}
          </div>
        </div>
      </div>

      {/* Virtual Waiting Room Admission Engine Controls */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
        <div className="glass-card rounded-3xl p-6 sm:p-8 border border-brand-500/30">
          <div className="flex items-center justify-between mb-6">
            <div className="flex items-center space-x-3">
              <div className="w-10 h-10 rounded-xl bg-brand-500/20 text-brand-400 flex items-center justify-center">
                <Sliders className="w-5 h-5" />
              </div>
              <div>
                <h3 className="text-lg font-bold text-white">Queue Rate Regulator</h3>
                <p className="text-xs text-slate-400">Control admission batch throttling per flash-sale event</p>
              </div>
            </div>
          </div>

          <div className="space-y-4">
            <div>
              <label className="block text-xs font-semibold text-slate-300 mb-1 font-mono">Target Flash-Sale Event:</label>
              <select
                value={selectedEventId}
                onChange={(e) => setSelectedEventId(e.target.value)}
                className="w-full px-3 py-2 rounded-xl bg-slate-900 border border-slate-700 text-white text-xs font-medium focus:outline-none focus:border-brand-500"
              >
                {events.map((e) => (
                  <option key={e.event_id} value={e.event_id}>
                    {e.name} ({e.status})
                  </option>
                ))}
              </select>
            </div>

            {/* Event Queue Live Stats */}
            <div className="grid grid-cols-3 gap-3 p-4 rounded-2xl bg-slate-900/90 border border-slate-800 text-center font-mono">
              <div>
                <span className="text-[10px] text-slate-500 uppercase block">Waiting In Queue</span>
                <span className="text-xl font-bold text-amber-400">
                  {queueMetrics?.waiting_users ?? 0}
                </span>
              </div>
              <div>
                <span className="text-[10px] text-slate-500 uppercase block">Active Admitted</span>
                <span className="text-xl font-bold text-emerald-400">
                  {queueMetrics?.active_admitted_users ?? 0}
                </span>
              </div>
              <div>
                <span className="text-[10px] text-slate-500 uppercase block">Expired Passes</span>
                <span className="text-xl font-bold text-slate-400">
                  {queueMetrics?.expired_users ?? 0}
                </span>
              </div>
            </div>

            {/* Admission Actions */}
            <div className="pt-2">
              <label className="block text-xs font-semibold text-slate-300 mb-2 font-mono">
                Trigger Regulated Batch Admission:
              </label>
              <div className="grid grid-cols-3 gap-2">
                <button
                  onClick={() => handleBatchAdmit(1)}
                  className="py-2.5 px-3 rounded-xl bg-slate-900 hover:bg-slate-800 text-slate-200 text-xs font-mono font-bold border border-slate-700 transition"
                >
                  +1 User
                </button>
                <button
                  onClick={() => handleBatchAdmit(5)}
                  className="py-2.5 px-3 rounded-xl bg-gradient-to-r from-brand-600 to-indigo-600 hover:opacity-95 text-white text-xs font-mono font-bold shadow-md shadow-brand-600/20 transition"
                >
                  +5 Users
                </button>
                <button
                  onClick={() => handleBatchAdmit(20)}
                  className="py-2.5 px-3 rounded-xl bg-emerald-600 hover:bg-emerald-500 text-white text-xs font-mono font-bold transition"
                >
                  +20 Surge
                </button>
              </div>
            </div>
          </div>
        </div>

        {/* Flash-Sale Event Status Controller */}
        <div className="glass-card rounded-3xl p-6 sm:p-8 border border-slate-800 flex flex-col justify-between">
          <div>
            <div className="flex items-center space-x-3 mb-6">
              <div className="w-10 h-10 rounded-xl bg-indigo-500/20 text-indigo-400 flex items-center justify-center">
                <Zap className="w-5 h-5" />
              </div>
              <div>
                <h3 className="text-lg font-bold text-white">Event State Transitions</h3>
                <p className="text-xs text-slate-400">Toggle sale phases to regulate concurrency entrance</p>
              </div>
            </div>

            <div className="space-y-4">
              {events.map((evt) => (
                <div
                  key={evt.event_id}
                  className="p-4 rounded-2xl bg-slate-900/60 border border-slate-800 flex flex-col sm:flex-row sm:items-center justify-between gap-3"
                >
                  <div>
                    <h4 className="text-sm font-bold text-white">{evt.name}</h4>
                    <p className="text-[11px] text-slate-400 font-mono">
                      Capacity: {evt.available_capacity}/{evt.total_capacity} • Current: {evt.status}
                    </p>
                  </div>

                  <div className="flex items-center space-x-1.5 self-end sm:self-auto">
                    <button
                      onClick={() => handleToggleEventStatus(evt.event_id, 'UPCOMING')}
                      className={`px-2.5 py-1 rounded-lg text-[10px] font-mono font-bold transition ${
                        evt.status === 'UPCOMING'
                          ? 'bg-indigo-600 text-white'
                          : 'bg-slate-800 hover:bg-slate-700 text-slate-300'
                      }`}
                    >
                      Upcoming
                    </button>
                    <button
                      onClick={() => handleToggleEventStatus(evt.event_id, 'ACTIVE')}
                      className={`px-2.5 py-1 rounded-lg text-[10px] font-mono font-bold transition ${
                        evt.status === 'ACTIVE'
                          ? 'bg-emerald-600 text-white'
                          : 'bg-slate-800 hover:bg-slate-700 text-slate-300'
                      }`}
                    >
                      Active Sale
                    </button>
                    <button
                      onClick={() => handleToggleEventStatus(evt.event_id, 'SOLD_OUT')}
                      className={`px-2.5 py-1 rounded-lg text-[10px] font-mono font-bold transition ${
                        evt.status === 'SOLD_OUT'
                          ? 'bg-rose-600 text-white'
                          : 'bg-slate-800 hover:bg-slate-700 text-slate-300'
                      }`}
                    >
                      Sold Out
                    </button>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
