import { GalleryMeasureLayout } from '../../galleryBench/galleryMeasure';

/** Gallery bench: Reanimated measure(), without teleport + width/height (docs/gallery-mount-time.md). */
export default function Layout() {
  return <GalleryMeasureLayout teleport={false} />;
}
