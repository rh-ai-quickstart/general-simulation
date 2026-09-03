import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Production builds embed under /admin/ on the API. Local dev uses / on :5173.
const base = process.env.VITE_BASE_PATH || '/'

// https://vite.dev/config/
export default defineConfig({
  base,
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      '/health': 'http://localhost:8000',
      '/query': 'http://localhost:8000',
      '/admin': 'http://localhost:8000',
    },
  },
})
