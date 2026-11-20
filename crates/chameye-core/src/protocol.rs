use bytes::{Buf, BufMut, Bytes, BytesMut};
use prost::Message;

use crate::error::{ChameyeError, Result};

pub mod pb {
    include!(concat!(env!("OUT_DIR"), "/chameye.v1.rs"));
}

pub const PROTOCOL_VERSION: u32 = 1;
pub const MAX_CONTROL_FRAME_LEN: usize = 16 * 1024 * 1024; // 16 MiB (supports Retina clipboard images)
pub const MAX_VIDEO_FRAME_LEN: usize = 16 * 1024 * 1024; // 16 MiB

/// Unidirectional QUIC stream type discriminator (first byte on the stream).
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamType {
    Video = 0x01,
    Audio = 0x02,
    Blob = 0x03,
}

impl TryFrom<u8> for StreamType {
    type Error = ChameyeError;

    fn try_from(value: u8) -> Result<Self> {
        match value {
            0x01 => Ok(Self::Video),
            0x02 => Ok(Self::Audio),
            0x03 => Ok(Self::Blob),
            other => Err(ChameyeError::Protocol(format!("unknown stream type: {other}"))),
        }
    }
}

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VideoCodec {
    H264 = 1,
    Hevc = 2,
}

impl TryFrom<u8> for VideoCodec {
    type Error = ChameyeError;

    fn try_from(value: u8) -> Result<Self> {
        match value {
            1 => Ok(Self::H264),
            2 => Ok(Self::Hevc),
            other => Err(ChameyeError::Protocol(format!("unknown video codec: {other}"))),
        }
    }
}

pub const VIDEO_FLAG_KEYFRAME: u8 = 0x01;
pub const VIDEO_FLAG_CONFIG: u8 = 0x02;

/// Binary wire header size (after the 1-byte StreamType):
/// codec(1) + flags(1) + reserved(1) + window_id(4) + timestamp_us(8) + width(2) + height(2) + payload_len(4) = 23 bytes
pub const VIDEO_HEADER_LEN: usize = 23;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VideoFrame {
    pub codec: VideoCodec,
    pub flags: u8,
    pub window_id: u32,
    pub timestamp_us: u64,
    pub width: u16,
    pub height: u16,
    pub payload: Bytes,
}

impl VideoFrame {
    pub fn is_keyframe(&self) -> bool {
        (self.flags & VIDEO_FLAG_KEYFRAME) != 0
    }

    pub fn encode_frame(&self) -> Bytes {
        let mut buf = BytesMut::with_capacity(VIDEO_HEADER_LEN + self.payload.len());
        buf.put_u8(self.codec as u8);
        buf.put_u8(self.flags);
        buf.put_u8(0); // reserved
        buf.put_u32(self.window_id);
        buf.put_u64(self.timestamp_us);
        buf.put_u16(self.width);
        buf.put_u16(self.height);
        buf.put_u32(self.payload.len() as u32);
        buf.put_slice(&self.payload);
        buf.freeze()
    }

    pub fn decode_header(mut header: &[u8]) -> Result<(VideoCodec, u8, u32, u64, u16, u16, usize)> {
        if header.len() < VIDEO_HEADER_LEN {
            return Err(ChameyeError::Protocol("video header truncated".into()));
        }
        let codec = VideoCodec::try_from(header.get_u8())?;
        let flags = header.get_u8();
        let _reserved = header.get_u8();
        let window_id = header.get_u32();
        let timestamp_us = header.get_u64();
        let width = header.get_u16();
        let height = header.get_u16();
        let payload_len = header.get_u32() as usize;
        if payload_len > MAX_VIDEO_FRAME_LEN {
            return Err(ChameyeError::Protocol(format!(
                "video frame too large: {payload_len}"
            )));
        }
        Ok((codec, flags, window_id, timestamp_us, width, height, payload_len))
    }
}

pub fn encode_control(env: &pb::ControlEnvelope) -> Result<Bytes> {
    let payload_len = env.encoded_len();
    if payload_len > MAX_CONTROL_FRAME_LEN {
        return Err(ChameyeError::Protocol(format!(
            "control frame too large: {payload_len}"
        )));
    }
    let mut buf = BytesMut::with_capacity(4 + payload_len);
    buf.put_u32(payload_len as u32);
    env.encode(&mut buf)?;
    Ok(buf.freeze())
}

pub fn decode_control_payload(bytes: &[u8]) -> Result<pb::ControlEnvelope> {
    Ok(pb::ControlEnvelope::decode(bytes)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_video_frame() {
        let frame = VideoFrame {
            codec: VideoCodec::Hevc,
            flags: VIDEO_FLAG_KEYFRAME,
            window_id: 42,
            timestamp_us: 123_456_789,
            width: 1920,
            height: 1080,
            payload: Bytes::from_static(&[0x00, 0x00, 0x00, 0x01, 0x26, 0xAA]),
        };
        let encoded = frame.encode_frame();
        let (codec, flags, win_id, ts, w, h, len) =
            VideoFrame::decode_header(&encoded[..VIDEO_HEADER_LEN]).unwrap();
        assert_eq!(codec, VideoCodec::Hevc);
        assert_eq!(flags, VIDEO_FLAG_KEYFRAME);
        assert_eq!(win_id, 42);
        assert_eq!(ts, 123_456_789);
        assert_eq!(w, 1920);
        assert_eq!(h, 1080);
        assert_eq!(len, 6);
        assert_eq!(&encoded[VIDEO_HEADER_LEN..], frame.payload.as_ref());
    }

    #[test]
    fn roundtrip_control_envelope() {
        let env = pb::ControlEnvelope {
            seq: 7,
            payload: Some(pb::control_envelope::Payload::TextCommit(
                pb::TextCommitEvent {
                    window_id: 101,
                    text: "你好，微信！".to_string(),
                },
            )),
        };
        let framed = encode_control(&env).unwrap();
        let len = u32::from_be_bytes(framed[..4].try_into().unwrap()) as usize;
        assert_eq!(len, framed.len() - 4);
        let decoded = decode_control_payload(&framed[4..]).unwrap();
        assert_eq!(decoded, env);
    }
}
