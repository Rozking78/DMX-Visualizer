import { useStore } from './store';

let reconnectTimeout = null;
let reconnectAttempts = 0;
const MAX_RECONNECT_ATTEMPTS = 10;
const RECONNECT_DELAY = 3000;

export function connectWebSocket() {
  const { serverUrl, setConnected, setConnecting, setWs, setOutputs } = useStore.getState();

  // Clear any pending reconnect
  if (reconnectTimeout) {
    clearTimeout(reconnectTimeout);
    reconnectTimeout = null;
  }

  setConnecting(true);

  console.log(`Connecting to ${serverUrl}...`);

  const ws = new WebSocket(serverUrl);

  ws.onopen = () => {
    console.log('WebSocket connected');
    setConnected(true);
    setConnecting(false);
    setWs(ws);
    reconnectAttempts = 0;

    // Request current outputs
    ws.send(JSON.stringify({ type: 'get_outputs' }));
  };

  ws.onmessage = (event) => {
    try {
      const data = JSON.parse(event.data);
      handleMessage(data);
    } catch (e) {
      console.error('Failed to parse WebSocket message:', e);
    }
  };

  ws.onclose = () => {
    console.log('WebSocket disconnected');
    setConnected(false);
    setConnecting(false);
    setWs(null);

    // Attempt reconnect
    if (reconnectAttempts < MAX_RECONNECT_ATTEMPTS) {
      reconnectAttempts++;
      console.log(`Reconnecting in ${RECONNECT_DELAY}ms (attempt ${reconnectAttempts}/${MAX_RECONNECT_ATTEMPTS})...`);
      reconnectTimeout = setTimeout(connectWebSocket, RECONNECT_DELAY);
    }
  };

  ws.onerror = (error) => {
    console.error('WebSocket error:', error);
  };
}

export function disconnectWebSocket() {
  const { ws, setConnected, setWs } = useStore.getState();

  if (reconnectTimeout) {
    clearTimeout(reconnectTimeout);
    reconnectTimeout = null;
  }

  reconnectAttempts = MAX_RECONNECT_ATTEMPTS; // Prevent auto-reconnect

  if (ws) {
    ws.close();
    setWs(null);
    setConnected(false);
  }
}

function handleMessage(data) {
  const store = useStore.getState();

  switch (data.type) {
    case 'outputs':
      store.setOutputs(data.outputs || []);
      break;

    case 'output_config':
      if (data.outputId === store.selectedOutputId) {
        store.loadOutputConfig(data);
      }
      break;

    case 'output_updated':
      // Refresh outputs list
      const { ws } = store;
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'get_outputs' }));
      }
      break;

    case 'error':
      console.error('Server error:', data.message);
      break;

    default:
      console.log('Unknown message type:', data.type);
  }
}

// Send output config update
export function sendConfigUpdate() {
  const store = useStore.getState();
  store.sendConfig();
}

// Throttled send (for continuous gamepad updates)
let sendThrottleTimeout = null;
export function throttledSendConfig(delay = 50) {
  if (sendThrottleTimeout) return;

  sendThrottleTimeout = setTimeout(() => {
    sendConfigUpdate();
    sendThrottleTimeout = null;
  }, delay);
}
