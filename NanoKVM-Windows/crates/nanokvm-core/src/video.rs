use serde::{Deserialize, Serialize};

use crate::{CoreError, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum VideoCodec {
    H264,
    H265,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FrameKind {
    Config,
    Key,
    Delta,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EncodedFrame {
    pub codec: VideoCodec,
    pub kind: FrameKind,
    pub data: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NalRole {
    Vps,
    Sps,
    Pps,
    Slice,
    Other,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VideoPacket {
    pub codec: VideoCodec,
    pub keyframe: bool,
    pub timestamp_micros: u64,
    pub annex_b: Vec<u8>,
}

impl VideoPacket {
    pub fn parse(codec: VideoCodec, bytes: &[u8]) -> Result<Self> {
        if bytes.len() < 9 {
            return Err(CoreError::InvalidVideoPacket);
        }
        let timestamp_micros = u64::from_le_bytes(
            bytes[1..9]
                .try_into()
                .map_err(|_| CoreError::InvalidVideoPacket)?,
        );
        let annex_b = bytes[9..].to_vec();
        if split_annex_b(&annex_b, 0).is_empty() {
            return Err(CoreError::MissingNalUnits);
        }
        Ok(Self {
            codec,
            keyframe: bytes[0] == 1,
            timestamp_micros,
            annex_b,
        })
    }

    pub fn nal_units(&self) -> Vec<Vec<u8>> {
        split_annex_b(&self.annex_b, 0)
            .into_iter()
            .map(|unit| unit.to_vec())
            .collect()
    }

    pub fn roles(&self) -> Vec<NalRole> {
        self.nal_units()
            .iter()
            .map(|unit| classify_nal(self.codec, unit))
            .collect()
    }
}

pub fn classify_nal(codec: VideoCodec, nal: &[u8]) -> NalRole {
    let Some(header) = nal.first() else {
        return NalRole::Other;
    };
    match codec {
        VideoCodec::H264 => match header & 0x1f {
            7 => NalRole::Sps,
            8 => NalRole::Pps,
            1 | 5 => NalRole::Slice,
            _ => NalRole::Other,
        },
        VideoCodec::H265 => match (header >> 1) & 0x3f {
            32 => NalRole::Vps,
            33 => NalRole::Sps,
            34 => NalRole::Pps,
            0..=9 | 16..=21 => NalRole::Slice,
            _ => NalRole::Other,
        },
    }
}

pub fn split_annex_b(bytes: &[u8], from: usize) -> Vec<&[u8]> {
    if from >= bytes.len() {
        return Vec::new();
    }
    let mut starts = Vec::new();
    let mut index = from;
    while index + 3 <= bytes.len() {
        if bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1 {
            starts.push((index, index + 3));
            index += 3;
            continue;
        }
        if index + 4 <= bytes.len()
            && bytes[index] == 0
            && bytes[index + 1] == 0
            && bytes[index + 2] == 0
            && bytes[index + 3] == 1
        {
            starts.push((index, index + 4));
            index += 4;
            continue;
        }
        index += 1;
    }

    starts
        .iter()
        .enumerate()
        .filter_map(|(position, &(_, data_start))| {
            let next_start = starts
                .get(position + 1)
                .map(|(start, _)| *start)
                .unwrap_or(bytes.len());
            let mut end = next_start;
            while end > data_start && bytes[end - 1] == 0 {
                end -= 1;
            }
            (end > data_start).then_some(&bytes[data_start..end])
        })
        .collect()
}

impl EncodedFrame {
    pub fn new(codec: VideoCodec, kind: FrameKind, data: Vec<u8>) -> Result<Self> {
        if data.is_empty() {
            return Err(CoreError::EmptyVideoFrame);
        }
        Ok(Self { codec, kind, data })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retains_annex_b_bytes() {
        let data = vec![0, 0, 0, 1, 0x65, 1, 2, 3];
        let frame = EncodedFrame::new(VideoCodec::H264, FrameKind::Key, data.clone()).unwrap();
        assert_eq!(frame.data, data);
    }

    #[test]
    fn rejects_empty_frame() {
        assert_eq!(
            EncodedFrame::new(VideoCodec::H265, FrameKind::Delta, Vec::new()),
            Err(CoreError::EmptyVideoFrame)
        );
    }

    #[test]
    fn parses_device_video_header_and_annex_b_units() {
        let mut bytes = vec![1];
        bytes.extend_from_slice(&1234_u64.to_le_bytes());
        bytes.extend_from_slice(&[0, 0, 0, 1, 0x67, 1, 0, 0, 1, 0x68, 2]);

        let packet = VideoPacket::parse(VideoCodec::H264, &bytes).unwrap();
        assert!(packet.keyframe);
        assert_eq!(packet.timestamp_micros, 1234);
        assert_eq!(packet.nal_units(), [vec![0x67, 1], vec![0x68, 2]]);
        assert_eq!(packet.roles(), [NalRole::Sps, NalRole::Pps]);
    }

    #[test]
    fn rejects_short_and_non_annex_b_packets() {
        assert_eq!(
            VideoPacket::parse(VideoCodec::H264, &[1, 2, 3]),
            Err(CoreError::InvalidVideoPacket)
        );
        let mut garbage = vec![0; 9];
        garbage.extend_from_slice(&[7, 8, 9]);
        assert_eq!(
            VideoPacket::parse(VideoCodec::H264, &garbage),
            Err(CoreError::MissingNalUnits)
        );
    }
}
