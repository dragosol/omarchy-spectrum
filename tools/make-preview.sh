#!/bin/sh
# Rebuilds preview.png, the marketplace card, from docs/window.png. Run from the repo root.
exec python3 tools/make_preview.py --shot docs/window.png --icon tools/icon.svg \
  --name Spectrum --name2 Visualizer --accent '#e0603f' \
  --tagline 'See your music,|live in your bar:|lows, mids and highs.' \
  --features '60 bands · peak hold|theme colours · pause' --out preview.png
