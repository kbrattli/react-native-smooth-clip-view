import { GalleryFlightGrid } from '../../galleryBench/galleryFlights';

export default function Grid() {
  return (
    <GalleryFlightGrid
      base="/gallery-flight-teleport"
      label="SmoothClipView flight, with teleport"
      teleport={true}
    />
  );
}
