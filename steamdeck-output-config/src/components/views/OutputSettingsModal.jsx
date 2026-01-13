import React from 'react';
import { useStore } from '../../utils/store';
import * as api from '../../utils/api';

const SETTINGS_TABS = [
  { id: 'position', label: 'Position' },
  { id: 'edgeblend', label: 'Edge Blend' },
  { id: 'warp', label: 'Warp' },
  { id: 'lens', label: 'Lens' },
  { id: 'dmx', label: 'DMX' },
];

export default function OutputSettingsModal({ onSave }) {
  const {
    settingsModalOpen,
    closeSettingsModal,
    settingsTab,
    setSettingsTab,
    selectedOutputId,
    currentSettings,
    updatePositionSetting,
    updateEdgeBlendSetting,
    updateWarpSetting,
    updateWarpCurvature,
    updateLensSetting,
    buildSettingsPayload,
  } = useStore();

  if (!settingsModalOpen) return null;

  const handleSave = async () => {
    try {
      const settings = buildSettingsPayload();
      await api.updateOutputSettings(selectedOutputId, settings);
      closeSettingsModal();
      onSave?.();
    } catch (e) {
      console.error('Failed to save settings:', e);
    }
  };

  return (
    <div className="modal-overlay active" onClick={closeSettingsModal}>
      <div className="modal-content settings-modal" onClick={(e) => e.stopPropagation()}>
        <h3>Output Settings</h3>

        <div className="settings-tabs">
          {SETTINGS_TABS.map((tab) => (
            <button
              key={tab.id}
              className={`settings-tab ${settingsTab === tab.id ? 'active' : ''}`}
              onClick={() => setSettingsTab(tab.id)}
            >
              {tab.label}
            </button>
          ))}
        </div>

        <div className="settings-content">
          {settingsTab === 'position' && (
            <PositionTab
              settings={currentSettings.position}
              onChange={updatePositionSetting}
            />
          )}
          {settingsTab === 'edgeblend' && (
            <EdgeBlendTab
              settings={currentSettings.edgeBlend}
              onChange={updateEdgeBlendSetting}
            />
          )}
          {settingsTab === 'warp' && (
            <WarpTab
              settings={currentSettings.warp}
              onChangePoint={updateWarpSetting}
              onChangeCurvature={updateWarpCurvature}
            />
          )}
          {settingsTab === 'lens' && (
            <LensTab
              settings={currentSettings.lens}
              onChange={updateLensSetting}
            />
          )}
          {settingsTab === 'dmx' && (
            <DMXTab settings={currentSettings.dmx} />
          )}
        </div>

        <div className="modal-buttons">
          <button className="btn" onClick={closeSettingsModal}>Cancel</button>
          <button className="btn btn-success" onClick={handleSave}>Save</button>
        </div>
      </div>
    </div>
  );
}

function PositionTab({ settings, onChange }) {
  return (
    <div className="settings-panel">
      <SettingsRow label="X Position">
        <input
          type="number"
          value={settings.x}
          onChange={(e) => onChange('x', parseInt(e.target.value) || 0)}
        />
      </SettingsRow>
      <SettingsRow label="Y Position">
        <input
          type="number"
          value={settings.y}
          onChange={(e) => onChange('y', parseInt(e.target.value) || 0)}
        />
      </SettingsRow>
      <SettingsRow label="Width">
        <input
          type="number"
          value={settings.width}
          onChange={(e) => onChange('width', parseInt(e.target.value) || 1920)}
        />
      </SettingsRow>
      <SettingsRow label="Height">
        <input
          type="number"
          value={settings.height}
          onChange={(e) => onChange('height', parseInt(e.target.value) || 1080)}
        />
      </SettingsRow>
      <SettingsRow label="Intensity">
        <input
          type="range"
          min="0"
          max="1"
          step="0.01"
          value={settings.intensity}
          onChange={(e) => onChange('intensity', parseFloat(e.target.value))}
        />
        <span className="value">{Math.round(settings.intensity * 100)}%</span>
      </SettingsRow>
    </div>
  );
}

function EdgeBlendTab({ settings, onChange }) {
  return (
    <div className="settings-panel">
      <SettingsRow label="Left Blend">
        <input
          type="range"
          min="0"
          max="500"
          value={settings.left}
          onChange={(e) => onChange('left', parseInt(e.target.value))}
        />
        <span className="value">{settings.left}px</span>
      </SettingsRow>
      <SettingsRow label="Right Blend">
        <input
          type="range"
          min="0"
          max="500"
          value={settings.right}
          onChange={(e) => onChange('right', parseInt(e.target.value))}
        />
        <span className="value">{settings.right}px</span>
      </SettingsRow>
      <SettingsRow label="Top Blend">
        <input
          type="range"
          min="0"
          max="500"
          value={settings.top}
          onChange={(e) => onChange('top', parseInt(e.target.value))}
        />
        <span className="value">{settings.top}px</span>
      </SettingsRow>
      <SettingsRow label="Bottom Blend">
        <input
          type="range"
          min="0"
          max="500"
          value={settings.bottom}
          onChange={(e) => onChange('bottom', parseInt(e.target.value))}
        />
        <span className="value">{settings.bottom}px</span>
      </SettingsRow>
      <SettingsRow label="Gamma">
        <input
          type="range"
          min="1"
          max="4"
          step="0.1"
          value={settings.gamma}
          onChange={(e) => onChange('gamma', parseFloat(e.target.value))}
        />
        <span className="value">{settings.gamma.toFixed(1)}</span>
      </SettingsRow>
    </div>
  );
}

function WarpTab({ settings, onChangePoint, onChangeCurvature }) {
  const corners = [
    ['topLeft', 'Top Left'], ['topMid', 'Top Mid'], ['topRight', 'Top Right'],
    ['midLeft', 'Mid Left'], [null, null], ['midRight', 'Mid Right'],
    ['bottomLeft', 'Bot Left'], ['bottomMid', 'Bot Mid'], ['bottomRight', 'Bot Right'],
  ];

  return (
    <div className="settings-panel">
      <p className="hint">Adjust corner and edge points (pixels offset)</p>
      <div className="warp-grid">
        {corners.map(([key, label], i) => (
          key ? (
            <div key={key} className="warp-point">
              <label>{label}</label>
              <input
                type="number"
                placeholder="X"
                value={settings[key]?.x || 0}
                onChange={(e) => onChangePoint(key, 'x', parseInt(e.target.value) || 0)}
              />
              <input
                type="number"
                placeholder="Y"
                value={settings[key]?.y || 0}
                onChange={(e) => onChangePoint(key, 'y', parseInt(e.target.value) || 0)}
              />
            </div>
          ) : (
            <div key={i} className="warp-point empty" />
          )
        ))}
      </div>
      <SettingsRow label="Curvature">
        <input
          type="range"
          min="-1"
          max="1"
          step="0.01"
          value={settings.curvature}
          onChange={(e) => onChangeCurvature(parseFloat(e.target.value))}
        />
        <span className="value">{settings.curvature.toFixed(2)}</span>
      </SettingsRow>
    </div>
  );
}

function LensTab({ settings, onChange }) {
  return (
    <div className="settings-panel">
      <SettingsRow label="K1 (Primary)">
        <input
          type="range"
          min="-0.5"
          max="0.5"
          step="0.01"
          value={settings.k1}
          onChange={(e) => onChange('k1', parseFloat(e.target.value))}
        />
        <span className="value">{settings.k1.toFixed(2)}</span>
      </SettingsRow>
      <SettingsRow label="K2 (Secondary)">
        <input
          type="range"
          min="-0.5"
          max="0.5"
          step="0.01"
          value={settings.k2}
          onChange={(e) => onChange('k2', parseFloat(e.target.value))}
        />
        <span className="value">{settings.k2.toFixed(2)}</span>
      </SettingsRow>
      <SettingsRow label="Center X">
        <input
          type="range"
          min="0"
          max="1"
          step="0.01"
          value={settings.centerX}
          onChange={(e) => onChange('centerX', parseFloat(e.target.value))}
        />
        <span className="value">{settings.centerX.toFixed(2)}</span>
      </SettingsRow>
      <SettingsRow label="Center Y">
        <input
          type="range"
          min="0"
          max="1"
          step="0.01"
          value={settings.centerY}
          onChange={(e) => onChange('centerY', parseFloat(e.target.value))}
        />
        <span className="value">{settings.centerY.toFixed(2)}</span>
      </SettingsRow>
    </div>
  );
}

function DMXTab({ settings }) {
  return (
    <div className="settings-panel">
      <SettingsRow label="Universe">
        <input type="number" value={settings.universe} disabled />
      </SettingsRow>
      <SettingsRow label="Address">
        <input type="number" value={settings.address} disabled />
      </SettingsRow>
      <p className="hint">DMX control coming soon</p>
    </div>
  );
}

function SettingsRow({ label, children }) {
  return (
    <div className="settings-row">
      <label>{label}</label>
      {children}
    </div>
  );
}
