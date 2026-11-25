#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EdidTiming {
    pub pixel_clock_10khz: u32,
    pub h_active: u32,
    pub h_blank: u32,
    pub h_front: u32,
    pub h_sync: u32,
    pub v_active: u32,
    pub v_blank: u32,
    pub v_front: u32,
    pub v_sync: u32,
}

impl EdidTiming {
    pub fn pixel_clock_mhz(self) -> f64 {
        f64::from(self.pixel_clock_10khz) / 100.0
    }
}

#[derive(Debug, Clone)]
pub struct EdidBuilder {
    pub width: u32,
    pub height: u32,
    pub refresh: u32,
    pub name: String,
}

impl EdidBuilder {
    pub fn normalized(width: u32, height: u32) -> (u32, u32) {
        (width.max(640).div_ceil(8) * 8, height.max(480) & !1)
    }

    pub fn timing(&self) -> EdidTiming {
        let (h_blank, h_front, h_sync) = (160, 48, 32);
        let ratio = f64::from(self.width) / f64::from(self.height);
        let v_sync = if (1.30..=1.36).contains(&ratio) {
            4
        } else if (1.74..=1.80).contains(&ratio) {
            5
        } else if (1.58..=1.62).contains(&ratio) {
            6
        } else if (1.22..=1.28).contains(&ratio) || (1.65..=1.70).contains(&ratio) {
            7
        } else {
            10
        };
        let h_period = (1.0 / f64::from(self.refresh) - 460e-6) / f64::from(self.height);
        let vbi_lines = (460e-6 / h_period) as u32 + 1;
        let v_blank = vbi_lines.max(3 + v_sync + 6);
        let clock = (self.width + h_blank) * (self.height + v_blank) * self.refresh;
        EdidTiming {
            pixel_clock_10khz: clock / 10_000,
            h_active: self.width,
            h_blank,
            h_front,
            h_sync,
            v_active: self.height,
            v_blank,
            v_front: 3,
            v_sync,
        }
    }

    pub fn build(&self) -> [u8; 256] {
        let timing = self.timing();
        let mut bytes = [0_u8; 256];
        bytes[..8].copy_from_slice(&[0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0]);
        bytes[8] = 0x39;
        bytes[9] = 0x76;
        bytes[10] = 1;
        bytes[12] = 1;
        bytes[16] = 1;
        bytes[17] = 36;
        bytes[18] = 1;
        bytes[19] = 4;
        bytes[20] = 0xa2;
        let width_cm = (f64::from(self.width) / 110.0 * 2.54).round() as u32;
        let height_cm = (f64::from(self.height) / 110.0 * 2.54).round() as u32;
        bytes[21] = width_cm.clamp(1, 255) as u8;
        bytes[22] = height_cm.clamp(1, 255) as u8;
        bytes[23] = 0x78;
        bytes[24] = 0x06;
        bytes[25..35]
            .copy_from_slice(&[0xee, 0x91, 0xa3, 0x54, 0x4c, 0x99, 0x26, 0x0f, 0x50, 0x54]);
        for index in 0..8 {
            bytes[38 + index * 2] = 1;
            bytes[39 + index * 2] = 1;
        }
        write_dtd(
            &mut bytes,
            54,
            timing,
            width_cm.min(255) * 10,
            height_cm.min(255) * 10,
        );

        let range = 72;
        bytes[range..range + 5].copy_from_slice(&[0, 0, 0, 0xfd, 0]);
        bytes[range + 5] = self.refresh.saturating_sub(5).clamp(1, 255) as u8;
        bytes[range + 6] = self.refresh.saturating_add(70).min(255) as u8;
        let h_khz = (((timing.h_active + timing.h_blank)
            * (timing.v_active + timing.v_blank)
            * self.refresh) as f64
            / f64::from(timing.h_active + timing.h_blank)
            / 1000.0)
            .ceil() as u32;
        bytes[range + 7] = h_khz.saturating_sub(5).clamp(15, 255) as u8;
        bytes[range + 8] = h_khz.saturating_add(10).min(255) as u8;
        bytes[range + 9] = ((timing.pixel_clock_mhz() / 10.0).ceil() as u32 + 1).min(255) as u8;
        bytes[range + 10] = 0;
        bytes[range + 11] = 0x0a;
        bytes[range + 12..range + 18].fill(0x20);

        let name = 90;
        bytes[name..name + 5].copy_from_slice(&[0, 0, 0, 0xfc, 0]);
        let mut chars = self
            .name
            .bytes()
            .filter(|value| (32..127).contains(value))
            .take(13)
            .collect::<Vec<_>>();
        if chars.len() < 13 {
            chars.push(0x0a);
        }
        chars.resize(13, 0x20);
        bytes[name + 5..name + 18].copy_from_slice(&chars);
        bytes[108..113].copy_from_slice(&[0, 0, 0, 0x10, 0]);
        bytes[126] = 1;
        bytes[127] = checksum(&bytes[..127]);

        bytes[128] = 2;
        bytes[129] = 3;
        bytes[130] = 10;
        bytes[132..138].copy_from_slice(&[0x65, 3, 0x0c, 0, 0x10, 0]);
        bytes[255] = checksum(&bytes[128..255]);
        bytes
    }
}

fn checksum(values: &[u8]) -> u8 {
    (256 - i32::from(
        values
            .iter()
            .fold(0_u8, |sum, value| sum.wrapping_add(*value)),
    ) % 256) as u8
}

fn write_dtd(
    bytes: &mut [u8; 256],
    offset: usize,
    timing: EdidTiming,
    width_mm: u32,
    height_mm: u32,
) {
    bytes[offset] = timing.pixel_clock_10khz as u8;
    bytes[offset + 1] = (timing.pixel_clock_10khz >> 8) as u8;
    bytes[offset + 2] = timing.h_active as u8;
    bytes[offset + 3] = timing.h_blank as u8;
    bytes[offset + 4] = (((timing.h_active >> 8) << 4) | (timing.h_blank >> 8)) as u8;
    bytes[offset + 5] = timing.v_active as u8;
    bytes[offset + 6] = timing.v_blank as u8;
    bytes[offset + 7] = (((timing.v_active >> 8) << 4) | (timing.v_blank >> 8)) as u8;
    bytes[offset + 8] = timing.h_front as u8;
    bytes[offset + 9] = timing.h_sync as u8;
    bytes[offset + 10] = (((timing.v_front & 0xf) << 4) | (timing.v_sync & 0xf)) as u8;
    bytes[offset + 11] = (((timing.h_front >> 8) << 6)
        | ((timing.h_sync >> 8) << 4)
        | ((timing.v_front >> 4) << 2)
        | (timing.v_sync >> 4)) as u8;
    bytes[offset + 12] = width_mm as u8;
    bytes[offset + 13] = height_mm as u8;
    bytes[offset + 14] = (((width_mm >> 8) << 4) | (height_mm >> 8)) as u8;
    bytes[offset + 17] = 0x1a;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_even_cvt_dimensions() {
        assert_eq!(EdidBuilder::normalized(1919, 1079), (1920, 1078));
    }

    #[test]
    fn builds_valid_256_byte_edid_with_checksums() {
        let edid = EdidBuilder {
            width: 1920,
            height: 1080,
            refresh: 60,
            name: "Windows".into(),
        }
        .build();
        assert_eq!(edid.len(), 256);
        assert_eq!(edid[..8], [0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0]);
        assert_eq!(edid[..128].iter().fold(0_u8, |a, b| a.wrapping_add(*b)), 0);
        assert_eq!(edid[128..].iter().fold(0_u8, |a, b| a.wrapping_add(*b)), 0);
    }
}
