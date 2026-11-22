import { GALLERY_IMAGES, type GalleryImage } from '../galleryImages';
import { GALLERY_MEASURED_TILE } from './galleryBenchGeometry';

/**
 * The gallery bench's twelve photos, in tile order. The measured tile shows
 * the hero bench's photo (coastal overlook): its edges are bright against the
 * dark background, which the frame analysis needs.
 */
const ORDER = [
  'misty-pasture',
  'stone-aqueduct',
  'summer-gathering',
  'mountain-sunrise',
  'coastal-overlook',
  'poolside-fencing',
  'volcanic-shore',
  'foggy-laurel',
  'ocean-portrait',
  'waterfall-spray',
  'dragon-fountain',
  'red-sea-cliffs',
] as const;

export const GALLERY_PHOTOS: readonly GalleryImage[] = ORDER.map((id) => {
  const image = GALLERY_IMAGES.find((candidate) => candidate.id === id);
  if (!image) throw new Error(`gallery bench: no image ${id}`);
  return image;
});

if (GALLERY_PHOTOS[GALLERY_MEASURED_TILE]?.id !== 'coastal-overlook') {
  throw new Error('gallery bench: the measured tile must be coastal-overlook');
}

export function galleryPhoto(id: string | string[] | undefined): {
  index: number;
  photo: GalleryImage;
} {
  const index = Number(Array.isArray(id) ? id[0] : id);
  const photo = GALLERY_PHOTOS[index];
  if (!Number.isInteger(index) || !photo) {
    return { index: GALLERY_MEASURED_TILE, photo: GALLERY_PHOTOS[4]! };
  }
  return { index, photo };
}
