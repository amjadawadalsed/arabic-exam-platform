import tailwindcss from '@tailwindcss/vite';
import react from '@vitejs/plugin-react';
import fs from 'fs';
import path from 'path';
import {defineConfig, type Plugin} from 'vite';

/**
 * The student/teacher HTML pages live in `public/`. Vite normally copies that
 * folder untouched, so those pages are never processed (no env injection, no
 * bundling of /src/js). We build them as extra HTML entries instead, which
 * emits the processed copies under `dist/public/...`.
 *
 * This plugin runs after everything is written and moves the processed pages
 * to their real URLs (`dist/student/*.html`, `dist/teacher/*.html`), replacing
 * the raw copies that came from `public/`. It only touches the build output.
 */
function movePublicPagesToRoot(outDir: string): Plugin {
  return {
    name: 'move-public-pages-to-root',
    apply: 'build',
    closeBundle() {
      const builtPublic = path.join(outDir, 'public');
      if (!fs.existsSync(builtPublic)) return;

      const moveDir = (from: string, to: string) => {
        fs.mkdirSync(to, {recursive: true});
        for (const entry of fs.readdirSync(from, {withFileTypes: true})) {
          const src = path.join(from, entry.name);
          const dst = path.join(to, entry.name);
          if (entry.isDirectory()) moveDir(src, dst);
          else fs.copyFileSync(src, dst);
        }
      };

      moveDir(builtPublic, outDir);
      fs.rmSync(builtPublic, {recursive: true, force: true});
    },
  };
}

export default defineConfig(() => {
  const rootDir = typeof import.meta.dirname !== 'undefined' ? import.meta.dirname : process.cwd();
  const outDir = path.resolve(rootDir, 'dist');

  return {
    plugins: [react(), tailwindcss(), movePublicPagesToRoot(outDir)],
    resolve: {
      alias: {
        '@': path.resolve(rootDir, '.'),
        '/js': path.resolve(rootDir, 'src/js'),
      },
    },
    build: {
      outDir,
      rollupOptions: {
        input: {
          main: path.resolve(rootDir, 'index.html'),
          studentDashboard: path.resolve(rootDir, 'public/student/dashboard.html'),
          studentExam: path.resolve(rootDir, 'public/student/exam.html'),
          studentResult: path.resolve(rootDir, 'public/student/result.html'),
          teacherDashboard: path.resolve(rootDir, 'public/teacher/dashboard.html'),
          teacherReview: path.resolve(rootDir, 'public/teacher/review.html'),
        },
      },
    },
    server: {
      // HMR is disabled in AI Studio via DISABLE_HMR env var.
      // Do not modify—file watching is disabled to prevent flickering during agent edits.
      hmr: process.env.DISABLE_HMR !== 'true',
      // Disable file watching when DISABLE_HMR is true to save CPU during agent edits.
      watch: process.env.DISABLE_HMR === 'true' ? null : {},
    },
  };
});
