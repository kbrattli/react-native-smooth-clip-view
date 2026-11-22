import { GalleryMeasureGrid } from '../../galleryBench/galleryMeasure';

export default function Grid() {
  return (
    <GalleryMeasureGrid
      base="/gallery-measure-teleport"
      label="Reanimated measure(), with teleport"
      teleport={true}
    />
  );
}
