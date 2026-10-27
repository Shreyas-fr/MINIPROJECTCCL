import React, { useEffect, useState } from 'react';
import { X, Download, QrCode, CheckCircle2, Printer } from 'lucide-react';
import { Booking } from '../types';
import { api } from '../services/api';

interface TicketModalProps {
  isOpen: boolean;
  booking: Booking | null;
  onClose: () => void;
  onNavigateToScanner?: (ref: string) => void;
}

export const TicketModal: React.FC<TicketModalProps> = ({
  isOpen,
  booking,
  onClose,
  onNavigateToScanner,
}) => {
  const [svgContent, setSvgContent] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (!booking) return;

    setLoading(true);
    fetch(api.getTicketSvgUrl(booking.booking_ref))
      .then((res) => res.text())
      .then((svg) => {
        setSvgContent(svg);
        setLoading(false);
      })
      .catch(() => {
        setLoading(false);
      });
  }, [booking]);

  if (!isOpen || !booking) return null;

  const handleDownload = () => {
    if (!svgContent) return;
    const blob = new Blob([svgContent], { type: 'image/svg+xml' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `SurgeGate-Ticket-${booking.booking_ref}.svg`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  };

  const handlePrint = () => {
    window.print();
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/85 backdrop-blur-md animate-fade-in overflow-y-auto">
      <div className="relative w-full max-w-xl rounded-3xl glass-card border border-brand-500/40 p-6 sm:p-8 shadow-2xl my-8">
        <button
          onClick={onClose}
          className="absolute top-4 right-4 p-1.5 rounded-lg text-slate-400 hover:text-white hover:bg-slate-800 transition"
        >
          <X className="w-5 h-5" />
        </button>

        {/* Modal Header */}
        <div className="text-center mb-6">
          <div className="w-12 h-12 rounded-2xl bg-emerald-500/20 text-emerald-400 border border-emerald-500/30 mx-auto flex items-center justify-center mb-3">
            <CheckCircle2 className="w-6 h-6" />
          </div>
          <h3 className="text-2xl font-extrabold text-white">Booking Confirmed!</h3>
          <p className="text-xs text-slate-400 mt-1 font-mono">
            Booking Ref: <strong className="text-brand-300 font-bold">{booking.booking_ref}</strong>
          </p>
        </div>

        {/* SVG Ticket Render */}
        <div className="p-4 rounded-2xl bg-slate-950/80 border border-slate-800 flex justify-center mb-6 shadow-inner">
          {loading ? (
            <div className="py-24 text-center text-xs text-slate-400 font-mono">
              Rendering dynamic vector ticket...
            </div>
          ) : svgContent ? (
            <div
              className="w-full max-w-[340px] [&>svg]:w-full [&>svg]:h-auto drop-shadow-xl"
              dangerouslySetInnerHTML={{ __html: svgContent }}
            />
          ) : (
            <div className="py-12 text-slate-400 text-xs font-mono">Ticket asset generating...</div>
          )}
        </div>

        {/* Actions */}
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
          <button
            onClick={handleDownload}
            className="py-2.5 px-4 rounded-xl bg-brand-600 hover:bg-brand-500 text-white font-semibold text-xs shadow-md shadow-brand-600/30 transition flex items-center justify-center space-x-1.5"
          >
            <Download className="w-4 h-4" />
            <span>Download SVG</span>
          </button>

          <button
            onClick={handlePrint}
            className="py-2.5 px-4 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-200 font-semibold text-xs border border-slate-700 transition flex items-center justify-center space-x-1.5"
          >
            <Printer className="w-4 h-4" />
            <span>Print Pass</span>
          </button>

          {onNavigateToScanner && (
            <button
              onClick={() => onNavigateToScanner(booking.booking_ref)}
              className="py-2.5 px-4 rounded-xl bg-slate-800 hover:bg-slate-700 text-brand-300 font-semibold text-xs border border-brand-500/30 transition flex items-center justify-center space-x-1.5"
            >
              <QrCode className="w-4 h-4" />
              <span>Verify at Gate</span>
            </button>
          )}
        </div>
      </div>
    </div>
  );
};
