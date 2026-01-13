/**
 * DMX Visualizer API Client
 * Matches the endpoints in WebServer.swift
 */

let baseUrl = 'http://localhost:8082';

export function setBaseUrl(url) {
  baseUrl = url.replace(/\/$/, '');
}

export function getBaseUrl() {
  return baseUrl;
}

// Helper for API calls
async function apiCall(endpoint, options = {}) {
  const url = `${baseUrl}/api/v1${endpoint}`;
  try {
    const response = await fetch(url, {
      ...options,
      headers: {
        'Content-Type': 'application/json',
        ...options.headers,
      },
    });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    const text = await response.text();
    return text ? JSON.parse(text) : {};
  } catch (error) {
    console.error(`API Error [${endpoint}]:`, error);
    throw error;
  }
}

// ============================================
// Status
// ============================================

export async function getStatus() {
  return apiCall('/status');
}

export function getPreviewUrl() {
  return `${baseUrl}/api/v1/status/preview?t=${Date.now()}`;
}

// ============================================
// Outputs
// ============================================

export async function getOutputs() {
  return apiCall('/outputs');
}

export async function getDisplays() {
  return apiCall('/displays');
}

export async function addDisplayOutput(displayId) {
  return apiCall('/outputs/display', {
    method: 'POST',
    body: JSON.stringify({ displayId }),
  });
}

export async function addNDIOutput(name) {
  return apiCall('/outputs/ndi', {
    method: 'POST',
    body: JSON.stringify({ name }),
  });
}

export async function enableOutput(id) {
  return apiCall(`/outputs/${id}/enable`, { method: 'PUT' });
}

export async function disableOutput(id) {
  return apiCall(`/outputs/${id}/disable`, { method: 'PUT' });
}

export async function deleteOutput(id) {
  return apiCall(`/outputs/${id}`, { method: 'DELETE' });
}

export async function updateOutputSettings(id, settings) {
  return apiCall(`/outputs/${id}/settings`, {
    method: 'PUT',
    body: JSON.stringify(settings),
  });
}

// ============================================
// Gobos
// ============================================

export async function getGobos() {
  return apiCall('/gobos');
}

export function getGoboImageUrl(id) {
  return `${baseUrl}/api/v1/gobos/${id}/image`;
}

export async function uploadGobo(slot, file) {
  const formData = new FormData();
  formData.append('file', file);
  formData.append('slot', slot.toString());

  const response = await fetch(`${baseUrl}/api/v1/gobos/upload`, {
    method: 'POST',
    body: formData,
  });
  return response.json();
}

export async function deleteGobo(id) {
  return apiCall(`/gobos/${id}`, { method: 'DELETE' });
}

export async function moveGobo(fromSlot, toSlot) {
  return apiCall(`/gobos/${fromSlot}/move/${toSlot}`, { method: 'PUT' });
}

// ============================================
// Media Slots
// ============================================

export async function getMediaSlots() {
  return apiCall('/media/slots');
}

export async function assignMediaSlot(slot, source) {
  return apiCall(`/media/slots/${slot}`, {
    method: 'PUT',
    body: JSON.stringify({ source }),
  });
}

export async function clearMediaSlot(slot) {
  return apiCall(`/media/slots/${slot}`, { method: 'DELETE' });
}

export async function getVideos() {
  return apiCall('/media/videos');
}

export async function getImages() {
  return apiCall('/media/images');
}

export async function uploadVideo(file) {
  const formData = new FormData();
  formData.append('file', file);

  const response = await fetch(`${baseUrl}/api/v1/media/videos/upload`, {
    method: 'POST',
    body: formData,
  });
  return response.json();
}

export async function uploadImage(file) {
  const formData = new FormData();
  formData.append('file', file);

  const response = await fetch(`${baseUrl}/api/v1/media/images/upload`, {
    method: 'POST',
    body: formData,
  });
  return response.json();
}

// ============================================
// NDI Sources
// ============================================

export async function getNDISources() {
  return apiCall('/ndi/sources');
}

export async function refreshNDISources() {
  return apiCall('/ndi/refresh', { method: 'POST' });
}
