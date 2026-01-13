import React, { useEffect, useRef } from 'react';
import { useStore } from '../../utils/store';
import * as api from '../../utils/api';

export default function GobosView() {
  const {
    gobos, setGobos,
    selectedGoboSlot, setSelectedGoboSlot,
    connected,
  } = useStore();
  const fileInputRef = useRef(null);

  useEffect(() => {
    if (!connected) return;
    fetchGobos();
  }, [connected]);

  const fetchGobos = async () => {
    try {
      const data = await api.getGobos();
      setGobos(data.gobos || []);
    } catch (e) {
      console.error('Failed to fetch gobos:', e);
    }
  };

  const handleUpload = async (e) => {
    const file = e.target.files?.[0];
    if (!file) return;

    try {
      await api.uploadGobo(selectedGoboSlot, file);
      fetchGobos();
      // Move to next slot
      if (selectedGoboSlot < 200) {
        setSelectedGoboSlot(selectedGoboSlot + 1);
      }
    } catch (err) {
      console.error('Failed to upload gobo:', err);
    }
    e.target.value = '';
  };

  const handleDelete = async (slot) => {
    try {
      await api.deleteGobo(slot);
      fetchGobos();
    } catch (e) {
      console.error('Failed to delete gobo:', e);
    }
  };

  // Generate slots 21-200
  const slots = [];
  for (let i = 21; i <= 200; i++) {
    const gobo = gobos.find((g) => g.slot === i);
    slots.push({ slot: i, gobo });
  }

  return (
    <div className="gobos-view">
      <h2>Gobos (Slots 21-200)</h2>

      <div className="upload-zone">
        <p>Upload gobo to specific DMX slot</p>
        <div className="upload-controls">
          <label>Slot:</label>
          <input
            type="number"
            min="21"
            max="200"
            value={selectedGoboSlot}
            onChange={(e) => setSelectedGoboSlot(parseInt(e.target.value) || 21)}
          />
          <button
            className="btn btn-primary"
            onClick={() => fileInputRef.current?.click()}
          >
            Browse PNG
          </button>
        </div>
        <input
          ref={fileInputRef}
          type="file"
          accept=".png,image/png"
          onChange={handleUpload}
          style={{ display: 'none' }}
        />
      </div>

      <div className="gobo-grid">
        {slots.map(({ slot, gobo }) => (
          <div
            key={slot}
            className={`gobo-item ${!gobo ? 'empty' : ''} ${slot === selectedGoboSlot ? 'selected' : ''}`}
            onClick={() => setSelectedGoboSlot(slot)}
          >
            {gobo ? (
              <>
                <img src={api.getGoboImageUrl(gobo.id)} alt={`Gobo ${slot}`} />
                <div className="gobo-id">#{slot}</div>
                <button
                  className="btn btn-danger btn-small"
                  onClick={(e) => {
                    e.stopPropagation();
                    handleDelete(slot);
                  }}
                >
                  ×
                </button>
              </>
            ) : (
              <>
                <div className="gobo-placeholder">Empty</div>
                <div className="gobo-id">#{slot}</div>
              </>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}
