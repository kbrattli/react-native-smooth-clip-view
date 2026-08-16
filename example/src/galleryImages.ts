export type GalleryImage = Readonly<{
  id: string;
  title: string;
  accessibilityLabel: string;
  source: number;
  width: number;
  height: number;
}>;

export const GALLERY_IMAGES: readonly GalleryImage[] = [
  {
    id: 'coastal-overlook',
    title: 'Coastal overlook',
    accessibilityLabel: 'Person overlooking a rugged coastline',
    source: require('../assets/gallery/coastal-overlook.jpg'),
    width: 1180,
    height: 1572,
  },
  {
    id: 'misty-pasture',
    title: 'Misty pasture',
    accessibilityLabel: 'Misty green pasture beneath steep mountains',
    source: require('../assets/gallery/misty-pasture.jpg'),
    width: 1180,
    height: 1572,
  },
  {
    id: 'stone-aqueduct',
    title: 'Stone aqueduct',
    accessibilityLabel: 'Historic stone aqueduct in a green landscape',
    source: require('../assets/gallery/stone-aqueduct.jpg'),
    width: 1180,
    height: 1572,
  },
  {
    id: 'summer-gathering',
    title: 'Summer gathering',
    accessibilityLabel: 'Friends gathered outdoors on a summer evening',
    source: require('../assets/gallery/summer-gathering.jpg'),
    width: 1180,
    height: 1572,
  },
  {
    id: 'waterfall-spray',
    title: 'Waterfall spray',
    accessibilityLabel: 'Wide waterfall sending mist across a rocky valley',
    source: require('../assets/gallery/waterfall-spray.jpg'),
    width: 2096,
    height: 1180,
  },
  {
    id: 'mountain-sunrise',
    title: 'Mountain sunrise',
    accessibilityLabel: 'Sunrise lighting a mountain valley',
    source: require('../assets/gallery/mountain-sunrise.jpg'),
    width: 1180,
    height: 1572,
  },
  {
    id: 'poolside-fencing',
    title: 'Poolside fencing',
    accessibilityLabel: 'Outdoor fencing practice beside a pool',
    source: require('../assets/gallery/poolside-fencing.jpg'),
    width: 1180,
    height: 1572,
  },
  {
    id: 'volcanic-shore',
    title: 'Volcanic shore',
    accessibilityLabel: 'Dark volcanic shoreline meeting the ocean',
    source: require('../assets/gallery/volcanic-shore.jpg'),
    width: 1180,
    height: 1572,
  },
  {
    id: 'foggy-laurel',
    title: 'Foggy laurel',
    accessibilityLabel: 'Ancient laurel forest covered in fog',
    source: require('../assets/gallery/foggy-laurel.jpg'),
    width: 1180,
    height: 1572,
  },
  {
    id: 'ocean-portrait',
    title: 'Ocean portrait',
    accessibilityLabel: 'Portrait by a bright blue ocean',
    source: require('../assets/gallery/ocean-portrait.jpg'),
    width: 1180,
    height: 1572,
  },
  {
    id: 'dragon-fountain',
    title: 'Dragon fountain',
    accessibilityLabel: 'Ornate dragon fountain sculpture',
    source: require('../assets/gallery/dragon-fountain.jpg'),
    width: 1174,
    height: 2090,
  },
  {
    id: 'red-sea-cliffs',
    title: 'Red Sea cliffs',
    accessibilityLabel: 'Red cliffs rising above a blue sea',
    source: require('../assets/gallery/red-sea-cliffs.jpg'),
    width: 1180,
    height: 1572,
  },
];

export const galleryImageKeyExtractor = (image: GalleryImage) => image.id;
