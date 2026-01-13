import React from 'react';
import { useStore } from '../../utils/store';
import { throttledSendConfig } from '../../utils/websocket';

/**
 * PositionControls - X/Y position, scale, and rotation controls
 */

export default function PositionControls() {
  const {
    position,
    updatePosition,
    resetPosition,
    mode,
  } = useStore();

  const isActive = mode === 'position';

  const handleChange = (key, value) => {
    updatePosition({ [key]: value });
    throttledSendConfig();
  };

  return (
    <div className="position-controls" style={{ opacity: isActive ? 1 : 0.5 }}>
      <div style={{
        display: 'grid',
        gridTemplateColumns: '1fr 1fr',
        gap: 12,
        marginBottom: 16,
      }}>
        {/* X Position */}
        <div className="control-group">
          <label>X Position</label>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <input
              type="range"
              min={-500}
              max={500}
              value={position.x}
              onChange={(e) => handleChange('x', parseFloat(e.target.value))}
              disabled={!isActive}
              style={{ flex: 1, accentColor: 'var(--accent)' }}
            />
            <input
              type="number"
              value={position.x.toFixed(0)}
              onChange={(e) => handleChange('x', parseFloat(e.target.value) || 0)}
              disabled={!isActive}
              style={{ width: 70, textAlign: 'right' }}
            />
          </div>
        </div>

        {/* Y Position */}
        <div className="control-group">
          <label>Y Position</label>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <input
              type="range"
              min={-500}
              max={500}
              value={position.y}
              onChange={(e) => handleChange('y', parseFloat(e.target.value))}
              disabled={!isActive}
              style={{ flex: 1, accentColor: 'var(--accent)' }}
            />
            <input
              type="number"
              value={position.y.toFixed(0)}
              onChange={(e) => handleChange('y', parseFloat(e.target.value) || 0)}
              disabled={!isActive}
              style={{ width: 70, textAlign: 'right' }}
            />
          </div>
        </div>

        {/* Scale */}
        <div className="control-group">
          <label>Scale</label>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <input
              type="range"
              min={0.1}
              max={3}
              step={0.01}
              value={position.scale}
              onChange={(e) => handleChange('scale', parseFloat(e.target.value))}
              disabled={!isActive}
              style={{ flex: 1, accentColor: 'var(--accent)' }}
            />
            <input
              type="number"
              step={0.1}
              value={position.scale.toFixed(2)}
              onChange={(e) => handleChange('scale', parseFloat(e.target.value) || 1)}
              disabled={!isActive}
              style={{ width: 70, textAlign: 'right' }}
            />
          </div>
        </div>

        {/* Rotation */}
        <div className="control-group">
          <label>Rotation</label>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <input
              type="range"
              min={-180}
              max={180}
              value={position.rotation}
              onChange={(e) => handleChange('rotation', parseFloat(e.target.value))}
              disabled={!isActive}
              style={{ flex: 1, accentColor: 'var(--accent)' }}
            />
            <input
              type="number"
              value={position.rotation.toFixed(1)}
              onChange={(e) => handleChange('rotation', parseFloat(e.target.value) || 0)}
              disabled={!isActive}
              style={{ width: 70, textAlign: 'right' }}
            />
          </div>
        </div>
      </div>

      {/* Quick presets */}
      <div style={{
        display: 'flex',
        gap: 8,
        flexWrap: 'wrap',
      }}>
        <button
          onClick={() => {
            resetPosition();
            throttledSendConfig();
          }}
          disabled={!isActive}
          style={{ flex: 1 }}
        >
          Reset
        </button>
        <button
          onClick={() => {
            updatePosition({ scale: 1 });
            throttledSendConfig();
          }}
          disabled={!isActive}
          style={{ flex: 1 }}
        >
          Scale 100%
        </button>
        <button
          onClick={() => {
            updatePosition({ rotation: 0 });
            throttledSendConfig();
          }}
          disabled={!isActive}
          style={{ flex: 1 }}
        >
          No Rotation
        </button>
        <button
          onClick={() => {
            updatePosition({ x: 0, y: 0 });
            throttledSendConfig();
          }}
          disabled={!isActive}
          style={{ flex: 1 }}
        >
          Center
        </button>
      </div>

      {/* Visual position indicator */}
      <div style={{
        marginTop: 16,
        padding: 16,
        background: 'var(--bg-primary)',
        borderRadius: 8,
        position: 'relative',
        height: 150,
        overflow: 'hidden',
      }}>
        {/* Grid */}
        <svg
          width="100%"
          height="100%"
          style={{ position: 'absolute', top: 0, left: 0 }}
        >
          <defs>
            <pattern id="grid" width="20" height="20" patternUnits="userSpaceOnUse">
              <path d="M 20 0 L 0 0 0 20" fill="none" stroke="#333" strokeWidth="0.5" />
            </pattern>
          </defs>
          <rect width="100%" height="100%" fill="url(#grid)" />
          {/* Center lines */}
          <line x1="50%" y1="0" x2="50%" y2="100%" stroke="#444" strokeWidth="1" strokeDasharray="4" />
          <line x1="0" y1="50%" x2="100%" y2="50%" stroke="#444" strokeWidth="1" strokeDasharray="4" />
        </svg>

        {/* Position indicator */}
        <div
          style={{
            position: 'absolute',
            left: `calc(50% + ${position.x / 10}px)`,
            top: `calc(50% + ${position.y / 10}px)`,
            transform: `translate(-50%, -50%) rotate(${position.rotation}deg) scale(${position.scale})`,
            width: 60,
            height: 40,
            background: 'var(--accent)',
            borderRadius: 4,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            fontSize: 11,
            fontWeight: 600,
            boxShadow: '0 2px 8px rgba(0,0,0,0.5)',
            transition: 'all 0.1s ease',
          }}
        >
          OUTPUT
        </div>
      </div>
    </div>
  );
}
