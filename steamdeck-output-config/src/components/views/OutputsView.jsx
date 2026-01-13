import React, { useEffect } from 'react';
import { useStore } from '../../utils/store';
import * as api from '../../utils/api';
import OutputSettingsModal from './OutputSettingsModal';

export default function OutputsView() {
  const {
    outputs, setOutputs,
    displays, setDisplays,
    connected,
    openSettingsModal,
  } = useStore();

  useEffect(() => {
    if (!connected) return;
    fetchData();
  }, [connected]);

  const fetchData = async () => {
    try {
      const [outputsData, displaysData] = await Promise.all([
        api.getOutputs(),
        api.getDisplays(),
      ]);
      setOutputs(outputsData.outputs || []);
      setDisplays(displaysData.displays || []);
    } catch (e) {
      console.error('Failed to fetch outputs:', e);
    }
  };

  const handleEnable = async (id) => {
    try {
      await api.enableOutput(id);
      fetchData();
    } catch (e) {
      console.error('Failed to enable output:', e);
    }
  };

  const handleDisable = async (id) => {
    try {
      await api.disableOutput(id);
      fetchData();
    } catch (e) {
      console.error('Failed to disable output:', e);
    }
  };

  const handleDelete = async (id) => {
    try {
      await api.deleteOutput(id);
      fetchData();
    } catch (e) {
      console.error('Failed to delete output:', e);
    }
  };

  const handleAddDisplay = async (displayId) => {
    try {
      await api.addDisplayOutput(displayId);
      fetchData();
    } catch (e) {
      console.error('Failed to add display:', e);
    }
  };

  const handleAddNDI = async () => {
    const name = prompt('NDI Output Name:', 'GeoDraw NDI');
    if (!name) return;
    try {
      await api.addNDIOutput(name);
      fetchData();
    } catch (e) {
      console.error('Failed to add NDI output:', e);
    }
  };

  return (
    <div className="outputs-view">
      <h2>Output Settings</h2>

      <div className="button-row">
        <button className="btn btn-primary" onClick={handleAddNDI}>
          + Add NDI Output
        </button>
      </div>

      <h3>Configured Outputs</h3>
      <div className="outputs-list">
        {outputs.length === 0 ? (
          <div className="empty-message">No outputs configured</div>
        ) : (
          outputs.map((output) => (
            <div
              key={output.id}
              className={`output-item ${output.enabled ? 'enabled' : 'disabled'}`}
            >
              <div className="output-info">
                <div className="output-name">{output.name}</div>
                <div className="output-type">{output.type}</div>
              </div>
              <div className="output-actions">
                <button
                  className="btn btn-settings"
                  onClick={() => openSettingsModal(output)}
                >
                  Settings
                </button>
                {output.enabled ? (
                  <button
                    className="btn btn-warning"
                    onClick={() => handleDisable(output.id)}
                  >
                    Disable
                  </button>
                ) : (
                  <button
                    className="btn btn-success"
                    onClick={() => handleEnable(output.id)}
                  >
                    Enable
                  </button>
                )}
                <button
                  className="btn btn-danger"
                  onClick={() => handleDelete(output.id)}
                >
                  Delete
                </button>
              </div>
            </div>
          ))
        )}
      </div>

      <h3>Available Displays</h3>
      <div className="displays-list">
        {displays.length === 0 ? (
          <div className="empty-message">No displays detected</div>
        ) : (
          displays.map((display) => (
            <div key={display.id} className="display-item">
              <div className="output-info">
                <div className="output-name">{display.name}</div>
                <div className="output-type">{display.resolution}</div>
              </div>
              <button
                className="btn btn-primary"
                onClick={() => handleAddDisplay(display.id)}
              >
                Add Output
              </button>
            </div>
          ))
        )}
      </div>

      <OutputSettingsModal onSave={fetchData} />
    </div>
  );
}
