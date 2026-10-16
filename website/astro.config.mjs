// @ts-check
import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://lopper.zawalid.com',
  output: 'static',
  build: { inlineStylesheets: 'auto' },
});
