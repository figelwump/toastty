# Toastty App Icon Explorations

This folder contains a first-pass app icon study for Toastty, biased toward the bakery direction the brand work already favors. The primary review surface is [`contact-sheet.html`](./contact-sheet.html), which compares four concepts side by side and now includes 64px, 32px, and 16px scale checks for each option.

All four SVGs use a `1024x1024` canvas and keep the main artwork inset from the edges so there is safe-area headroom before final macOS packaging. The current recommendation is to refine `Bakery Window` and `Butter Grid`; `Toaster Terminal` is kept only as a contrast direction to show the more technical end of the spectrum.

For async review, use the exported `contact-sheet-preview.png` rather than relying on local HTML rendering. Known gaps for a production pass: macOS `.icns` packaging, light/dark variants, and final pixel-tuning after a direction is selected.
