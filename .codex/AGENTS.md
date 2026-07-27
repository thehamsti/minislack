# Frontend Project AGENTS.md

Copy this file as `AGENTS.md` (or `.codex/AGENTS.md`) into frontend project roots.

---

# Design Language

## Visual Identity

Clean, minimal interfaces with generous whitespace. Soft rounded corners (8–16px radius), subtle shadows, glassmorphism on navbars/cards. Light backgrounds (off-white/cream), near-black text, bold saturated accent color (green/orange/brand). Nature-inspired imagery, organic shapes.

## Typography

Bold punchy headlines, large hero text with lighter subheadings. Highlight key phrases with accent colors/underlines. One clear value proposition per section.

## Layout Patterns

Sticky pill navbar with backdrop blur | Hero: centered headline + dual CTAs | Trust logos (grayscale) | Features: icon + headline + description grid | Process: numbered steps | Pricing: 3-tier cards, highlight recommended | Testimonials: photo + quote + rating | Final CTA before footer

## UX Principles

Reduce cognitive load (one action per section), social proof early, progressive disclosure, mobile-first

---

# UI Gotchas

Non-obvious rules that models often miss:

- **iOS zoom:** `<input>` font-size must be ≥16px
- **Double-tap zoom:** Use `touch-action: manipulation`
- **Flex truncation:** Children need `min-w-0` to allow text truncation
- **Modal scroll:** `overscroll-behavior: contain` in modals/drawers
- **Number alignment:** `font-variant-numeric: tabular-nums` for comparisons
- **Anchor scroll:** `scroll-margin-top` on headings for sticky header offset
- **Hydration inputs:** `value` requires `onChange`, or use `defaultValue`
- **Hydration dates:** Guard date/time rendering against server/client mismatch
- **Windows select:** Native `<select>` needs explicit `background-color` and `color`
- **Reduced motion:** Honor `prefers-reduced-motion` (reduce/disable animations)
- **Animation props:** Only animate `transform` and `opacity`, never `top/left/width/height`
- **Transition explicit:** Never use `transition: all`; list properties explicitly
