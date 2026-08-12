export type Rect = { x: number; y: number; w: number; h: number };

export type ZoomCity = {
  id: string;
  title: string;
  lat: number;
  lon: number;
  /** Solid card fill. The reference app renders a weather shader here and
   *  falls back to exactly this palette in its "boring mode". */
  color: string;
  /** Static stand-in for the reference app's fetched aurora probability. */
  score: number;
};

/** The reference app's boring-mode card palette (util/getCardColor.ts). */
export const CARD_COLORS = [
  '#003f86',
  '#5E5CE6',
  '#1D6FA3',
  '#4A4DE7',
  '#2E86AB',
] as const;

export function getCardColor(index: number): string {
  return CARD_COLORS[index % CARD_COLORS.length]!;
}

export const ZOOM_CITIES: readonly ZoomCity[] = [
  {
    id: 'tromso',
    title: 'Tromsø',
    lat: 69.6492,
    lon: 18.9553,
    color: getCardColor(0),
    score: 78,
  },
  {
    id: 'reykjavik',
    title: 'Reykjavík',
    lat: 64.1466,
    lon: -21.9426,
    color: getCardColor(1),
    score: 54,
  },
  {
    id: 'fairbanks',
    title: 'Fairbanks',
    lat: 64.8378,
    lon: -147.7164,
    color: getCardColor(2),
    score: 91,
  },
];
