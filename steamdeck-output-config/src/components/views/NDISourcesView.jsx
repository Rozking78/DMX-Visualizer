import React, { useEffect, useState } from 'react';
import { useStore } from '../../utils/store';
import * as api from '../../utils/api';

export default function NDISourcesView() {
  const { ndiSources, setNDISources, connected } = useStore();
  const [refreshing, setRefreshing] = useState(false);

  useEffect(() => {
    if (!connected) return;
    fetchSources();
  }, [connected]);

  const fetchSources = async () => {
    try {
      const data = await api.getNDISources();
      setNDISources(data.sources || []);
    } catch (e) {
      console.error('Failed to fetch NDI sources:', e);
    }
  };

  const handleRefresh = async () => {
    setRefreshing(true);
    try {
      await api.refreshNDISources();
      // Wait a moment for discovery
      await new Promise((r) => setTimeout(r, 2000));
      await fetchSources();
    } catch (e) {
      console.error('Failed to refresh NDI sources:', e);
    }
    setRefreshing(false);
  };

  return (
    <div className="ndi-view">
      <h2>NDI Sources</h2>

      <button
        className="btn btn-primary"
        onClick={handleRefresh}
        disabled={refreshing}
      >
        {refreshing ? 'Refreshing...' : 'Refresh Sources'}
      </button>

      <div className="source-list">
        {ndiSources.length === 0 ? (
          <div className="empty-message">
            {connected ? 'No NDI sources found. Click Refresh to discover.' : 'Connect to view sources'}
          </div>
        ) : (
          ndiSources.map((source, index) => (
            <div key={index} className="source-item">
              <div className="source-info">
                <div className="source-name">{source.name}</div>
                <div className="source-address">{source.address || 'Auto-discovered'}</div>
              </div>
              <div className="source-status">
                <span className={`status-badge ${source.connected ? 'connected' : ''}`}>
                  {source.connected ? 'Connected' : 'Available'}
                </span>
              </div>
            </div>
          ))
        )}
      </div>

      <div className="ndi-info">
        <h3>NDI Info</h3>
        <p>NDI (Network Device Interface) allows video to be sent over your local network.</p>
        <ul>
          <li>Sources are auto-discovered on your network</li>
          <li>Click Refresh to scan for new sources</li>
          <li>Use Output settings to add NDI outputs</li>
        </ul>
      </div>
    </div>
  );
}
