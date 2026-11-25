use nanokvm_core::{Result, VideoCodec};
use serde::Serialize;

#[cfg(any(not(windows), test))]
use nanokvm_core::CoreError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub(crate) struct VideoCapabilities {
    pub native_surface: bool,
    pub hardware_h264: bool,
    pub hardware_h265: bool,
}

pub(crate) const PRESENTATION_UNAVAILABLE: &str = "Native video presentation is unavailable: the Direct3D child surface is not attached to the Tauri window. The authenticated video WebSocket can still verify that packets arrive, but this build does not use a web or canvas fallback.";

pub(crate) fn presentation_unavailable(capabilities: &VideoCapabilities) -> Option<&'static str> {
    (!capabilities.native_surface).then_some(PRESENTATION_UNAVAILABLE)
}

pub(crate) trait NativeVideoBackend {
    fn capabilities(&self) -> VideoCapabilities;
    fn configure(&mut self, codec: VideoCodec) -> Result<()>;
    fn submit(&mut self, codec: VideoCodec, annex_b: &[u8]) -> Result<()>;
    fn dimensions(&self) -> Option<(u32, u32)> {
        None
    }
}

#[cfg(any(not(windows), test))]
pub(crate) struct DisabledVideoBackend;

#[cfg(any(not(windows), test))]
impl NativeVideoBackend for DisabledVideoBackend {
    fn capabilities(&self) -> VideoCapabilities {
        VideoCapabilities {
            native_surface: false,
            hardware_h264: false,
            hardware_h265: false,
        }
    }

    fn configure(&mut self, _codec: VideoCodec) -> Result<()> {
        Err(CoreError::Unsupported(
            "the Windows Media Foundation decoder is not available on this build".to_owned(),
        ))
    }

    fn submit(&mut self, _codec: VideoCodec, _annex_b: &[u8]) -> Result<()> {
        Err(CoreError::Unsupported(
            "the Windows Media Foundation decoder is not available on this build".to_owned(),
        ))
    }
}

#[cfg(not(windows))]
pub(crate) fn create_backend() -> Box<dyn NativeVideoBackend + Send> {
    Box::new(DisabledVideoBackend)
}

#[cfg(windows)]
pub(crate) fn create_backend() -> Box<dyn NativeVideoBackend + Send> {
    Box::new(platform::WindowsVideoBackend::new())
}

#[cfg(windows)]
mod platform {
    use super::{NativeVideoBackend, VideoCapabilities};
    use nanokvm_core::{CoreError, Result, VideoCodec};
    use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_HARDWARE;
    use windows::Win32::Graphics::Direct3D11::{
        D3D11_CREATE_DEVICE_VIDEO_SUPPORT, D3D11_SDK_VERSION, D3D11CreateDevice, ID3D11Device,
    };
    use windows::Win32::Media::MediaFoundation::{
        IMFActivate, IMFDXGIDeviceManager, IMFTransform, MF_E_TRANSFORM_NEED_MORE_INPUT,
        MF_MT_FRAME_SIZE, MF_MT_MAJOR_TYPE, MF_MT_SUBTYPE, MFCreateDXGIDeviceManager,
        MFCreateMediaType, MFCreateMemoryBuffer, MFCreateSample, MFMediaType_Video, MFStartup,
        MFT_CATEGORY_VIDEO_DECODER, MFT_ENUM_FLAG_HARDWARE, MFT_ENUM_FLAG_SORTANDFILTER,
        MFT_ENUM_FLAG_SYNCMFT, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, MFT_MESSAGE_SET_D3D_MANAGER,
        MFT_OUTPUT_DATA_BUFFER, MFT_REGISTER_TYPE_INFO, MFTEnumEx, MFVideoFormat_H264,
        MFVideoFormat_HEVC,
    };
    use windows::Win32::System::Com::{COINIT_MULTITHREADED, CoInitializeEx, CoTaskMemFree};

    pub(crate) struct WindowsVideoBackend {
        codecs: VideoCapabilities,
        device: Option<ID3D11Device>,
        manager: Option<IMFDXGIDeviceManager>,
        transform: Option<IMFTransform>,
        reset_token: u32,
        dimensions: Option<(u32, u32)>,
    }

    unsafe impl Send for WindowsVideoBackend {}

    impl WindowsVideoBackend {
        pub(crate) fn new() -> Self {
            let codecs = VideoCapabilities {
                native_surface: false,
                hardware_h264: has_hardware_decoder(MFVideoFormat_H264),
                hardware_h265: has_hardware_decoder(MFVideoFormat_HEVC),
            };
            Self {
                codecs,
                device: None,
                manager: None,
                transform: None,
                reset_token: 0,
                dimensions: None,
            }
        }

        fn initialize_direct3d(&mut self) -> Result<()> {
            unsafe {
                let _ = CoInitializeEx(None, COINIT_MULTITHREADED).ok();
                MFStartup(0x0002_0070, 0).map_err(media_error)?;
                let mut device = None;
                D3D11CreateDevice(
                    None,
                    D3D_DRIVER_TYPE_HARDWARE,
                    Default::default(),
                    D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
                    None,
                    D3D11_SDK_VERSION,
                    Some(&mut device),
                    None,
                    None,
                )
                .map_err(media_error)?;
                let device = device
                    .ok_or_else(|| media_error_text("D3D11 device creation returned null"))?;
                let mut reset_token = 0;
                let mut manager = None;
                MFCreateDXGIDeviceManager(&mut reset_token, &mut manager).map_err(media_error)?;
                let manager = manager.ok_or_else(|| {
                    media_error_text("DXGI device manager creation returned null")
                })?;
                manager
                    .ResetDevice(&device, reset_token)
                    .map_err(media_error)?;
                self.device = Some(device);
                self.manager = Some(manager);
                self.reset_token = reset_token;
            }
            Ok(())
        }

        fn initialize_decoder(&mut self, codec: VideoCodec) -> Result<()> {
            let subtype = match codec {
                VideoCodec::H264 => MFVideoFormat_H264,
                VideoCodec::H265 => MFVideoFormat_HEVC,
            };
            unsafe {
                let transform = activate_decoder(subtype)?;
                let manager = self
                    .manager
                    .as_ref()
                    .ok_or_else(|| media_error_text("DXGI manager is not initialized"))?;
                transform
                    .ProcessMessage(
                        MFT_MESSAGE_SET_D3D_MANAGER,
                        windows::core::Interface::as_raw(manager) as usize,
                    )
                    .map_err(media_error)?;
                let input = MFCreateMediaType().map_err(media_error)?;
                input
                    .SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)
                    .map_err(media_error)?;
                input
                    .SetGUID(&MF_MT_SUBTYPE, &subtype)
                    .map_err(media_error)?;
                transform.SetInputType(0, &input, 0).map_err(media_error)?;
                let output = transform
                    .GetOutputAvailableType(0, 0)
                    .map_err(media_error)?;
                transform
                    .SetOutputType(0, &output, 0)
                    .map_err(media_error)?;
                if let Ok(frame_size) = output.GetUINT64(&MF_MT_FRAME_SIZE) {
                    self.dimensions = Some((
                        (frame_size >> 32) as u32,
                        (frame_size & u32::MAX as u64) as u32,
                    ));
                }
                transform
                    .ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)
                    .map_err(media_error)?;
                self.transform = Some(transform);
            }
            Ok(())
        }
    }

    impl NativeVideoBackend for WindowsVideoBackend {
        fn capabilities(&self) -> VideoCapabilities {
            self.codecs
        }

        fn configure(&mut self, codec: VideoCodec) -> Result<()> {
            let available = match codec {
                VideoCodec::H264 => self.codecs.hardware_h264,
                VideoCodec::H265 => self.codecs.hardware_h265,
            };
            if !available {
                return Err(CoreError::Unsupported(format!(
                    "no hardware Media Foundation decoder is registered for {codec:?}"
                )));
            }
            self.initialize_direct3d()?;
            self.initialize_decoder(codec)
        }

        fn submit(&mut self, codec: VideoCodec, annex_b: &[u8]) -> Result<()> {
            if annex_b.is_empty() || self.device.is_none() || self.manager.is_none() {
                return Err(media_error_text(
                    "the DXVA decoder is not initialized for this access unit",
                ));
            }
            let transform = self.transform.as_ref().ok_or_else(|| {
                media_error_text(format!(
                    "the {codec:?} Media Foundation decoder is not initialized"
                ))
            })?;
            let length = u32::try_from(annex_b.len())
                .map_err(|_| media_error_text("the Annex-B access unit is too large"))?;
            unsafe {
                let buffer = MFCreateMemoryBuffer(length).map_err(media_error)?;
                let mut address = std::ptr::null_mut();
                buffer.Lock(&mut address, None, None).map_err(media_error)?;
                if address.is_null() {
                    return Err(media_error_text(
                        "Media Foundation returned a null sample buffer",
                    ));
                }
                std::ptr::copy_nonoverlapping(annex_b.as_ptr(), address, annex_b.len());
                buffer.Unlock().map_err(media_error)?;
                buffer.SetCurrentLength(length).map_err(media_error)?;
                let sample = MFCreateSample().map_err(media_error)?;
                sample.AddBuffer(&buffer).map_err(media_error)?;
                transform.ProcessInput(0, &sample, 0).map_err(media_error)?;

                let mut output = MFT_OUTPUT_DATA_BUFFER::default();
                let mut output_status = 0;
                match transform.ProcessOutput(
                    0,
                    std::slice::from_mut(&mut output),
                    &mut output_status,
                ) {
                    Ok(()) => {
                        drop(std::mem::ManuallyDrop::take(&mut output.pSample));
                        drop(std::mem::ManuallyDrop::take(&mut output.pEvents));
                        Ok(())
                    }
                    Err(error) if error.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => Ok(()),
                    Err(error) => Err(media_error(error)),
                }
            }
        }

        fn dimensions(&self) -> Option<(u32, u32)> {
            self.dimensions
        }
    }

    fn activate_decoder(subtype: windows::core::GUID) -> Result<IMFTransform> {
        unsafe {
            let input = MFT_REGISTER_TYPE_INFO {
                guidMajorType: MFMediaType_Video,
                guidSubtype: subtype,
            };
            let mut activations: *mut Option<IMFActivate> = std::ptr::null_mut();
            let mut count = 0;
            MFTEnumEx(
                MFT_CATEGORY_VIDEO_DECODER,
                MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER,
                Some(&input),
                None,
                &mut activations,
                &mut count,
            )
            .map_err(media_error)?;
            if activations.is_null() || count == 0 {
                if !activations.is_null() {
                    CoTaskMemFree(Some(activations.cast()));
                }
                return Err(media_error_text(
                    "no hardware Media Foundation decoder is registered",
                ));
            }
            let activation_items =
                std::slice::from_raw_parts_mut(activations, count as usize).to_vec();
            let transform = activation_items
                .into_iter()
                .flatten()
                .find_map(|activation| activation.ActivateObject::<IMFTransform>().ok())
                .ok_or_else(|| {
                    media_error_text("the hardware Media Foundation decoder could not activate")
                })?;
            CoTaskMemFree(Some(activations.cast()));
            Ok(transform)
        }
    }

    fn has_hardware_decoder(subtype: windows::core::GUID) -> bool {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED).ok();
            if MFStartup(0x0002_0070, 0).is_err() {
                return false;
            }
            let input = MFT_REGISTER_TYPE_INFO {
                guidMajorType: MFMediaType_Video,
                guidSubtype: subtype,
            };
            let mut activations: *mut Option<IMFActivate> = std::ptr::null_mut();
            let mut count = 0;
            let result = MFTEnumEx(
                MFT_CATEGORY_VIDEO_DECODER,
                MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER,
                Some(&input),
                None,
                &mut activations,
                &mut count,
            );
            if !activations.is_null() {
                if result.is_ok() && count > 0 {
                    drop(std::slice::from_raw_parts_mut(activations, count as usize).to_vec());
                }
                CoTaskMemFree(Some(activations.cast()));
            }
            result.is_ok() && count > 0
        }
    }

    fn media_error(error: impl std::fmt::Display) -> CoreError {
        media_error_text(error.to_string())
    }

    fn media_error_text(message: impl Into<String>) -> CoreError {
        CoreError::Unsupported(format!("Windows video backend: {}", message.into()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unavailable_decoder_is_reported_explicitly() {
        let mut backend = DisabledVideoBackend;
        assert!(!backend.capabilities().hardware_h264);
        assert!(matches!(
            backend.configure(VideoCodec::H264),
            Err(CoreError::Unsupported(_))
        ));
    }

    #[test]
    fn missing_native_surface_has_an_actionable_reason() {
        let capabilities = DisabledVideoBackend.capabilities();
        assert_eq!(
            presentation_unavailable(&capabilities),
            Some(PRESENTATION_UNAVAILABLE)
        );
    }
}
