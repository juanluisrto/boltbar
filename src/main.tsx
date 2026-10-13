import React, { useEffect, useState } from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import SettingsApp from "./SettingsApp";
import "./index.css";

function isSettingsView(): boolean {
  const hash = window.location.hash.replace(/^#/, "");
  return hash === "settings" || hash.startsWith("settings");
}

function Root() {
  const [settings, setSettings] = useState(isSettingsView);
  useEffect(() => {
    const onHash = () => setSettings(isSettingsView());
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);
  return settings ? <SettingsApp /> : <App />;
}

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <Root />
  </React.StrictMode>,
);
