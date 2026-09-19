import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { resolve } from 'path'

export default defineConfig({
  plugins: [react()],
  root: resolve(__dirname, 'src/renderer'),
  base: './',
  build: {
    outDir: resolve(__dirname, 'dist/renderer'),
    emptyOutDir: true,
  },
  resolve: {
    alias: [
      { find: '@', replacement: resolve(__dirname, 'src/renderer') },
      { find: /^@sotto\/voice\/main$/, replacement: resolve(__dirname, 'src/voice-dictation/main/index.ts') },
      { find: /^@sotto\/voice\/renderer$/, replacement: resolve(__dirname, 'src/voice-dictation/renderer/index.ts') },
      { find: /^@sotto\/voice$/, replacement: resolve(__dirname, 'src/voice-dictation/index.ts') },
    ],
  },
  server: {
    host: '127.0.0.1',
    port: 5174,
    strictPort: true,
    open: false,
  },
})
