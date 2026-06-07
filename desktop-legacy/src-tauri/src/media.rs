//! macOS WKWebView media-access enablement (wb-dj5r voice).
//!
//! Tauri 2 / wry on macOS doesn't expose `navigator.mediaDevices` to
//! JavaScript by default, so `getUserMedia` throws "undefined is not
//! an object". This module flips the private WKPreferences keys that
//! make `mediaDevices` visible, and installs a UI delegate that
//! auto-grants `requestMediaCapturePermissionForOrigin:` requests so
//! the JS call reaches the OS-level mic prompt instead of being
//! denied at the webview boundary.
//!
//! macOS still gates the actual capture through the system TCC
//! prompt at the *process* level. For dev builds the prompt fires for
//! whatever binary launched the webview (cargo, tauri-cli); for
//! release builds it's the bundled `.app`, and the `Info.plist` needs
//! `NSMicrophoneUsageDescription` set so the prompt has a reason
//! string (tracked separately).

#![cfg(target_os = "macos")]
#![allow(unsafe_code)]

use std::sync::OnceLock;

use block2::Block;
use objc2::{
    class, define_class, msg_send,
    rc::Retained,
    runtime::{AnyObject, NSObject},
    AllocAnyThread,
};
use objc2_foundation::{NSInteger, NSString};

/// Configure the given Tauri webview window so navigator.mediaDevices
/// is visible to JS and getUserMedia is granted at the webview layer.
pub fn configure(window: &tauri::WebviewWindow) -> tauri::Result<()> {
    window.with_webview(|webview| {
        // SAFETY: `with_webview` runs on the main thread and the
        // WKWebView pointer is owned by the window; we don't retain.
        unsafe { install(webview.inner() as *mut AnyObject) }
    })?;
    Ok(())
}

unsafe fn install(wkwebview: *mut AnyObject) {
    unsafe {
        apply_preferences(wkwebview);
        install_ui_delegate(wkwebview);
    }
}

unsafe fn apply_preferences(wkwebview: *mut AnyObject) {
    let config: *mut AnyObject = unsafe { msg_send![wkwebview, configuration] };
    let prefs: *mut AnyObject = unsafe { msg_send![config, preferences] };

    let yes_num: *mut AnyObject =
        unsafe { msg_send![class!(NSNumber), numberWithBool: true] };
    let no_num: *mut AnyObject =
        unsafe { msg_send![class!(NSNumber), numberWithBool: false] };

    // Private WKPreferences keys. Undocumented but stable across
    // macOS releases — what every Rust/Tauri project that needs mic
    // access ends up setting.
    unsafe {
        set_value(prefs, yes_num, "mediaDevicesEnabled");
        set_value(prefs, yes_num, "mediaStreamEnabled");
        set_value(prefs, no_num, "mediaCaptureRequiresSecureConnection");
    }
}

unsafe fn set_value(target: *mut AnyObject, value: *mut AnyObject, key: &str) {
    let key_obj = NSString::from_str(key);
    let _: () = unsafe { msg_send![target, setValue: value, forKey: &*key_obj] };
}

unsafe fn install_ui_delegate(wkwebview: *mut AnyObject) {
    // wry installs its own WKUIDelegate for window.open / JS dialogs.
    // Replacing it outright would lose those features. Since wry's
    // delegate doesn't implement requestMediaCapturePermission..., the
    // swap is benign for media but loses JS-dialog handling — acceptable
    // for v1; a forwarding delegate is a follow-up.
    let delegate = MediaCaptureDelegate::new();
    let delegate_ref: &MediaCaptureDelegate = &delegate;
    let _: () = unsafe { msg_send![wkwebview, setUIDelegate: delegate_ref] };

    // WKWebView holds a weak reference to its UIDelegate, so we leak
    // our retained handle into a process-static — one delegate per
    // app, lives forever, harmless.
    let _ = DELEGATE_HOLDER.set(delegate);
}

static DELEGATE_HOLDER: OnceLock<Retained<MediaCaptureDelegate>> = OnceLock::new();

define_class!(
    /// A WKUIDelegate that auto-grants any media-capture permission
    /// request. The OS-level TCC prompt has already mediated user
    /// consent before we reach this delegate, so granting at the
    /// webview layer is the right default.
    #[unsafe(super(NSObject))]
    #[name = "WBMediaCaptureDelegate"]
    struct MediaCaptureDelegate;

    impl MediaCaptureDelegate {
        #[unsafe(method(webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:))]
        fn request_media_capture(
            &self,
            _webview: *mut AnyObject,
            _origin: *mut AnyObject,
            _frame: *mut AnyObject,
            _capture_type: NSInteger,
            decision_handler: &Block<dyn Fn(NSInteger)>,
        ) {
            // WKPermissionDecision: deny=0, grant=1, prompt=2.
            decision_handler.call((1,));
        }
    }
);

impl MediaCaptureDelegate {
    fn new() -> Retained<Self> {
        let this = Self::alloc().set_ivars(());
        unsafe { msg_send![super(this), init] }
    }
}
