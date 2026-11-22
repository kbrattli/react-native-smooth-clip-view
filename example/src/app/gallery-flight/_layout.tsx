import { GalleryFlightLayout } from '../../galleryBench/galleryFlights';

/** Gallery bench: SmoothClipView flight, without teleport (docs/gallery-mount-time.md). */
export default function Layout() {
  return <GalleryFlightLayout teleport={false} />;
}
