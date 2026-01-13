import React, { useEffect, useState } from 'react';
import { useStore } from '../../utils/store';
import { getStatus, getPreviewUrl } from '../../utils/api';

export default function StatusView() {
  const { status, setStatus, connected } = useStore();
  const [previewKey, setPreviewKey] = useState(0);

  useEffect(() => {
    if (!connected) return;

    const fetchStatus = async () => {
      try {
        const data = await getStatus();
        setStatus({
          version: data.version || '-',
          fixtures: data.fixtures || 0,
          resolution: data.resolution || '-',
          outputCount: data.outputs || 0,
        });
      } catch (e) {
        console.error('Failed to fetch status:', e);
      }
    };

    fetchStatus();
    const interval = setInterval(fetchStatus, 5000);
    return () => clearInterval(interval);
  }, [connected]);

  // Refresh preview periodically
  useEffect(() => {
    if (!connected) return;
    const interval = setInterval(() => setPreviewKey(k => k + 1), 1000);
    return () => clearInterval(interval);
  }, [connected]);

  return (
    <div className="status-view">
      <div className="status-grid">
        <div className="status-info">
          <div className="status-item">
            <span>Version:</span>
            <span className="status-value">{status.version}</span>
          </div>
          <div className="status-item">
            <span>Fixtures:</span>
            <span className="status-value">{status.fixtures}</span>
          </div>
          <div className="status-item">
            <span>Resolution:</span>
            <span className="status-value">{status.resolution}</span>
          </div>
          <div className="status-item">
            <span>Outputs:</span>
            <span className="status-value">{status.outputCount}</span>
          </div>
        </div>

        <div className="preview-container">
          {connected ? (
            <img
              key={previewKey}
              src={getPreviewUrl()}
              alt="Preview"
              onError={(e) => e.target.style.opacity = 0.3}
            />
          ) : (
            <div className="preview-placeholder">
              Connect to view preview
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
