import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

// The built assets replace the old public/ folder served by Express.
export default defineConfig({
  root: 'frontend',
  plugins: [react(), tailwindcss()],
  build: { outDir: '../public', emptyOutDir: true },
  // Dev server: API and WebSocket requests go to the Express process.
  server: {
    proxy: {
      '/api': 'http://localhost:8080',
      '/ws': { target: 'ws://localhost:8080', ws: true },
    },
  },
});
