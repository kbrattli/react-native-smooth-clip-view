import { GalleryFlightGrid } from '../../galleryBench/galleryFlights';

export default function Grid() {
  return (
    <GalleryFlightGrid
      base="/gallery-flight"
      label="SmoothClipView flight, without teleport"
      teleport={false}
    />
  );
}
