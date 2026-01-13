import React, { useEffect, useState } from 'react';
import { useStore } from './utils/store';
import * as api from './utils/api';
import GamepadController from './components/output-config/GamepadController';
import StatusView from './components/views/StatusView';
import OutputsView from './components/views/OutputsView';
import GobosView from './components/views/GobosView';
import MediaSlotsView from './components/views/MediaSlotsView';
import NDISourcesView from './components/views/NDISourcesView';

const TABS = [
  { id: 'status', label: 'Status', icon: '📊' },
  { id: 'outputs', label: 'Outputs', icon: '🖥️' },
  { id: 'gobos', label: 'Gobos', icon: '🎨' },
  { id: 'media', label: 'Media', icon: '🎬' },
  { id: 'ndi', label: 'NDI', icon: '📡' },
];

function App() {
  const {
    connected,
    setConnected,
    serverUrl,
    setServerUrl,
    activeTab,
    setActiveTab,
    gamepadConnected,
    gamepadId,
  } = useStore();

  const [showSettings, setShowSettings] = useState(false);
  const [tempUrl, setTempUrl] = useState(serverUrl);
  const [connecting, setConnecting] = useState(false);

  // Test connection on mount and when URL changes
  useEffect(() => {
    testConnection();
  }, [serverUrl]);

  const testConnection = async () => {
    setConnecting(true);
    try {
      await api.getStatus();
      setConnected(true);
    } catch (e) {
      setConnected(false);
    }
    setConnecting(false);
  };

  const renderView = () => {
    switch (activeTab) {
      case 'status':
        return <StatusView />;
      case 'outputs':
        return <OutputsView />;
      case 'gobos':
        return <GobosView />;
      case 'media':
        return <MediaSlotsView />;
      case 'ndi':
        return <NDISourcesView />;
      default:
        return <StatusView />;
    }
  };

  return (
    <div className="app-container">
      {/* Gamepad controller (logic only) */}
      <GamepadController />

      {/* Header */}
      <header className="app-header">
        <h1>DMX Visualizer Control</h1>
        <div className="header-right">
          {gamepadConnected && (
            <div className="gamepad-status">
              <span className="gamepad-icon">🎮</span>
              <span className="gamepad-name">{gamepadId?.substring(0, 20) || 'Gamepad'}</span>
            </div>
          )}
          <div className="connection-status">
            <span className={`status-dot ${connected ? 'connected' : ''}`} />
            <span>{connecting ? 'Connecting...' : (connected ? 'Connected' : 'Disconnected')}</span>
          </div>
          <button className="btn-icon" onClick={() => setShowSettings(true)}>
            ⚙️
          </button>
        </div>
      </header>

      {/* Tab bar */}
      <nav className="tab-bar">
        {TABS.map((tab) => (
          <button
            key={tab.id}
            className={`tab-button ${activeTab === tab.id ? 'active' : ''}`}
            onClick={() => setActiveTab(tab.id)}
          >
            <span className="tab-icon">{tab.icon}</span>
            <span className="tab-label">{tab.label}</span>
          </button>
        ))}
        <div className="tab-hint">
          <span className="hint-btn">LB</span>/<span className="hint-btn">RB</span> Switch Tabs
        </div>
      </nav>

      {/* Main content */}
      <main className="main-view">
        {renderView()}
      </main>

      {/* Gamepad hints overlay */}
      {gamepadConnected && (
        <div className="gamepad-overlay">
          <div className="gamepad-hint">
            <span className="btn">A</span> Select
          </div>
          <div className="gamepad-hint">
            <span className="btn">B</span> Back
          </div>
          <div className="gamepad-hint">
            <span className="btn">D-Pad</span> Navigate
          </div>
          <div className="gamepad-hint">
            <span className="btn">Start</span> Save
          </div>
        </div>
      )}

      {/* Settings modal */}
      {showSettings && (
        <div className="modal-overlay active" onClick={() => setShowSettings(false)}>
          <div className="modal-content" onClick={(e) => e.stopPropagation()}>
            <h2>Settings</h2>

            <div className="form-group">
              <label>DMX Visualizer URL</label>
              <input
                type="text"
                value={tempUrl}
                onChange={(e) => setTempUrl(e.target.value)}
                placeholder="http://192.168.1.100:8082"
              />
              <p className="hint">Enter the URL of your DMX Visualizer web control</p>
            </div>

            <div className="modal-buttons">
              <button className="btn" onClick={() => setShowSettings(false)}>Cancel</button>
              <button
                className="btn btn-success"
                onClick={() => {
                  setServerUrl(tempUrl);
                  setShowSettings(false);
                }}
              >
                Connect
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

export default App;
