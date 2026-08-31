import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
import UpstreamVersionCheck from './UpstreamVersionCheck'
import './styles.css'

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
    <UpstreamVersionCheck />
  </React.StrictMode>,
)
