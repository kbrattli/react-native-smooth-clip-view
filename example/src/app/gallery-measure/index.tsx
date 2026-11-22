import { GalleryMeasureGrid } from '../../galleryBench/galleryMeasure';

export default function Grid() {
  return (
    <GalleryMeasureGrid
      base="/gallery-measure"
      label="Reanimated measure(), without teleport"
      teleport={false}
    />
  );
}
