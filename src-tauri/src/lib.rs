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
    AppHandle, Emitter, LogicalSize, Manager, State,
};
use tokio::sync::Mutex;

struct AppState {
    engine: Engine,
    settings: Mutex<Settings>,
}

#[derive(Serialize)]
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
async fn bootstrap(app: AppHandle, state: State<'_, AppState>) -> Result<Bootstrap, String> {
    let settings = state.settings.lock().await.clone();
    let providers = state.engine.providers(&settings);
    let _ = app;
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
    save_settings(&data_dir(&app), &settings).map_err(|e| e.to_string())?;
    {
        let mut url = state.engine.cursor_base_url.lock().map_err(|e| e.to_string())?;
        *url = settings.cursor_base_url.clone();
    }
    if let Err(err) = register_hotkey(&app, &settings.hotkey) {
        eprintln!("boltbar: could not register hotkey: {err}");
    }
    let providers = state.engine.providers(&settings);
    *state.settings.lock().await = settings;
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
async fn start_chat(
    app: AppHandle,
    state: State<'_, AppState>,
    request: ChatRequest,
) -> Result<(), String> {
    let engine = state.engine.clone();
    tokio::spawn(async move {
        let (tx, mut rx) = tokio::sync::mpsc::channel::<StreamEvent>(64);
        let emit = app.clone();
        tokio::spawn(async move {
            while let Some(event) = rx.recv().await {
                let _ = emit.emit("chat-event", event);
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
async fn resize_bar(app: AppHandle, width: f64, height: f64) -> Result<(), String> {
    if let Some(win) = app.get_webview_window("main") {
        let w = width.clamp(
            boltbar_core::settings::MIN_BAR_WIDTH,
            boltbar_core::settings::MAX_BAR_WIDTH,
        );
        let h = height.clamp(
            boltbar_core::settings::MIN_BAR_HEIGHT,
            boltbar_core::settings::MAX_BAR_HEIGHT,
        );
        win.set_size(LogicalSize::new(w, h))
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
async fn read_files(paths: Vec<String>) -> Result<Vec<boltbar_core::Attachment>, String> {
    let mut out = Vec::new();
    for path in paths {
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

fn show_bar(app: &AppHandle) {
    let _ = app.emit("conversation-reset", ());
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.center();
        let _ = win.show();
        let _ = win.set_focus();
    }
}

fn hide_main(app: &AppHandle) {
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.hide();
    }
}

fn toggle_bar(app: &AppHandle) {
    if let Some(win) = app.get_webview_window("main") {
        if win.is_visible().unwrap_or(false) {
            hide_main(app);
        } else {
            show_bar(app);
        }
    }
}

fn register_hotkey(app: &AppHandle, hotkey: &str) -> Result<(), String> {
    use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut};

    let shortcut: Shortcut = hotkey
        .parse()
        .map_err(|e| format!("invalid hotkey '{hotkey}': {e}"))?;
    let _ = app.global_shortcut().unregister_all();
    app.global_shortcut()
        .register(shortcut)
        .map_err(|e| e.to_string())
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
                        toggle_bar(app);
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
            if let Err(err) = register_hotkey(&handle, &settings.hotkey) {
                eprintln!("boltbar: could not register hotkey: {err}");
                let _ = register_hotkey(&handle, boltbar_core::settings::DEFAULT_HOTKEY);
            }

            let show = MenuItem::with_id(app, "show", "New chat", true, Some("Alt+Space"))?;
            let hide = MenuItem::with_id(app, "hide", "Hide", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit Boltbar", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &hide, &quit])?;
            let icon: Image<'_> = include_image!("icons/32x32.png");
            TrayIconBuilder::new()
                .icon(icon)
                .menu(&menu)
                .tooltip("Boltbar")
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => show_bar(app),
                    "hide" => hide_main(app),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let tauri::tray::TrayIconEvent::Click {
                        button: tauri::tray::MouseButton::Left,
                        button_state: tauri::tray::MouseButtonState::Up,
                        ..
                    } = event
                    {
                        toggle_bar(tray.app_handle());
                    }
                })
                .build(app)?;

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
            start_chat,
            stop_chat,
            hide_bar,
            resize_bar,
            read_files
        ])
        .run(tauri::generate_context!())
        .expect("error while running boltbar");
}
