import React from 'react'
import { createRoot } from 'react-dom/client'
import { Theme } from '@astryxdesign/core/theme'
import { neutralTheme } from '@astryxdesign/theme-neutral/built'
import '@astryxdesign/core/reset.css'
import '@astryxdesign/core/astryx.css'
import '@astryxdesign/theme-neutral/theme.css'
import App from './App.jsx'
import { controlIcons } from './icons.jsx'
import './app.css'

// Keep Neutral's prebuilt CSS and replace its control glyphs with Reicons.
const editorTheme = {
  ...neutralTheme,
  icons: { ...neutralTheme.icons, ...controlIcons },
}

createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <Theme theme={editorTheme}>
      <App />
    </Theme>
  </React.StrictMode>,
)
