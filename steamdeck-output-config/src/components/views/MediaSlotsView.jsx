import React, { useEffect, useRef } from 'react';
import { useStore } from '../../utils/store';
import * as api from '../../utils/api';

export default function MediaSlotsView() {
  const {
    mediaSlots, setMediaSlots,
    videos, setVideos,
    images, setImages,
    selectedMediaSlot, setSelectedMediaSlot,
    connected,
  } = useStore();
  const videoInputRef = useRef(null);
  const imageInputRef = useRef(null);

  useEffect(() => {
    if (!connected) return;
    fetchData();
  }, [connected]);

  const fetchData = async () => {
    try {
      const [slotsData, videosData, imagesData] = await Promise.all([
        api.getMediaSlots(),
        api.getVideos(),
        api.getImages(),
      ]);
      setMediaSlots(slotsData.slots || []);
      setVideos(videosData.videos || []);
      setImages(imagesData.images || []);
    } catch (e) {
      console.error('Failed to fetch media data:', e);
    }
  };

  const handleVideoUpload = async (e) => {
    const files = e.target.files;
    if (!files?.length) return;

    for (const file of files) {
      try {
        await api.uploadVideo(file);
      } catch (err) {
        console.error('Failed to upload video:', err);
      }
    }
    fetchData();
    e.target.value = '';
  };

  const handleImageUpload = async (e) => {
    const files = e.target.files;
    if (!files?.length) return;

    for (const file of files) {
      try {
        await api.uploadImage(file);
      } catch (err) {
        console.error('Failed to upload image:', err);
      }
    }
    fetchData();
    e.target.value = '';
  };

  const handleAssignSlot = async (slot, source) => {
    try {
      await api.assignMediaSlot(slot, source);
      fetchData();
    } catch (e) {
      console.error('Failed to assign slot:', e);
    }
  };

  const handleClearSlot = async (slot) => {
    try {
      await api.clearMediaSlot(slot);
      fetchData();
    } catch (e) {
      console.error('Failed to clear slot:', e);
    }
  };

  // Generate slots 201-255
  const slots = [];
  for (let i = 201; i <= 255; i++) {
    const slot = mediaSlots.find((s) => s.slot === i);
    slots.push({ slot: i, data: slot });
  }

  return (
    <div className="media-view">
      <h2>Media Slots (201-255)</h2>

      <div className="upload-zones">
        <div className="upload-zone">
          <p>Upload <b>video</b> files</p>
          <button
            className="btn btn-primary"
            onClick={() => videoInputRef.current?.click()}
          >
            Browse Videos
          </button>
          <input
            ref={videoInputRef}
            type="file"
            accept=".mp4,.mov,.avi,.mkv,.m4v,video/*"
            multiple
            onChange={handleVideoUpload}
            style={{ display: 'none' }}
          />
        </div>

        <div className="upload-zone">
          <p>Upload <b>image</b> files</p>
          <button
            className="btn btn-primary"
            onClick={() => imageInputRef.current?.click()}
          >
            Browse Images
          </button>
          <input
            ref={imageInputRef}
            type="file"
            accept=".png,.jpg,.jpeg,.gif,.tiff,.bmp,.webp,image/*"
            multiple
            onChange={handleImageUpload}
            style={{ display: 'none' }}
          />
        </div>
      </div>

      <div className="available-media">
        <h3>Available Media</h3>
        <div className="media-list">
          {videos.map((v) => (
            <span key={v.name} className="media-tag video">{v.name}</span>
          ))}
          {images.map((i) => (
            <span key={i.name} className="media-tag image">{i.name}</span>
          ))}
          {videos.length === 0 && images.length === 0 && (
            <span className="empty-message">No media uploaded</span>
          )}
        </div>
      </div>

      <table className="slots-table">
        <thead>
          <tr>
            <th>Slot</th>
            <th>Type</th>
            <th>Source</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          {slots.map(({ slot, data }) => (
            <tr
              key={slot}
              className={slot === selectedMediaSlot ? 'selected' : ''}
              onClick={() => setSelectedMediaSlot(slot)}
            >
              <td>{slot}</td>
              <td>{data?.type || '-'}</td>
              <td className={!data ? 'slot-empty' : ''}>{data?.source || 'Empty'}</td>
              <td>
                {data ? (
                  <button
                    className="btn btn-danger btn-small"
                    onClick={(e) => {
                      e.stopPropagation();
                      handleClearSlot(slot);
                    }}
                  >
                    Clear
                  </button>
                ) : (
                  <select
                    onChange={(e) => {
                      if (e.target.value) {
                        handleAssignSlot(slot, e.target.value);
                        e.target.value = '';
                      }
                    }}
                    defaultValue=""
                  >
                    <option value="">Assign...</option>
                    <optgroup label="Videos">
                      {videos.map((v) => (
                        <option key={v.name} value={`video:${v.name}`}>{v.name}</option>
                      ))}
                    </optgroup>
                    <optgroup label="Images">
                      {images.map((i) => (
                        <option key={i.name} value={`image:${i.name}`}>{i.name}</option>
                      ))}
                    </optgroup>
                  </select>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
