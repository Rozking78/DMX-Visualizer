import React from 'react';
import { useStore } from '../../utils/store';
import { throttledSendConfig } from '../../utils/websocket';

/**
 * BlendEditor - Edge blending / feathering controls
 *
 * Allows setting soft edge gradients for multi-projector setups
 */

const EDGE_ICONS = {
  top: '⬆',
  right: '➡',
  bottom: '⬇',
  left: '⬅',
};

export default function BlendEditor() {
  const {
    blend,
    selectedEdge,
    setSelectedEdge,
    updateBlend,
    toggleBlendEdge,
    mode,
  } = useStore();

  const handleWidthChange = (edge, value) => {
    updateBlend(edge, { width: value, enabled: value > 0 });
    throttledSendConfig();
  };

  const handleCurveChange = (edge, value) => {
    updateBlend(edge, { curve: value });
    throttledSendConfig();
  };

  const handleGammaChange = (edge, value) => {
    updateBlend(edge, { gamma: value });
    throttledSendConfig();
  };

  const isActive = mode === 'blend';

  return (
    <div className="blend-editor" style={{ opacity: isActive ? 1 : 0.5 }}>
      {/* Edge selector */}
      <div className="edge-selector" style={{
        display: 'grid',
        gridTemplateColumns: '1fr 1fr 1fr',
        gridTemplateRows: '1fr 1fr 1fr',
        gap: 4,
        width: 120,
        height: 120,
        margin: '0 auto 16px',
      }}>
        <div /> {/* empty */}
        <EdgeButton
          edge="top"
          blend={blend.top}
          selected={selectedEdge === 'top'}
          onSelect={() => setSelectedEdge('top')}
          onToggle={() => toggleBlendEdge('top')}
          disabled={!isActive}
        />
        <div /> {/* empty */}
        <EdgeButton
          edge="left"
          blend={blend.left}
          selected={selectedEdge === 'left'}
          onSelect={() => setSelectedEdge('left')}
          onToggle={() => toggleBlendEdge('left')}
          disabled={!isActive}
        />
        <div style={{
          background: '#16213e',
          borderRadius: 4,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          fontSize: 20,
        }}>
          📺
        </div>
        <EdgeButton
          edge="right"
          blend={blend.right}
          selected={selectedEdge === 'right'}
          onSelect={() => setSelectedEdge('right')}
          onToggle={() => toggleBlendEdge('right')}
          disabled={!isActive}
        />
        <div /> {/* empty */}
        <EdgeButton
          edge="bottom"
          blend={blend.bottom}
          selected={selectedEdge === 'bottom'}
          onSelect={() => setSelectedEdge('bottom')}
          onToggle={() => toggleBlendEdge('bottom')}
          disabled={!isActive}
        />
        <div /> {/* empty */}
      </div>

      {/* Selected edge controls */}
      <div className="edge-controls" style={{
        background: 'var(--bg-secondary)',
        borderRadius: 8,
        padding: 16,
      }}>
        <div style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          marginBottom: 16,
        }}>
          <span style={{ fontWeight: 600, textTransform: 'capitalize' }}>
            {EDGE_ICONS[selectedEdge]} {selectedEdge} Edge
          </span>
          <button
            onClick={() => toggleBlendEdge(selectedEdge)}
            disabled={!isActive}
            style={{
              padding: '6px 12px',
              fontSize: 13,
              background: blend[selectedEdge].enabled ? 'var(--accent)' : 'var(--bg-tertiary)',
            }}
          >
            {blend[selectedEdge].enabled ? 'Enabled' : 'Disabled'}
          </button>
        </div>

        <SliderControl
          label="Blend Width"
          value={blend[selectedEdge].width}
          min={0}
          max={0.5}
          step={0.01}
          onChange={(v) => handleWidthChange(selectedEdge, v)}
          format={(v) => `${(v * 100).toFixed(0)}%`}
          disabled={!isActive}
        />

        <SliderControl
          label="Curve"
          value={blend[selectedEdge].curve}
          min={0}
          max={1}
          step={0.01}
          onChange={(v) => handleCurveChange(selectedEdge, v)}
          format={(v) => v.toFixed(2)}
          disabled={!isActive || !blend[selectedEdge].enabled}
        />

        <SliderControl
          label="Gamma"
          value={blend[selectedEdge].gamma}
          min={0.1}
          max={3}
          step={0.05}
          onChange={(v) => handleGammaChange(selectedEdge, v)}
          format={(v) => v.toFixed(2)}
          disabled={!isActive || !blend[selectedEdge].enabled}
        />
      </div>

      {/* Visual preview of blend */}
      <div style={{
        marginTop: 16,
        height: 40,
        background: 'linear-gradient(to right, #000, #fff)',
        borderRadius: 4,
        position: 'relative',
        overflow: 'hidden',
      }}>
        {blend[selectedEdge].enabled && (
          <div style={{
            position: 'absolute',
            top: 0,
            left: 0,
            width: `${blend[selectedEdge].width * 100}%`,
            height: '100%',
            background: `linear-gradient(to right,
              rgba(233, 69, 96, 0.8) 0%,
              rgba(233, 69, 96, 0) 100%)`,
          }} />
        )}
        <div style={{
          position: 'absolute',
          top: '50%',
          left: '50%',
          transform: 'translate(-50%, -50%)',
          fontSize: 11,
          color: '#666',
        }}>
          Blend Preview
        </div>
      </div>
    </div>
  );
}

function EdgeButton({ edge, blend, selected, onSelect, onToggle, disabled }) {
  return (
    <button
      onClick={onSelect}
      onDoubleClick={onToggle}
      disabled={disabled}
      style={{
        background: selected ? 'var(--accent)' : (blend.enabled ? 'var(--bg-tertiary)' : 'var(--bg-primary)'),
        border: `2px solid ${selected ? 'var(--accent-hover)' : (blend.enabled ? 'var(--accent)' : 'var(--border-color)')}`,
        borderRadius: 4,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        fontSize: 16,
        padding: 0,
        cursor: disabled ? 'not-allowed' : 'pointer',
      }}
    >
      {EDGE_ICONS[edge]}
    </button>
  );
}

function SliderControl({ label, value, min, max, step, onChange, format, disabled }) {
  return (
    <div style={{ marginBottom: 12 }}>
      <div style={{
        display: 'flex',
        justifyContent: 'space-between',
        marginBottom: 4,
        fontSize: 13,
      }}>
        <span style={{ color: 'var(--text-secondary)' }}>{label}</span>
        <span style={{ fontFamily: 'monospace', fontWeight: 600 }}>
          {format ? format(value) : value}
        </span>
      </div>
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(e) => onChange(parseFloat(e.target.value))}
        disabled={disabled}
        style={{
          width: '100%',
          accentColor: 'var(--accent)',
        }}
      />
    </div>
  );
}
