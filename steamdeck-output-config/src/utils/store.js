import { create } from 'zustand';

export const useStore = create((set, get) => ({
  // Connection state
  connected: false,
  connecting: false,
  serverUrl: 'ws://localhost:8080/ws',
  ws: null,

  // Outputs
  outputs: [],
  selectedOutputId: null,

  // Current mode: 'position' | 'keystone' | 'blend'
  mode: 'position',

  // Keystone - 8 corner points (normalized 0-1)
  keystone: {
    topLeft: { x: 0, y: 0 },
    topRight: { x: 1, y: 0 },
    bottomLeft: { x: 0, y: 1 },
    bottomRight: { x: 1, y: 1 },
    // Mid-edge points for 8-point warping
    topMid: { x: 0.5, y: 0 },
    bottomMid: { x: 0.5, y: 1 },
    leftMid: { x: 0, y: 0.5 },
    rightMid: { x: 1, y: 0.5 },
  },
  selectedCorner: 'topLeft',

  // Position
  position: {
    x: 0,
    y: 0,
    scale: 1,
    rotation: 0,
  },

  // Blend / Edge feathering
  blend: {
    top: { enabled: false, width: 0, curve: 0.5, gamma: 1 },
    bottom: { enabled: false, width: 0, curve: 0.5, gamma: 1 },
    left: { enabled: false, width: 0, curve: 0.5, gamma: 1 },
    right: { enabled: false, width: 0, curve: 0.5, gamma: 1 },
  },
  selectedEdge: 'left',

  // Gamepad state
  gamepadConnected: false,
  gamepadId: null,

  // Actions
  setServerUrl: (url) => set({ serverUrl: url }),

  setConnected: (connected) => set({ connected }),
  setConnecting: (connecting) => set({ connecting }),
  setWs: (ws) => set({ ws }),

  setOutputs: (outputs) => set({ outputs }),
  setSelectedOutputId: (id) => set({ selectedOutputId: id }),

  setMode: (mode) => set({ mode }),

  // Keystone actions
  setSelectedCorner: (corner) => set({ selectedCorner: corner }),
  updateCorner: (corner, x, y) => set((state) => ({
    keystone: {
      ...state.keystone,
      [corner]: { x: Math.max(0, Math.min(1, x)), y: Math.max(0, Math.min(1, y)) }
    }
  })),
  moveSelectedCorner: (dx, dy) => {
    const state = get();
    const corner = state.keystone[state.selectedCorner];
    state.updateCorner(state.selectedCorner, corner.x + dx, corner.y + dy);
  },
  resetKeystone: () => set({
    keystone: {
      topLeft: { x: 0, y: 0 },
      topRight: { x: 1, y: 0 },
      bottomLeft: { x: 0, y: 1 },
      bottomRight: { x: 1, y: 1 },
      topMid: { x: 0.5, y: 0 },
      bottomMid: { x: 0.5, y: 1 },
      leftMid: { x: 0, y: 0.5 },
      rightMid: { x: 1, y: 0.5 },
    }
  }),

  // Position actions
  updatePosition: (updates) => set((state) => ({
    position: { ...state.position, ...updates }
  })),
  movePosition: (dx, dy) => set((state) => ({
    position: {
      ...state.position,
      x: state.position.x + dx,
      y: state.position.y + dy
    }
  })),
  resetPosition: () => set({
    position: { x: 0, y: 0, scale: 1, rotation: 0 }
  }),

  // Blend actions
  setSelectedEdge: (edge) => set({ selectedEdge: edge }),
  updateBlend: (edge, updates) => set((state) => ({
    blend: {
      ...state.blend,
      [edge]: { ...state.blend[edge], ...updates }
    }
  })),
  toggleBlendEdge: (edge) => set((state) => ({
    blend: {
      ...state.blend,
      [edge]: { ...state.blend[edge], enabled: !state.blend[edge].enabled }
    }
  })),
  resetBlend: () => set({
    blend: {
      top: { enabled: false, width: 0, curve: 0.5, gamma: 1 },
      bottom: { enabled: false, width: 0, curve: 0.5, gamma: 1 },
      left: { enabled: false, width: 0, curve: 0.5, gamma: 1 },
      right: { enabled: false, width: 0, curve: 0.5, gamma: 1 },
    }
  }),

  // Gamepad
  setGamepadConnected: (connected, id = null) => set({
    gamepadConnected: connected,
    gamepadId: id
  }),

  // Send config to server
  sendConfig: () => {
    const state = get();
    if (!state.ws || state.ws.readyState !== WebSocket.OPEN) return;

    const config = {
      type: 'output_config',
      outputId: state.selectedOutputId,
      keystone: state.keystone,
      position: state.position,
      blend: state.blend,
    };

    state.ws.send(JSON.stringify(config));
  },

  // Load config from output
  loadOutputConfig: (config) => {
    if (config.keystone) set({ keystone: config.keystone });
    if (config.position) set({ position: config.position });
    if (config.blend) set({ blend: config.blend });
  },
}));
