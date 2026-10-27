import React from 'react';
import { 
  Zap, 
  Ticket, 
  Users, 
  Layers, 
  LayoutDashboard, 
  QrCode, 
  History, 
  LogIn, 
  LogOut, 
  Shield 
} from 'lucide-react';
import { useAuth } from '../context/AuthContext';

interface NavbarProps {
  activeTab: string;
  setActiveTab: (tab: any) => void;
  openAuthModal: () => void;
  nodeHealth: string;
}

export const Navbar: React.FC<NavbarProps> = ({
  activeTab,
  setActiveTab,
  openAuthModal,
  nodeHealth,
}) => {
  const { user, isAuthenticated, isAdmin, logout } = useAuth();

  return (
    <header className="sticky top-0 z-40 glass-panel border-b border-slate-800">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 h-16 flex items-center justify-between">
        {/* Brand */}
        <div 
          onClick={() => setActiveTab('events')} 
          className="flex items-center space-x-3 cursor-pointer group"
        >
          <div className="w-10 h-10 rounded-xl bg-gradient-to-tr from-brand-600 via-indigo-600 to-purple-500 flex items-center justify-center shadow-lg shadow-brand-500/25 group-hover:scale-105 transition-transform">
            <Zap className="w-5 h-5 text-white" />
          </div>
          <div>
            <div className="flex items-center space-x-2">
              <span className="font-extrabold text-xl tracking-tight bg-gradient-to-r from-white via-slate-100 to-brand-300 bg-clip-text text-transparent">
                SurgeGate
              </span>
              <span className="px-2 py-0.5 text-[10px] font-mono uppercase font-bold rounded-full bg-brand-500/20 text-brand-300 border border-brand-500/30">
                v1.0
              </span>
            </div>
            <p className="text-[10px] text-slate-400 font-mono hidden sm:block">Flash-Sale Traffic Control</p>
          </div>
        </div>

        {/* Navigation Tabs */}
        <nav className="hidden lg:flex items-center space-x-1">
          <button
            onClick={() => setActiveTab('events')}
            className={`px-3 py-1.5 rounded-lg text-sm font-medium transition-all ${
              activeTab === 'events'
                ? 'bg-brand-600 text-white shadow-md shadow-brand-600/30'
                : 'text-slate-300 hover:text-white hover:bg-slate-800/60'
            }`}
          >
            <span className="flex items-center space-x-1.5">
              <Ticket className="w-4 h-4" />
              <span>Events</span>
            </span>
          </button>

          <button
            onClick={() => setActiveTab('queue')}
            className={`px-3 py-1.5 rounded-lg text-sm font-medium transition-all ${
              activeTab === 'queue'
                ? 'bg-brand-600 text-white shadow-md shadow-brand-600/30'
                : 'text-slate-300 hover:text-white hover:bg-slate-800/60'
            }`}
          >
            <span className="flex items-center space-x-1.5">
              <Users className="w-4 h-4" />
              <span>Waiting Room</span>
            </span>
          </button>

          <button
            onClick={() => setActiveTab('seats')}
            className={`px-3 py-1.5 rounded-lg text-sm font-medium transition-all ${
              activeTab === 'seats'
                ? 'bg-brand-600 text-white shadow-md shadow-brand-600/30'
                : 'text-slate-300 hover:text-white hover:bg-slate-800/60'
            }`}
          >
            <span className="flex items-center space-x-1.5">
              <Layers className="w-4 h-4" />
              <span>Seat Map</span>
            </span>
          </button>

          <button
            onClick={() => setActiveTab('bookings')}
            className={`px-3 py-1.5 rounded-lg text-sm font-medium transition-all ${
              activeTab === 'bookings'
                ? 'bg-brand-600 text-white shadow-md shadow-brand-600/30'
                : 'text-slate-300 hover:text-white hover:bg-slate-800/60'
            }`}
          >
            <span className="flex items-center space-x-1.5">
              <History className="w-4 h-4" />
              <span>My Tickets</span>
            </span>
          </button>

          <button
            onClick={() => setActiveTab('verify')}
            className={`px-3 py-1.5 rounded-lg text-sm font-medium transition-all ${
              activeTab === 'verify'
                ? 'bg-brand-600 text-white shadow-md shadow-brand-600/30'
                : 'text-slate-300 hover:text-white hover:bg-slate-800/60'
            }`}
          >
            <span className="flex items-center space-x-1.5">
              <QrCode className="w-4 h-4" />
              <span>Turnstile Scanner</span>
            </span>
          </button>

          <button
            onClick={() => setActiveTab('admin')}
            className={`px-3 py-1.5 rounded-lg text-sm font-medium transition-all ${
              activeTab === 'admin'
                ? 'bg-brand-600 text-white shadow-md shadow-brand-600/30'
                : 'text-slate-300 hover:text-white hover:bg-slate-800/60'
            }`}
          >
            <span className="flex items-center space-x-1.5">
              <LayoutDashboard className="w-4 h-4" />
              <span>Admin Telemetry</span>
            </span>
          </button>
        </nav>

        {/* User / Auth Controls */}
        <div className="flex items-center space-x-3">
          {/* Health Indicator */}
          <div className="hidden sm:flex items-center space-x-2 px-2.5 py-1 rounded-full bg-slate-900 border border-slate-800 text-xs font-mono">
            <span className={`w-2 h-2 rounded-full ${nodeHealth === 'HEALTHY' ? 'bg-emerald-400 animate-pulse' : 'bg-amber-400'}`}></span>
            <span className="text-slate-400">{nodeHealth}</span>
          </div>

          {isAuthenticated && user ? (
            <div className="flex items-center space-x-3">
              <div className="flex items-center space-x-2 px-3 py-1 rounded-xl bg-slate-800/80 border border-slate-700 text-xs">
                {isAdmin ? (
                  <Shield className="w-3.5 h-3.5 text-amber-400" />
                ) : (
                  <div className="w-2 h-2 rounded-full bg-brand-400" />
                )}
                <span className="font-medium text-slate-200">{user.full_name}</span>
                <span className={`px-1.5 py-0.2 rounded text-[10px] font-bold ${isAdmin ? 'bg-amber-500/20 text-amber-300' : 'bg-brand-500/20 text-brand-300'}`}>
                  {user.role}
                </span>
              </div>
              <button
                onClick={logout}
                title="Log out"
                className="p-2 rounded-lg bg-slate-800 hover:bg-rose-500/20 hover:text-rose-400 text-slate-400 border border-slate-700 transition"
              >
                <LogOut className="w-4 h-4" />
              </button>
            </div>
          ) : (
            <button
              onClick={openAuthModal}
              className="px-4 py-2 rounded-xl bg-gradient-to-r from-brand-600 to-indigo-600 text-white font-medium text-xs shadow-md shadow-brand-600/30 hover:opacity-95 transition flex items-center space-x-1.5"
            >
              <LogIn className="w-3.5 h-3.5" />
              <span>Sign In</span>
            </button>
          )}
        </div>
      </div>
    </header>
  );
};
