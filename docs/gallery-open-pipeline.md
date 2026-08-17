# Gallery zero-blank open pipeline

## Status

Implemented in the example app (2026-08-17). Records why the gallery overlay
is not a route, why every pager page stacks two images, and why the opening
frame never reads the pager's scroll state.

## Problem

The original gallery flashed black between tapping a tile and seeing the
fullscreen image. Three independent causes stacked:

1. The fullscreen page mounted a new `expo-image` whose screen-size decode
   had never run; until it resolved the source was `null` and the page drew
   nothing.
2. `hiddenIndex` hid the grid tile the instant the open started, removing
   the only pixels that existed.
3. The `transparentModal` overlay route composited 4–5 frames after every
   JS-side ready signal (`onDisplay`, committed layout, `transitionEnd`),
   so any gate built from those signals started the clip clock over pixels
   nobody could see.

The mitigation — a tap-time prewarm store plus a five-signal gate with an
8-frame settle margin — converted blank frames into ~100–250 ms of open
latency, retained an unbounded `ImageRef` map, and left swipes to
neighbouring pages unprotected entirely.

## Reference

`react-native-teleport`'s PhotoGallery example has no blank frames because
it never creates pixels mid-transition: it re-parents the already-decoded
thumbnail view into a host rendered above the navigator, decodes the
full-res image at `opacity: 0` during the flight, and swaps both opacities
in one commit gated on animation-end and `onLoad`. Its close path uses no
re-parenting at all — plain overlapped transforms — which shows the overlap
technique alone is sufficient. Re-parenting exists there because their thumb
and full image are different crops; this gallery already synthesizes
pixel-identity geometrically (`resolveGalleryPresentation` makes the seeded
fullscreen page look exactly like the cover-cropped tile), so the principles
transfer without a native dependency.

## Pipeline

**Root-hosted overlay.** `GalleryOverlayHost` renders the overlay as a
sibling after `<Stack>` inside `SharedElementTransitionProvider`. Mounting
into the already-composited root surface puts the overlay's first commit on
screen at the next vsync; the modal-presentation latency, and the gate that
padded it, no longer exist. Window-space tile rects stay valid, close
teardown is one React commit, and Android back is a `BackHandler` that plays
the close animation.

**Two stacked images per page.** The bottom layer is the grid's own
cell-size decode: `galleryThumb.ts` computes one set of `maxWidth`/
`maxHeight` options used by both the grid tile and the page, so the page's
`useImage` call is a cache hit rather than a second decode. The opening page
additionally borrows the tapped tile's live `ImageRef` through the measured
payload — expo-image applies an `ImageRef` source synchronously in the iOS
prop setter, and `useImage` always returns `null` on its first render — then
hands off to its own hook ref for the same bitmap. The top layer is a plain
full-res `<Image>` sized fullscreen; it decodes under expo-image's own cache
eviction and paints over the thumb whenever it lands. The swap changes
sharpness only, never geometry, so no orchestration gates it.

**One signal, overlap instead of margins.** The grid tile stays visible
while the seeded overlay mounts over it pixel-identically; being a frame
early or late is an invisible overlap. The opening page's thumb `onDisplay`
fires `startOpen`, which hides the tile and starts the clip in one step.

## The initialScrollIndex hazard

`LegendList`'s `initialScrollIndex` content offset applies a few frames
late: the ScrollView clamps the offset until the list's content is sized.
During that window the clip — seeded for the opening page's coordinates —
shows page 0's territory, a black hole, and the image then pops in
mid-flight. A page-level `onDisplay` says nothing about scroll position;
this is the exact race the deleted gate's per-frame `measure(pageX) ≈ 0`
check guarded.

The fix removes the dependency instead of detecting it: while the phase is
OPENING, a standalone copy of the opening page renders absolutely above the
pager (unconditional pixels from the first commit), and the pager sits at
`opacity: 0` with scrolling disabled. When the phase leaves OPENING — via
completion, a dismiss grab, or a close — an animated reaction flips
`openSettled` and one commit swaps standalone for pager, pixel-identical
because the offset settled during the 400 ms flight.

## Invariant

At every frame, the tapped tile's rect holds tile pixels and/or thumbnail
pixels, and the clip window only ever expands over the standalone page's
image content. Blank frames require a frame with neither image, which the
overlap ordering makes unreachable. Swipes hold the same property
statistically rather than structurally: `drawDistance` of one screen width
premounts neighbours, whose thumbs are cache hits, before they can enter
the viewport.
