import React, { useEffect, useState } from 'react';
import { useStore } from './utils/store';
import { connectWebSocket, disconnectWebSocket } from './utils/websocket';
import GamepadController from './components/output-config/GamepadController';
import KeystoneCanvas from './components/output-config/KeystoneCanvas';
import BlendEditor from './components/output-config/BlendEditor';
import PositionControls from './components/output-config/PositionControls';

function App() {
  const {
    connected,
    connecting,
    serverUrl,
    setServerUrl,
    outputs,
    selectedOutputId,
    setSelectedOutputId,
    mode,
    setMode,
    gamepadConnected,
    gamepadId,
    sendConfig,
  } = useStore();

  const [showSettings, setShowSettings] = useState(false);
  const [tempUrl, setTempUrl] = useState(serverUrl);

  // Connect on mount
  useEffect(() => {
    connectWebSocket();
    return () => disconnectWebSocket();
  }, []);

  // Select first output when outputs load
  useEffect(() => {
    if (outputs.length > 0 && !selectedOutputId) {
      setSelectedOutputId(outputs[0].id);
    }
  }, [outputs, selectedOutputId]);

  const selectedOutput = outputs.find(o => o.id === selectedOutputId);

  return (
    <div className="app-container">
      {/* Gamepad controller (logic only) */}
      <GamepadController />

      {/* Header */}
      <header className="app-header">
        <h1>Output Config</h1>
        <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
          {gamepadConnected && (
            <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 13, color: 'var(--text-secondary)' }}>
              <span>🎮</span>
              <span>{gamepadId?.substring(0, 20) || 'Gamepad'}</span>
            </div>
          )}
          <div className="connection-status">
            <span className={`status-dot ${connected ? 'connected' : ''}`} />
            <span>{connecting ? 'Connecting...' : (connected ? 'Connected' : 'Disconnected')}</span>
          </div>
          <button onClick={() => setShowSettings(true)} style={{ padding: '8px 12px' }}>
            ⚙️
          </button>
        </div>
      </header>

      {/* Main content */}
      <div className="main-content">
        {/* Sidebar - Output list */}
        <aside className="sidebar">
          <div className="sidebar-header">
            Outputs ({outputs.length})
          </div>
          <div className="output-list">
            {outputs.length === 0 ? (
              <div style={{ padding: 16, color: 'var(--text-secondary)', textAlign: 'center' }}>
                {connected ? 'No outputs configured' : 'Connect to visualizer...'}
              </div>
            ) : (
              outputs.map((output) => (
                <div
                  key={output.id}
                  className={`output-item ${selectedOutputId === output.id ? 'selected' : ''}`}
                  onClick={() => setSelectedOutputId(output.id)}
                  tabIndex={0}
                >
                  <span className="output-icon">
                    {output.type === 'ndi' ? '📡' : '🖥️'}
                  </span>
                  <div className="output-info">
                    <div className="output-name">{output.name || `Output ${output.id}`}</div>
                    <div className="output-type">{output.type?.toUpperCase() || 'Unknown'}</div>
                  </div>
                </div>
              ))
            )}
          </div>

          {/* Demo outputs for testing */}
          {outputs.length === 0 && connected && (
            <button
              onClick={() => {
                useStore.getState().setOutputs([
                  { id: 1, name: 'Main Projector', type: 'hdmi' },
                  { id: 2, name: 'Side Screen', type: 'displayport' },
                  { id: 3, name: 'NDI Stream 1', type: 'ndi' },
                ]);
              }}
              style={{ margin: 8 }}
            >
              Load Demo Outputs
            </button>
          )}
        </aside>

        {/* Canvas area */}
        <main className="canvas-area">
          {/* Mode tabs */}
          <div className="mode-tabs">
            <div
              className={`mode-tab ${mode === 'position' ? 'active' : ''}`}
              onClick={() => setMode('position')}
              tabIndex={0}
            >
              <div className="tab-icon">📐</div>
              <div className="tab-label">Position</div>
              <div className="tab-hint">Left Stick</div>
            </div>
            <div
              className={`mode-tab ${mode === 'keystone' ? 'active' : ''}`}
              onClick={() => setMode('keystone')}
              tabIndex={0}
            >
              <div className="tab-icon">🔲</div>
              <div className="tab-label">Keystone</div>
              <div className="tab-hint">Press X</div>
            </div>
            <div
              className={`mode-tab ${mode === 'blend' ? 'active' : ''}`}
              onClick={() => setMode('blend')}
              tabIndex={0}
            >
              <div className="tab-icon">🌫️</div>
              <div className="tab-label">Blend</div>
              <div className="tab-hint">Press Y</div>
            </div>
          </div>

          {/* Canvas */}
          <div className="canvas-container">
            <KeystoneCanvas />
          </div>

          {/* Controls panel */}
          <div className="controls-panel">
            {mode === 'position' && <PositionControls />}
            {mode === 'keystone' && (
              <div style={{ padding: 16, background: 'var(--bg-secondary)', borderRadius: 8 }}>
                <h3 style={{ marginBottom: 12 }}>Keystone Adjustment</h3>
                <p style={{ color: 'var(--text-secondary)', fontSize: 14, marginBottom: 12 }}>
                  Use D-Pad to select corner, Left Stick to move. Touch/drag corners on canvas.
                </p>
                <div style={{ display: 'flex', gap: 8 }}>
                  <button onClick={() => useStore.getState().resetKeystone()}>Reset Keystone</button>
                  <button onClick={sendConfig}>Apply</button>
                </div>
              </div>
            )}
            {mode === 'blend' && <BlendEditor />}
          </div>
        </main>
      </div>

      {/* Gamepad hints overlay */}
      {gamepadConnected && (
        <div className="gamepad-overlay">
          <div className="gamepad-hint">
            <span className="btn">A</span> Apply
          </div>
          <div className="gamepad-hint">
            <span className="btn">X</span> Keystone
          </div>
          <div className="gamepad-hint">
            <span className="btn">Y</span> Blend
          </div>
          <div className="gamepad-hint">
            <span className="btn">LB/RB</span> Switch Output
          </div>
          <div className="gamepad-hint">
            <span className="btn">Select</span> Reset
          </div>
        </div>
      )}

      {/* Settings modal */}
      {showSettings && (
        <div
          style={{
            position: 'fixed',
            inset: 0,
            background: 'rgba(0,0,0,0.8)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            zIndex: 1000,
          }}
          onClick={() => setShowSettings(false)}
        >
          <div
            style={{
              background: 'var(--bg-secondary)',
              borderRadius: 12,
              padding: 24,
              minWidth: 400,
            }}
            onClick={(e) => e.stopPropagation()}
          >
            <h2 style={{ marginBottom: 16 }}>Settings</h2>

            <div style={{ marginBottom: 16 }}>
              <label style={{ display: 'block', marginBottom: 8 }}>
                Visualizer WebSocket URL
              </label>
              <input
                type="text"
                value={tempUrl}
                onChange={(e) => setTempUrl(e.target.value)}
                placeholder="ws://192.168.1.100:8080/ws"
                style={{ width: '100%' }}
              />
            </div>

            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
              <button onClick={() => setShowSettings(false)}>Cancel</button>
              <button
                onClick={() => {
                  setServerUrl(tempUrl);
                  disconnectWebSocket();
                  setTimeout(connectWebSocket, 100);
                  setShowSettings(false);
                }}
                style={{ background: 'var(--accent)' }}
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
