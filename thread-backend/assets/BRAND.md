# Thread: brand usage

Wordmark: `thread`, one solid weight. Symbol: one strand of thread that loops
once and ends in a violet bead. Accent: that bead.

The mark is in this folder, drawn as outlines so no font is needed to view it:
`thread-logo.svg` (primary wordmark with its clear space; `thread-logo.png` is
the same at 1024px wide and `thread-logo-512.png` at half size),
`thread-logo-hardware.svg`, `thread-logo-flat.svg` and
`thread-logo-reversed.svg` (the other variants below), `thread-icon.svg` with
`thread-icon.png` (the app icon), `thread-icon-ios.svg` with `AppIcon.png` (the
iPhone app icon), and `thread-lockup.svg` with `thread-lockup.png` (symbol and
wordmark together). The rest of the specification is this page.

## Variants

| Variant | File | Colour | Use |
|---|---|---|---|
| Primary | `thread-logo.svg` | ink on transparent | repo, README, print (light background) |
| Hardware | `thread-logo-hardware.svg` | ink on transparent | glasses display, projector, bright rooms |
| Flat | `thread-logo-flat.svg` | ink on transparent | embroidery, stickers, single-colour print |
| **Reversed** | `thread-logo-reversed.svg` | **white on reverse** | **dark UI, stage slides, demo video** |

The word is one solid weight, so primary, hardware and flat are the same
drawing. They are kept as three files so that anything that names one of them
keeps working.

## Specification

| | |
|---|---|
| Typeface | Poppins Medium (500). Outfit or Space Grotesk are acceptable substitutes; all three are free. |
| Case | Always lowercase. Never Thread, never THREAD. |
| Tracking | −2.8% of the type size. Tight, not touching. |
| Split | None. Every letter is solid: the word has no halves that mean anything on their own. |
| Motion | None. The wordmark does not animate. |

The letters are drawn to Poppins Medium's measurements at a type size of 100
units: stems 11.4 wide, x-height 55.1, ascender 74, `t` 66.5 tall, round
letters overshooting by 0.9 above and below. `a` is Poppins' own outline, `d`
is that `a` with its stem taken up to the ascender, and `t`, `h`, `r` and `e`
are built from the curves of Poppins' `c`, `a` and `b`.

| Colour | Hex |
|---|---|
| Ink | `#191817` |
| Accent | `#7F77DD` |
| Reverse | `#16161D` |

Accent use: the violet appears in one place, the bead at the end of the
thread in the symbol (on the app icon and in the lockup). It never touches the
wordmark. The app, the dashboard and the landing page take their colours from
the system, so their controls are the system's blue, not the accent.

## Symbol and app icon

One strand of thread, white on the dark tile. It comes in from the left, loops
once and leaves to the right, ending in a violet bead: picking up the thread of
a conversation where it was left. It is a single line of even weight with
round ends, and it has no letter in it. Used for the launcher icon and favicon.
The wordmark alone gives nothing square; the icon is its partner, not a second
logo.

Geometry, on the 132-unit tile:

- Stroke 12 units (9% of the tile), round ends. The SVGs store the thread as a
  filled outline; its centreline and weight are noted in a comment in each
  file.
- The loop is centred on the tile's vertical axis, 34 units across on its
  centreline. The two tails cross under it and run out to x 24 and x 108 at
  y 91.
- The bead is 18 units across (14% of the tile), centred on the end of the
  right tail.
- The whole symbol spans 18 to 117 across and 32 to 100 down, so it sits in the
  middle of the tile with nothing near the corners.

Keep it this simple. Do not turn the loop into a spiral or an `@` (that is
Threads, by Meta), do not add a second accent colour, and do not add
highlights, shadows or glows; iOS adds its own.

`thread-icon.svg` is the rounded tile (corner radius 30, about 23% of the
tile) for the web and anywhere the corners are not masked for you;
`thread-icon.png` is that file at 512px.

iOS rounds the corners of an app icon itself and does not accept transparency,
so the iPhone app uses `thread-icon-ios.svg`: the same tile filling the whole
square, with the symbol in the same place. `AppIcon.png` is that file at 1024px
with no alpha channel, and it goes in
`Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`. For a layered
Liquid Glass icon in Icon Composer, use the thread and the bead from
`thread-icon-ios.svg` as the foreground and set the background to ink there.
The thread is a large, simple shape, so the system's glass effects apply to it
and the dark and tinted versions keep the same silhouette.

## Lockup

`thread-lockup.svg` (and `thread-lockup.png`, 1024px wide) puts the symbol
before the wordmark on a light background: the thread in ink, the bead in
violet. The symbol is scaled to 95% so that its stroke equals the letters'
stem, its tails sit on the line where the round letters' bottoms sit, and the
gap to the `t` is half the clear space.

## Sizes

Minimum size: wordmark 54px wide on screen / 14mm in print; icon 24px.

Clear space: the height of the `e` on all sides, for the wordmark and the
lockup.

## On screen

The app, the dashboard and the landing page do not show the wordmark. They
show the name, Thread, in the system font at semibold weight, the way Apple
shows a product's name in a top bar. Everything else on those screens is in
the system font too, and the wordmark was the one thing that was not. The app
icon is still the launcher icon and the favicon.

The wordmark artwork in this folder is for everything else: print, slides,
stickers, the glasses display. Use the vector files, never a bitmap.

In running text the product is written Thread, as a name. Lowercase is for
the wordmark.
