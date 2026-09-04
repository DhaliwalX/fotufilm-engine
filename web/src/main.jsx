import React from 'react'
import { createRoot } from 'react-dom/client'
import { Theme } from '@astryxdesign/core/theme'
import { butterTheme } from '@astryxdesign/theme-butter/built'
import '@astryxdesign/core/reset.css'
import '@astryxdesign/core/astryx.css'
import '@astryxdesign/theme-butter/theme.css'
import App from './App.jsx'
import './app.css'

createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <Theme theme={butterTheme} mode="light">
      <App />
    </Theme>
  </React.StrictMode>
)
