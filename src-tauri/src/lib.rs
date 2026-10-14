use boltbar_core::auth::secrets::default_store;
use boltbar_core::auth::AuthPaths;
use boltbar_core::settings::{load_settings, save_settings, Settings};
use boltbar_core::types::{
    ChatRequest, ProviderInfo, ProviderKind, StreamEvent,
};
use boltbar_core::Engine;
use serde::Serialize;
use tauri::{
    image::Image,
    include_image,
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    AppHandle, Emitter, LogicalSize, Manager, PhysicalPosition, State, WebviewUrl,
    WebviewWindowBuilder,
};
use tokio::sync::Mutex;

struct AppState {
    engine: Engine,
    settings: Mutex<Settings>,
}

#[derive(Clone, Serialize)]
struct Bootstrap {
    settings: Settings,
    providers: Vec<ProviderInfo>,
    keychain_native: bool,
}

fn data_dir(app: &AppHandle) -> std::path::PathBuf {
    app.path()
        .app_data_dir()
        .unwrap_or_else(|_| std::env::temp_dir().join("boltbar"))
}

#[tauri::command]
async fn bootstrap(state: State<'_, AppState>) -> Result<Bootstrap, String> {
    let settings = state.settings.lock().await.clone();
    let providers = state.engine.providers(&settings, true).await;

    Ok(Bootstrap {
        settings,
        providers,
        keychain_native: cfg!(target_os = "macos"),
    })
}

#[tauri::command]
async fn save_user_settings(
    app: AppHandle,
    state: State<'_, AppState>,
    settings: Settings,
) -> Result<Vec<ProviderInfo>, String> {
    let mut saved_settings = state.settings.lock().await;
    let previous = saved_settings.clone();
    if settings.hotkey != previous.hotkey {
        register_hotkey(&app, &settings.hotkey, Some(&previous.hotkey))?;
    }
    if let Err(err) = save_settings(&data_dir(&app), &settings) {
        let _ = register_hotkey(&app, &previous.hotkey, Some(&settings.hotkey));
        return Err(err.to_string());
    }
    {
        let mut url = state.engine.cursor_base_url.lock().map_err(|e| e.to_string())?;
        *url = settings.cursor_base_url.clone();
    }
    let providers = state.engine.providers(&settings, false).await;
    *saved_settings = settings.clone();
    let _ = app.emit("settings-changed", Bootstrap {
        settings, providers: providers.clone(), keychain_native: cfg!(target_os = "macos"),
    });
    Ok(providers)
}

#[tauri::command]
async fn set_api_key(
    state: State<'_, AppState>,
    provider: ProviderKind,
    key: String,
) -> Result<boltbar_core::AuthStatus, String> {
    if matches!(provider, ProviderKind::Demo) {
        return Err("the demo provider has no API key".into());
    }
    let account = provider.as_str();
    if key.trim().is_empty() {
        state
            .engine
            .secrets
            .delete(account)
            .map_err(|e| e.to_string())?;
    } else {
        state
            .engine
            .secrets
            .set(account, key.trim())
            .map_err(|e| e.to_string())?;
    }
    Ok(state.engine.auth_status(provider))
}

#[tauri::command]
async fn refresh_models(app: AppHandle, state: State<'_, AppState>) -> Result<Vec<ProviderInfo>, String> {
    let settings = state.settings.lock().await.clone();
    let providers = state.engine.providers(&settings, true).await;
    let _ = app.emit("settings-changed", Bootstrap {
        settings, providers: providers.clone(), keychain_native: cfg!(target_os = "macos"),
    });
    Ok(providers)
}

#[tauri::command]
async fn open_settings(app: AppHandle) -> Result<(), String> {
    open_settings_window(&app)
}

#[tauri::command]
async fn close_settings(app: AppHandle) -> Result<(), String> {
    if let Some(win) = app.get_webview_window("settings") {
        win.close().map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
async fn start_chat(
    app: AppHandle,
    state: State<'_, AppState>,
    request: ChatRequest,
    request_id: String,
) -> Result<(), String> {
    let engine = state.engine.clone();
    tokio::spawn(async move {
        let (tx, mut rx) = tokio::sync::mpsc::channel::<StreamEvent>(64);
        let emit = app.clone();
        tokio::spawn(async move {
            while let Some(event) = rx.recv().await {
                let _ = emit.emit("chat-event", serde_json::json!({ "request_id": request_id, "event": event }));
            }
        });
        engine.stream_chat(request, tx).await;
    });
    Ok(())
}

#[tauri::command]
async fn stop_chat(state: State<'_, AppState>) -> Result<(), String> {
    state.engine.cancel_active().await;
    Ok(())
}

#[tauri::command]
async fn hide_bar(app: AppHandle) -> Result<(), String> {
    if let Some(win) = app.get_webview_window("main") {
        win.hide().map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
fn new_chat(app: AppHandle) { show_bar(&app); }

#[tauri::command]
async fn resize_bar(app: AppHandle, width: f64, height: f64) -> Result<(), String> {
    if let Some(win) = app.get_webview_window("main") {
        let w = width.clamp(
            boltbar_core::settings::MIN_BAR_WIDTH,
            boltbar_core::settings::MAX_BAR_WIDTH,
        );
        let monitor = win.current_monitor().ok().flatten();
        let screen_height = monitor.as_ref().map(|m| f64::from(m.size().height) / m.scale_factor() - 80.0).unwrap_or(900.0);
        let h = height.clamp(
            boltbar_core::settings::MIN_BAR_HEIGHT,
            boltbar_core::settings::MAX_BAR_HEIGHT.min(screen_height),
        );
        let scale = win.scale_factor().unwrap_or(1.0);
        if let (Ok(pos), Ok(size)) = (win.outer_position(), win.inner_size()) {
            let old_h = f64::from(size.height) / scale;
            let delta = h - old_h;
            if delta.abs() > 0.5 {
                let top = monitor.as_ref().map(|m| f64::from(m.position().y) + 38.0 * scale).unwrap_or(0.0);
                let new_y = (f64::from(pos.y) - delta * scale).max(top);
                let _ = win.set_position(PhysicalPosition::new(pos.x, new_y.round() as i32));
            }
        }
        win.set_size(LogicalSize::new(w, h))
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
async fn read_files(paths: Vec<String>) -> Result<Vec<boltbar_core::Attachment>, String> {
    let mut out = Vec::new();
    if paths.len() > boltbar_core::attachments::MAX_ATTACHMENTS {
        return Err("At most 6 attachments are allowed".into());
    }
    for path in paths {
        let metadata = std::fs::metadata(&path).map_err(|e| e.to_string())?;
        if !metadata.is_file() || metadata.len() > boltbar_core::attachments::MAX_ATTACHMENT_BYTES as u64 {
            return Err("Choose files of at most 10 MB each".into());
        }
        let bytes = std::fs::read(&path).map_err(|e| format!("{path}: {e}"))?;
        let name = std::path::Path::new(&path)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("file")
            .to_string();
        let mime = guess_mime(&name);
        out.push(boltbar_core::Attachment {
            name,
            mime,
            data_base64: {
                use base64::Engine as _;
                base64::engine::general_purpose::STANDARD.encode(bytes)
            },
        });
    }
    Ok(out)
}

fn guess_mime(name: &str) -> String {
    match boltbar_core::attachments::extension(name).as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        "pdf" => "application/pdf",
        "json" => "application/json",
        "md" | "markdown" => "text/markdown",
        "txt" | "log" => "text/plain",
        "rs" | "ts" | "tsx" | "js" | "jsx" | "py" | "go" | "swift" => "text/plain",
        other if !other.is_empty() => return format!("application/{other}"),
        _ => "application/octet-stream",
    }
    .into()
}

fn open_settings_window(app: &AppHandle) -> Result<(), String> {
    hide_main(app);
    if let Some(win) = app.get_webview_window("settings") {
        let _ = win.show();
        let _ = win.set_focus();
        return Ok(());
    }
    WebviewWindowBuilder::new(app, "settings", WebviewUrl::App("index.html#settings".into()))
        .title("Boltbar Settings")
        .inner_size(560.0, 720.0)
        .min_inner_size(440.0, 520.0)
        .decorations(true)
        .transparent(false)
        .resizable(true)
        .center()
        .visible(true)
        .skip_taskbar(false)
        .build()
        .map_err(|e| e.to_string())?;
    Ok(())
}

fn show_bar(app: &AppHandle) {
    let started = std::time::Instant::now();
    let _ = app.emit("conversation-reset", ());
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.set_visible_on_all_workspaces(true);
        let _ = win.center();
        let _ = win.show();
        let _ = win.set_focus();
    }
    if std::env::var_os("BOLTBAR_QA_METRICS").is_some() {
        eprintln!("{}", serde_json::json!({"kind":"show_native", "ms":started.elapsed().as_secs_f64()*1000.0}));
    }
}

fn hide_main(app: &AppHandle) {
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.hide();
    }
}

fn register_hotkey(app: &AppHandle, hotkey: &str, previous: Option<&str>) -> Result<(), String> {
    use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut};

    let shortcut: Shortcut = hotkey
        .parse()
        .map_err(|e| format!("invalid hotkey '{hotkey}': {e}"))?;
    // Register first: a collision must not destroy the existing working shortcut.
    if !app.global_shortcut().is_registered(shortcut) {
        app.global_shortcut().register(shortcut).map_err(|e| e.to_string())?;
    }
    if let Some(previous) = previous {
        if let Ok(old) = previous.parse::<Shortcut>() {
            if old != shortcut { let _ = app.global_shortcut().unregister(old); }
        }
    }
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let secrets = default_store();
    let engine = Engine::new(secrets, AuthPaths::default()).expect("engine");

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, _shortcut, event| {
                    if event.state == tauri_plugin_global_shortcut::ShortcutState::Pressed {
                        show_bar(app);
                    }
                })
                .build(),
        )
        .setup(move |app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            if let Some(win) = app.get_webview_window("main") {
                let _ = win.set_shadow(false);
                let _ = win.set_background_color(Some(tauri::window::Color(0, 0, 0, 0)));
            }

            let dir = data_dir(&app.handle());
            let mut settings = load_settings(&dir);
            {
                let mut url = engine.cursor_base_url.lock().expect("cursor url");
                *url = settings.cursor_base_url.clone();
            }
            if settings.hotkey.trim().is_empty() {
                settings.hotkey = boltbar_core::settings::DEFAULT_HOTKEY.into();
            }

            let handle = app.handle().clone();
            if let Err(err) = register_hotkey(&handle, &settings.hotkey, None) {
                eprintln!("boltbar: could not register hotkey: {err}");
                let _ = register_hotkey(&handle, boltbar_core::settings::DEFAULT_HOTKEY, None);
            }

            let show = MenuItem::with_id(app, "show", "New chat", true, Some("Alt+Space"))?;
            let settings_item =
                MenuItem::with_id(app, "settings", "Settings…", true, Some("CmdOrCtrl+,"))?;
            let hide = MenuItem::with_id(app, "hide", "Hide", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit Boltbar", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &settings_item, &hide, &quit])?;
            let icon: Image<'_> = include_image!("icons/32x32.png");
            TrayIconBuilder::new()
                .icon(icon)
                .menu(&menu)
                .tooltip("Boltbar")
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => show_bar(app),
                    "settings" => {
                        let _ = open_settings_window(app);
                    }
                    "hide" => hide_main(app),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .build(app)?;

            #[cfg(target_os = "macos")]
            if let Some(win) = app.get_webview_window("main") {
                if let Ok(ptr) = win.ns_window() {
                    // The pointer is owned by Tauri and this setup runs on the main thread.
                    unsafe {
                        use objc2_app_kit::{NSWindow, NSWindowCollectionBehavior as B};
                        let native = &*ptr.cast::<NSWindow>();
                        native.setCollectionBehavior(B::CanJoinAllSpaces | B::FullScreenAuxiliary);
                    }
                }
            }

            // First-run: show the bar so the user knows it launched.
            show_bar(&app.handle());

            app.manage(AppState {
                engine,
                settings: Mutex::new(settings),
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            bootstrap,
            save_user_settings,
            set_api_key,
            refresh_models,
            open_settings,
            close_settings,
            start_chat,
            stop_chat,
            hide_bar,
            new_chat,
            resize_bar,
            read_files
        ])
        .build(tauri::generate_context!())
        .expect("error while building boltbar")
        .run(|app, event| {
            #[cfg(target_os = "macos")]
            if let tauri::RunEvent::Reopen { .. } = event { show_bar(app); }
            let _ = (app, event);
        });
}
