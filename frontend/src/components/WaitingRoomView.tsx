import React, { useEffect, useState } from 'react';
import { 
  Users, 
  Clock, 
  ShieldCheck, 
  ArrowRight, 
  AlertCircle, 
  LogOut, 
  Sparkles, 
  CheckCircle2, 
  Activity 
} from 'lucide-react';
import { EventDetail, QueueStatus } from '../types';
import { api } from '../services/api';

interface WaitingRoomViewProps {
  event: EventDetail;
  onAdmitted: (token: string) => void;
  onExit: () => void;
}

export const WaitingRoomView: React.FC<WaitingRoomViewProps> = ({
  event,
  onAdmitted,
  onExit,
}) => {
  const [queueStatus, setQueueStatus] = useState<QueueStatus | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [heartbeatActive, setHeartbeatActive] = useState(true);

  // Initial join & poll status
  useEffect(() => {
    let isMounted = true;

    async function initQueue() {
      try {
        setLoading(true);
        const status = await api.joinQueue(event.event_id);
        if (isMounted) {
          setQueueStatus(status);
          if (status.status === 'ADMITTED' && status.admission_token) {
            api.setStoredAdmissionToken(event.event_id, status.admission_token);
            onAdmitted(status.admission_token);
          }
        }
      } catch (err: any) {
        if (isMounted) {
          setError(err.message || 'Failed to enter waiting room');
        }
      } finally {
        if (isMounted) setLoading(false);
      }
    }

    initQueue();

    // Polling loop every 3 seconds for near-real-time updates
    const pollInterval = setInterval(async () => {
      try {
        const updated = await api.getQueueStatus(event.event_id);
        if (isMounted) {
          setQueueStatus(updated);
          setHeartbeatActive(true);
          if (updated.status === 'ADMITTED' && updated.admission_token) {
            api.setStoredAdmissionToken(event.event_id, updated.admission_token);
            onAdmitted(updated.admission_token);
          }
        }
      } catch (err: any) {
        // Ignored in poll interval
      }
    }, 3000);

    return () => {
      isMounted = false;
      clearInterval(pollInterval);
    };
  }, [event.event_id]);

  const handleLeave = async () => {
    try {
      await api.leaveQueue(event.event_id);
    } catch {
      // Ignored
    }
    onExit();
  };

  const isAdmitted = queueStatus?.status === 'ADMITTED';

  return (
    <div className="max-w-2xl mx-auto py-8 px-4 animate-fade-in">
      <div className="glass-card rounded-3xl p-8 sm:p-10 border border-brand-500/30 text-center relative overflow-hidden shadow-2xl">
        {/* Ambient background glow */}
        <div className="absolute top-0 right-0 -mr-20 -mt-20 w-72 h-72 bg-brand-600/20 rounded-full blur-3xl pointer-events-none"></div>
        <div className="absolute bottom-0 left-0 -ml-20 -mb-20 w-72 h-72 bg-indigo-600/20 rounded-full blur-3xl pointer-events-none"></div>

        {/* Header Info */}
        <div className="inline-flex items-center space-x-2 px-3 py-1 rounded-full bg-brand-500/10 border border-brand-500/20 text-brand-300 text-xs font-semibold mb-4">
          <ShieldCheck className="w-4 h-4" />
          <span>SurgeGate Edge Traffic Regulation</span>
        </div>

        <h2 className="text-3xl font-extrabold text-white mb-2">{event.name}</h2>
        <p className="text-xs text-slate-400 mb-8 font-mono">{event.venue}</p>

        {loading ? (
          <div className="py-12 flex flex-col items-center justify-center space-y-4">
            <div className="w-12 h-12 border-4 border-brand-500 border-t-transparent rounded-full animate-spin"></div>
            <p className="text-sm text-slate-300">Synchronizing with MySQL FIFO waiting room...</p>
          </div>
        ) : error ? (
          <div className="p-6 rounded-2xl bg-rose-500/10 border border-rose-500/30 text-rose-300 text-sm mb-6">
            <AlertCircle className="w-8 h-8 mx-auto mb-2 text-rose-400" />
            <p className="font-semibold">{error}</p>
            <button
              onClick={onExit}
              className="mt-4 px-4 py-2 rounded-xl bg-slate-800 hover:bg-slate-700 text-white text-xs font-medium"
            >
              Return to Events
            </button>
          </div>
        ) : isAdmitted ? (
          /* ADMITTED STATE */
          <div className="py-6 space-y-6">
            <div className="w-20 h-20 rounded-2xl bg-emerald-500/20 border border-emerald-500/40 text-emerald-400 mx-auto flex items-center justify-center shadow-lg shadow-emerald-500/25 animate-bounce">
              <CheckCircle2 className="w-10 h-10" />
            </div>

            <div>
              <span className="px-3 py-1 rounded-full text-xs font-bold font-mono bg-emerald-500/20 text-emerald-300 border border-emerald-500/30">
                ADMISSION GRANTED
              </span>
              <h3 className="text-2xl font-bold text-white mt-3">You're In! Seat Selection Unlocked</h3>
              <p className="text-xs text-slate-300 max-w-md mx-auto mt-1">
                Your admission pass is cryptographically verified. Complete your seat reservation within 15 minutes before your token expires.
              </p>
            </div>

            <div className="p-4 rounded-2xl bg-slate-900/90 border border-slate-800 text-left font-mono text-xs text-slate-300 max-w-md mx-auto space-y-1.5">
              <div className="flex justify-between">
                <span className="text-slate-500">Queue Ticket:</span>
                <span className="text-brand-300 font-bold">#{queueStatus?.queue_number}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-slate-500">Admission Pass:</span>
                <span className="text-emerald-400 font-bold truncate max-w-[200px]">
                  {queueStatus?.admission_token}
                </span>
              </div>
              <div className="flex justify-between">
                <span className="text-slate-500">Pass Expires:</span>
                <span className="text-amber-400 font-semibold">
                  {queueStatus?.admission_expires_at ? new Date(queueStatus.admission_expires_at).toLocaleTimeString() : '15 minutes'}
                </span>
              </div>
            </div>

            <button
              onClick={() => onAdmitted(queueStatus!.admission_token!)}
              className="w-full py-4 px-6 rounded-2xl bg-gradient-to-r from-emerald-500 to-teal-600 hover:from-emerald-400 hover:to-teal-500 text-white font-extrabold text-base shadow-xl shadow-emerald-500/30 transition transform hover:-translate-y-0.5 flex items-center justify-center space-x-2"
            >
              <Sparkles className="w-5 h-5" />
              <span>Choose Your Seats Now</span>
              <ArrowRight className="w-5 h-5 ml-1" />
            </button>
          </div>
        ) : (
          /* WAITING STATE */
          <div className="py-6 space-y-8">
            {/* Animated Radar Pulse Queue Ring */}
            <div className="relative w-36 h-36 mx-auto flex items-center justify-center">
              <div className="absolute inset-0 rounded-full border-2 border-brand-500/20 animate-ping"></div>
              <div className="absolute inset-2 rounded-full border border-brand-500/40"></div>
              <div className="w-28 h-28 rounded-full bg-slate-900/90 border border-brand-500/60 flex flex-col items-center justify-center shadow-xl shadow-brand-500/20">
                <span className="text-xs font-mono text-slate-400">YOUR PLACE</span>
                <span className="text-3xl font-extrabold text-white font-mono tracking-tight">
                  #{queueStatus?.queue_number}
                </span>
              </div>
            </div>

            {/* Waiting Metrics Cards */}
            <div className="grid grid-cols-2 gap-4 max-w-md mx-auto">
              <div className="glass-card p-4 rounded-2xl border border-slate-800">
                <div className="flex items-center space-x-2 text-slate-400 text-xs mb-1">
                  <Users className="w-4 h-4 text-brand-400" />
                  <span>Ahead in Line</span>
                </div>
                <div className="text-2xl font-bold text-white font-mono">
                  {queueStatus?.position_ahead}
                </div>
              </div>

              <div className="glass-card p-4 rounded-2xl border border-slate-800">
                <div className="flex items-center space-x-2 text-slate-400 text-xs mb-1">
                  <Clock className="w-4 h-4 text-indigo-400" />
                  <span>Est. Wait Time</span>
                </div>
                <div className="text-2xl font-bold text-white font-mono">
                  {queueStatus?.estimated_wait_seconds === 0 ? '< 10s' : `~${queueStatus?.estimated_wait_seconds}s`}
                </div>
              </div>
            </div>

            {/* Heartbeat Status Indicator */}
            <div className="inline-flex items-center space-x-2 px-3 py-1.5 rounded-full bg-slate-900 border border-slate-800 text-xs font-mono text-slate-400">
              <Activity className={`w-3.5 h-3.5 ${heartbeatActive ? 'text-emerald-400 animate-pulse' : 'text-slate-500'}`} />
              <span>Heartbeat active: position reserved in MySQL queue</span>
            </div>

            <div className="pt-4 border-t border-slate-800">
              <button
                onClick={handleLeave}
                className="text-xs text-slate-400 hover:text-rose-400 flex items-center justify-center space-x-1.5 mx-auto transition"
              >
                <LogOut className="w-3.5 h-3.5" />
                <span>Leave Waiting Room</span>
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
};
