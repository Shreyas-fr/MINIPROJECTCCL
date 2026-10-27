import { useState, useEffect } from 'react';
import { 
  ShieldCheck, 
  Zap, 
  Activity, 
  Ticket, 
  Users, 
  LayoutDashboard, 
  Layers, 
  ArrowRight,
  Server,
  Database,
  Cloud
} from 'lucide-react';

interface HealthStatus {
  status: string;
  service: string;
  environment: string;
  database_connected?: boolean;
  message: string;
}

export default function App() {
  const [activeTab, setActiveTab] = useState<'events' | 'queue' | 'seats' | 'ticket' | 'admin'>('events');
  const [health, setHealth] = useState<HealthStatus | null>(null);
  const [loadingHealth, setLoadingHealth] = useState(true);

  useEffect(() => {
    fetch('/health')
      .then((res) => res.json())
      .then((data) => {
        setHealth(data);
        setLoadingHealth(false);
      })
      .catch(() => {
        setHealth({
          status: 'OFFLINE',
          service: 'SurgeGate Backend',
          environment: 'local',
          message: 'Backend server initializing...',
        });
        setLoadingHealth(false);
      });
  }, []);

  return (
    <div className="min-h-screen bg-surface-950 flex flex-col font-sans">
      {/* Top Navbar */}
      <header className="sticky top-0 z-50 glass-panel border-b border-slate-800">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 h-16 flex items-center justify-between">
          <div className="flex items-center space-x-3">
            <div className="w-10 h-10 rounded-xl bg-gradient-to-tr from-brand-600 to-indigo-500 flex items-center justify-center shadow-lg shadow-brand-500/25">
              <Zap className="w-6 h-6 text-white" />
            </div>
            <div>
              <span className="font-extrabold text-xl tracking-tight bg-gradient-to-r from-white via-slate-200 to-brand-300 bg-clip-text text-transparent">
                SurgeGate
              </span>
              <span className="ml-2 px-2 py-0.5 text-xs font-semibold rounded-full bg-brand-500/20 text-brand-300 border border-brand-500/30">
                v1.0
              </span>
            </div>
          </div>

          {/* Navigation Items */}
          <nav className="hidden md:flex items-center space-x-1">
            <button
              onClick={() => setActiveTab('events')}
              className={`px-4 py-2 rounded-lg text-sm font-medium transition-all ${
                activeTab === 'events'
                  ? 'bg-brand-600 text-white shadow-lg shadow-brand-600/30'
                  : 'text-slate-400 hover:text-white hover:bg-slate-800/60'
              }`}
            >
              <span className="flex items-center space-x-2">
                <Ticket className="w-4 h-4" />
                <span>Live Events</span>
              </span>
            </button>
            <button
              onClick={() => setActiveTab('queue')}
              className={`px-4 py-2 rounded-lg text-sm font-medium transition-all ${
                activeTab === 'queue'
                  ? 'bg-brand-600 text-white shadow-lg shadow-brand-600/30'
                  : 'text-slate-400 hover:text-white hover:bg-slate-800/60'
              }`}
            >
              <span className="flex items-center space-x-2">
                <Users className="w-4 h-4" />
                <span>Waiting Room</span>
              </span>
            </button>
            <button
              onClick={() => setActiveTab('seats')}
              className={`px-4 py-2 rounded-lg text-sm font-medium transition-all ${
                activeTab === 'seats'
                  ? 'bg-brand-600 text-white shadow-lg shadow-brand-600/30'
                  : 'text-slate-400 hover:text-white hover:bg-slate-800/60'
              }`}
            >
              <span className="flex items-center space-x-2">
                <Layers className="w-4 h-4" />
                <span>Seat Reservation</span>
              </span>
            </button>
            <button
              onClick={() => setActiveTab('admin')}
              className={`px-4 py-2 rounded-lg text-sm font-medium transition-all ${
                activeTab === 'admin'
                  ? 'bg-brand-600 text-white shadow-lg shadow-brand-600/30'
                  : 'text-slate-400 hover:text-white hover:bg-slate-800/60'
              }`}
            >
              <span className="flex items-center space-x-2">
                <LayoutDashboard className="w-4 h-4" />
                <span>Admin Operations</span>
              </span>
            </button>
          </nav>

          {/* System Health Badge */}
          <div className="flex items-center space-x-3">
            <div className="flex items-center space-x-2 px-3 py-1.5 rounded-full bg-slate-900 border border-slate-800 text-xs font-mono">
              <span className={`w-2.5 h-2.5 rounded-full ${health?.status === 'HEALTHY' ? 'bg-emerald-400 animate-pulse' : 'bg-amber-400'}`}></span>
              <span className="text-slate-300">
                {loadingHealth ? 'Checking node...' : (health?.status || 'Active')}
              </span>
            </div>
          </div>
        </div>
      </header>

      {/* Main Content Area */}
      <main className="flex-1 max-w-7xl w-full mx-auto px-4 sm:px-6 lg:px-8 py-8">
        {/* Hero Banner */}
        <div className="relative overflow-hidden rounded-3xl glass-card p-8 md:p-12 mb-10 border border-slate-800/80">
          <div className="absolute top-0 right-0 -mr-16 -mt-16 w-96 h-96 bg-gradient-to-br from-brand-600/20 to-indigo-600/10 rounded-full blur-3xl pointer-events-none"></div>
          <div className="max-w-2xl relative z-10">
            <div className="inline-flex items-center space-x-2 px-3 py-1 rounded-full bg-brand-500/10 border border-brand-500/20 text-brand-300 text-xs font-semibold mb-4">
              <ShieldCheck className="w-4 h-4" />
              <span>Multi-Tier Concurrency Protection Enabled</span>
            </div>
            <h1 className="text-4xl md:text-5xl font-extrabold tracking-tight text-white mb-4">
              Flash-Sale Ticketing with <span className="bg-gradient-to-r from-brand-400 via-indigo-300 to-sky-400 bg-clip-text text-transparent">Zero Overselling</span>
            </h1>
            <p className="text-slate-300 text-base md:text-lg mb-6 leading-relaxed">
              SurgeGate orchestrates high-concurrency ticket rushes via an edge-regulated virtual waiting room, atomic row-level MySQL reservation locks, and serverless SQS ticket processing.
            </p>
            <div className="flex flex-wrap gap-4">
              <button 
                onClick={() => setActiveTab('events')}
                className="px-6 py-3 rounded-xl bg-gradient-to-r from-brand-600 to-indigo-600 text-white font-semibold shadow-lg shadow-brand-600/30 hover:opacity-95 transition flex items-center space-x-2"
              >
                <span>Browse Live Flash Sales</span>
                <ArrowRight className="w-4 h-4" />
              </button>
              <button 
                onClick={() => setActiveTab('admin')}
                className="px-6 py-3 rounded-xl bg-slate-800/80 hover:bg-slate-800 text-slate-200 font-semibold border border-slate-700 transition flex items-center space-x-2"
              >
                <Activity className="w-4 h-4 text-brand-400" />
                <span>Traffic Telemetry & Controls</span>
              </button>
            </div>
          </div>
        </div>

        {/* Architectural Highlights Cards */}
        <div className="grid grid-cols-1 md:grid-cols-3 gap-6 mb-12">
          <div className="glass-card p-6 rounded-2xl border border-slate-800/80">
            <div className="w-12 h-12 rounded-xl bg-sky-500/10 border border-sky-500/20 flex items-center justify-center text-sky-400 mb-4">
              <Users className="w-6 h-6" />
            </div>
            <h3 className="text-lg font-bold text-white mb-2">1. Virtual Waiting Room</h3>
            <p className="text-slate-400 text-sm leading-relaxed">
              Durable FIFO queue with regulated batch admission throttles spikes so transactional databases stay resilient under sudden traffic floods.
            </p>
          </div>

          <div className="glass-card p-6 rounded-2xl border border-slate-800/80">
            <div className="w-12 h-12 rounded-xl bg-purple-500/10 border border-purple-500/20 flex items-center justify-center text-purple-400 mb-4">
              <Database className="w-6 h-6" />
            </div>
            <h3 className="text-lg font-bold text-white mb-2">2. Row-Level Atomic Locks</h3>
            <p className="text-slate-400 text-sm leading-relaxed">
              Strict 5-minute reservations serialized with MySQL <code className="text-brand-300 font-mono text-xs">SELECT ... FOR UPDATE</code> prevent double-booking down to the millisecond.
            </p>
          </div>

          <div className="glass-card p-6 rounded-2xl border border-slate-800/80">
            <div className="w-12 h-12 rounded-xl bg-emerald-500/10 border border-emerald-500/20 flex items-center justify-center text-emerald-400 mb-4">
              <Cloud className="w-6 h-6" />
            </div>
            <h3 className="text-lg font-bold text-white mb-2">3. Serverless Ticket Worker</h3>
            <p className="text-slate-400 text-sm leading-relaxed">
              Decoupled SQS asynchronous messaging and S3 ticket storage decouple payment confirmation from heavy PDF/SVG QR generation.
            </p>
          </div>
        </div>

        {/* Dynamic Section Placeholder for Skeleton Phase */}
        <div className="glass-card rounded-2xl p-8 border border-slate-800 text-center">
          <div className="inline-flex items-center justify-center w-16 h-16 rounded-2xl bg-brand-500/10 text-brand-400 mb-4">
            <Server className="w-8 h-8" />
          </div>
          <h2 className="text-2xl font-bold text-white mb-2">
            SurgeGate System Skeleton Deployed
          </h2>
          <p className="text-slate-400 max-w-xl mx-auto mb-6 text-sm">
            Phase A infrastructure skeleton is initialized. The FastAPI backend is configured with MySQL ORM models, CORS, health endpoints, and the React/TypeScript frontend is online.
          </p>
          <div className="inline-block p-4 rounded-xl bg-slate-900 border border-slate-800 font-mono text-xs text-left text-slate-300 max-w-lg w-full">
            <div className="text-brand-400 font-bold mb-2">System Status Telemetry:</div>
            <div>• Backend Service: {health?.service || 'Connecting...'}</div>
            <div>• Health Endpoint: /health (HTTP 200 OK)</div>
            <div>• Node Environment: {health?.environment || 'dev'}</div>
            <div>• Concurrency Engine: InnoDB Row-Level Locks + SQS</div>
          </div>
        </div>
      </main>

      {/* Footer */}
      <footer className="border-t border-slate-800 py-6 text-center text-slate-500 text-xs font-mono">
        SurgeGate • Cloud Computing Mini-Project • React + FastAPI + MySQL 8 + AWS Architecture
      </footer>
    </div>
  );
}
