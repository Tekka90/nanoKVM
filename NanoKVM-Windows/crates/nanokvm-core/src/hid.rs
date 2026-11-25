use serde::{Deserialize, Serialize};

use crate::{CoreError, Result};

pub const MAX_HID_REPORT_LEN: usize = 64;
pub const SOURCE_BROWSER_KEYBOARD: u8 = 1;
pub const SOURCE_BROWSER_POINTER: u8 = 2;
pub const SOURCE_VIRTUAL_KEYBOARD: u8 = 16;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ReportKind {
    Keyboard = 1,
    RelativePointer = 2,
    AbsolutePointer = 3,
    PointerRelease = 6,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InputTransportReport(pub Vec<u8>);

impl InputTransportReport {
    pub fn new(
        source: u8,
        kind: ReportKind,
        sequence: u32,
        timestamp_ms: u32,
        payload: &[u8],
    ) -> Result<Self> {
        let mut bytes = vec![3, 1, source, kind as u8, 0];
        bytes.extend_from_slice(&sequence.to_le_bytes());
        bytes.extend_from_slice(&timestamp_ms.to_le_bytes());
        bytes.extend_from_slice(payload);
        Ok(Self(HidReport::new(bytes)?.bytes))
    }

    pub fn keyboard(
        source: u8,
        modifiers: u8,
        keys: &[u8],
        sequence: u32,
        timestamp_ms: u32,
    ) -> Result<Self> {
        let mut payload = Vec::with_capacity(8);
        payload.extend_from_slice(&[modifiers, 0]);
        payload.extend(keys.iter().take(6).copied());
        payload.resize(8, 0);
        Self::new(
            source,
            ReportKind::Keyboard,
            sequence,
            timestamp_ms,
            &payload,
        )
    }

    pub fn absolute_pointer(
        buttons: u8,
        x: f64,
        y: f64,
        wheel: i32,
        sequence: u32,
        timestamp_ms: u32,
    ) -> Result<Self> {
        let x = (x.clamp(0.0, 1.0) * u16::MAX as f64).round() as u16;
        let y = (y.clamp(0.0, 1.0) * u16::MAX as f64).round() as u16;
        let payload = pointer_payload(buttons, x.to_le_bytes(), y.to_le_bytes(), wheel);
        Self::new(
            SOURCE_BROWSER_POINTER,
            ReportKind::AbsolutePointer,
            sequence,
            timestamp_ms,
            &payload,
        )
    }

    pub fn relative_pointer(
        buttons: u8,
        dx: i32,
        dy: i32,
        wheel: i32,
        sequence: u32,
        timestamp_ms: u32,
    ) -> Result<Self> {
        let dx = i16::try_from(dx.clamp(i32::from(i16::MIN), i32::from(i16::MAX))).unwrap();
        let dy = i16::try_from(dy.clamp(i32::from(i16::MIN), i32::from(i16::MAX))).unwrap();
        let payload = pointer_payload(buttons, dx.to_le_bytes(), dy.to_le_bytes(), wheel);
        Self::new(
            SOURCE_BROWSER_POINTER,
            ReportKind::RelativePointer,
            sequence,
            timestamp_ms,
            &payload,
        )
    }

    pub fn pointer_release(sequence: u32, timestamp_ms: u32) -> Result<Self> {
        Self::new(
            SOURCE_BROWSER_POINTER,
            ReportKind::PointerRelease,
            sequence,
            timestamp_ms,
            &[0x0f],
        )
    }
}

fn pointer_payload(buttons: u8, x: [u8; 2], y: [u8; 2], wheel: i32) -> [u8; 7] {
    let wheel = i16::try_from(wheel.clamp(i32::from(i16::MIN), i32::from(i16::MAX))).unwrap();
    [
        buttons & 31,
        x[0],
        x[1],
        y[0],
        y[1],
        wheel.to_le_bytes()[0],
        wheel.to_le_bytes()[1],
    ]
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct KeyCode(pub u8);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct KeyEvent {
    pub code: KeyCode,
    pub pressed: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MouseButton {
    Left,
    Middle,
    Right,
    Back,
    Forward,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MouseEvent {
    Absolute { x: u16, y: u16 },
    Relative { x: i16, y: i16 },
    Wheel { x: i16, y: i16 },
    Button { button: MouseButton, pressed: bool },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HidReport {
    pub bytes: Vec<u8>,
}

impl HidReport {
    pub fn new(bytes: Vec<u8>) -> Result<Self> {
        if bytes.is_empty() {
            return Err(CoreError::EmptyHidReport);
        }
        if bytes.len() > MAX_HID_REPORT_LEN {
            return Err(CoreError::HidReportTooLarge(bytes.len()));
        }
        Ok(Self { bytes })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_empty_report() {
        assert_eq!(HidReport::new(Vec::new()), Err(CoreError::EmptyHidReport));
    }

    #[test]
    fn rejects_oversized_report() {
        let report = vec![0; MAX_HID_REPORT_LEN + 1];
        assert!(matches!(
            HidReport::new(report),
            Err(CoreError::HidReportTooLarge(_))
        ));
    }

    #[test]
    fn encodes_device_keyboard_frame() {
        let report =
            InputTransportReport::keyboard(SOURCE_BROWSER_KEYBOARD, 3, &[4, 5], 7, 1000).unwrap();
        assert_eq!(
            &report.0[..9],
            &[3, 1, SOURCE_BROWSER_KEYBOARD, 1, 0, 7, 0, 0, 0]
        );
        assert_eq!(&report.0[13..], &[3, 0, 4, 5, 0, 0, 0, 0]);
    }

    #[test]
    fn encodes_clamped_absolute_and_relative_pointers() {
        let absolute = InputTransportReport::absolute_pointer(1, 1.0, 0.5, -1, 1, 2).unwrap();
        assert_eq!(&absolute.0[13..], &[1, 0xff, 0xff, 0x00, 0x80, 0xff, 0xff]);
        let relative = InputTransportReport::relative_pointer(2, -2, 300, i32::MAX, 2, 3).unwrap();
        assert_eq!(&relative.0[13..], &[2, 0xfe, 0xff, 0x2c, 0x01, 0xff, 0x7f]);
    }
}
