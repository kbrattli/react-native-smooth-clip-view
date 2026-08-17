import { PixelRatio } from 'react-native';
import type { GalleryImage } from './galleryImages';

export const GALLERY_COLUMN_COUNT = 3;

export function galleryCellSize(windowWidth: number): number {
  return windowWidth / GALLERY_COLUMN_COUNT;
}

export type GalleryThumbOptions = Readonly<{
  /** Stable dep key: re-decode only when the cell's pixel size changes. */
  cellPixelSize: number;
  maxHeight: number;
  maxWidth: number;
}>;

// Decode at the size needed to cover the square cell: resize so the SHORTER
// side matches the cell's pixel size (maxWidth/maxHeight fit-within larger
// than the source is a no-op, so small sources are never upscaled). Grid tiles
// and pager thumb layers must both resolve their options here — expo-image
// keys cached decodes by source + max size, so byte-identical options turn the
// pager's request into a cache hit of the decode the grid already made.
export function galleryThumbOptions(
  image: GalleryImage,
  cellSize: number
): GalleryThumbOptions {
  const cellPixelSize = PixelRatio.getPixelSizeForLayoutSize(cellSize);
  const coverScale = cellPixelSize / Math.min(image.width, image.height);
  return {
    cellPixelSize,
    maxHeight: Math.ceil(image.height * coverScale),
    maxWidth: Math.ceil(image.width * coverScale),
  };
}
