export type GalleryFrame = Readonly<{
  x: number;
  y: number;
  width: number;
  height: number;
}>;

export type GalleryPresentation = Readonly<{
  clip: GalleryFrame & Readonly<{ radius: 0 }>;
  contentScale: number;
  contentTranslateX: number;
  contentTranslateY: number;
}>;

export type GalleryPresentationScalars = readonly [
  x: number,
  y: number,
  width: number,
  height: number,
  topLeftRadius: number,
  topRightRadius: number,
  bottomRightRadius: number,
  bottomLeftRadius: number,
  curveCode: number,
  contentTranslateX: number,
  contentTranslateY: number,
  contentScale: number,
];

/**
 * The gallery uses SmoothClip's complete V2 presentation as its sole geometry
 * owner. Keeping this conversion beside the geometry prevents a gesture path
 * from accidentally falling back to V1 and dropping the content-scale frame.
 */
export function resolveGalleryPresentationScalars(
  presentation: GalleryPresentation
): GalleryPresentationScalars {
  'worklet';
  const radius = presentation.clip.radius;
  return [
    presentation.clip.x,
    presentation.clip.y,
    presentation.clip.width,
    presentation.clip.height,
    radius,
    radius,
    radius,
    radius,
    0,
    presentation.contentTranslateX,
    presentation.contentTranslateY,
    presentation.contentScale,
  ];
}

function sanitizeDimension(value: number) {
  'worklet';
  return Number.isFinite(value) && value > 0 ? value : 0;
}

function sanitizeCoordinate(value: number) {
  'worklet';
  return Number.isFinite(value) ? value : 0;
}

function clamp(value: number, minimum: number, maximum: number) {
  'worklet';
  return Math.min(maximum, Math.max(minimum, value));
}

/**
 * Converts the requested aperture into the exact host-visible aperture while
 * leaving the content transform untouched. Native performs the same clipping
 * for streamed writes, but an autonomous V2 `from` must already be normalized
 * so preflight can prove that every animation frame is host-independent.
 */
export function normalizeGalleryPresentationToHost(
  presentation: GalleryPresentation,
  hostWidth: number,
  hostHeight: number
): GalleryPresentation {
  'worklet';
  const boundedHostWidth = sanitizeDimension(hostWidth);
  const boundedHostHeight = sanitizeDimension(hostHeight);
  const requestedX = sanitizeCoordinate(presentation.clip.x);
  const requestedY = sanitizeCoordinate(presentation.clip.y);
  const requestedWidth = sanitizeDimension(presentation.clip.width);
  const requestedHeight = sanitizeDimension(presentation.clip.height);
  const left = clamp(requestedX, 0, boundedHostWidth);
  const top = clamp(requestedY, 0, boundedHostHeight);
  const right = clamp(requestedX + requestedWidth, 0, boundedHostWidth);
  const bottom = clamp(requestedY + requestedHeight, 0, boundedHostHeight);

  return {
    clip: {
      x: left,
      y: top,
      width: Math.max(0, right - left),
      height: Math.max(0, bottom - top),
      radius: 0,
    },
    contentTranslateX: presentation.contentTranslateX,
    contentTranslateY: presentation.contentTranslateY,
    contentScale: presentation.contentScale,
  };
}

function lerp(from: number, to: number, progress: number) {
  'worklet';
  return from + (to - from) * progress;
}

export function resolveAspectFitFrame(
  containerWidth: number,
  containerHeight: number,
  imageWidth: number,
  imageHeight: number
): GalleryFrame {
  'worklet';

  const safeContainerWidth = sanitizeDimension(containerWidth);
  const safeContainerHeight = sanitizeDimension(containerHeight);
  const safeImageWidth = sanitizeDimension(imageWidth);
  const safeImageHeight = sanitizeDimension(imageHeight);

  if (safeImageWidth === 0 || safeImageHeight === 0) {
    return {
      x: 0,
      y: 0,
      width: safeContainerWidth,
      height: safeContainerHeight,
    };
  }

  const scale = Math.min(
    safeContainerWidth / safeImageWidth,
    safeContainerHeight / safeImageHeight
  );
  const width = safeImageWidth * scale;
  const height = safeImageHeight * scale;

  return {
    x: (safeContainerWidth - width) / 2,
    y: (safeContainerHeight - height) / 2,
    width,
    height,
  };
}

export function interpolateGalleryFrame(
  source: GalleryFrame,
  destination: GalleryFrame,
  progress: number
): GalleryFrame {
  'worklet';

  const clampedProgress = clamp(progress, 0, 1);

  return {
    x: lerp(
      sanitizeCoordinate(source.x),
      sanitizeCoordinate(destination.x),
      clampedProgress
    ),
    y: lerp(
      sanitizeCoordinate(source.y),
      sanitizeCoordinate(destination.y),
      clampedProgress
    ),
    width: lerp(
      sanitizeDimension(source.width),
      sanitizeDimension(destination.width),
      clampedProgress
    ),
    height: lerp(
      sanitizeDimension(source.height),
      sanitizeDimension(destination.height),
      clampedProgress
    ),
  };
}

export function resolveGalleryFrameProgress(
  source: GalleryFrame,
  destination: GalleryFrame,
  current: GalleryFrame
) {
  'worklet';

  const channels = [
    [source.x, destination.x, current.x],
    [source.y, destination.y, current.y],
    [source.width, destination.width, current.width],
    [source.height, destination.height, current.height],
  ] as const;
  let strongest = channels[0];

  for (const channel of channels) {
    if (
      Math.abs(channel[1] - channel[0]) > Math.abs(strongest[1] - strongest[0])
    ) {
      strongest = channel;
    }
  }

  const distance = strongest[1] - strongest[0];
  if (!Number.isFinite(distance) || distance === 0) return 1;

  return clamp((strongest[2] - strongest[0]) / distance, 0, 1);
}

export function resolveGalleryPresentation(
  frame: GalleryFrame,
  destination: GalleryFrame,
  containerWidth: number,
  containerHeight: number
): GalleryPresentation {
  'worklet';

  const width = sanitizeDimension(frame.width);
  const height = sanitizeDimension(frame.height);
  const destinationWidth = sanitizeDimension(destination.width);
  const destinationHeight = sanitizeDimension(destination.height);
  const safeContainerWidth = sanitizeDimension(containerWidth);
  const safeContainerHeight = sanitizeDimension(containerHeight);
  const contentScale =
    destinationWidth === 0 || destinationHeight === 0
      ? 1
      : Math.max(width / destinationWidth, height / destinationHeight);
  const containerCenterX = safeContainerWidth / 2;
  const containerCenterY = safeContainerHeight / 2;
  const destinationCenterX =
    sanitizeCoordinate(destination.x) + destinationWidth / 2;
  const destinationCenterY =
    sanitizeCoordinate(destination.y) + destinationHeight / 2;
  const scaledDestinationCenterX =
    containerCenterX + (destinationCenterX - containerCenterX) * contentScale;
  const scaledDestinationCenterY =
    containerCenterY + (destinationCenterY - containerCenterY) * contentScale;

  return {
    clip: {
      x: sanitizeCoordinate(frame.x),
      y: sanitizeCoordinate(frame.y),
      width,
      height,
      radius: 0,
    },
    contentScale,
    contentTranslateX:
      sanitizeCoordinate(frame.x) + width / 2 - scaledDestinationCenterX,
    contentTranslateY:
      sanitizeCoordinate(frame.y) + height / 2 - scaledDestinationCenterY,
  };
}

const GALLERY_DRAG_SCALE_FLOOR = 0.82;

export function resolveGalleryDismissProgress(
  translateY: number,
  dismissDistance: number
) {
  'worklet';
  const safeDistance = sanitizeDimension(dismissDistance);
  if (safeDistance === 0) return translateY > 0 ? 1 : 0;
  return clamp(Math.max(0, translateY) / safeDistance, 0, 1);
}

export function resolveDraggedGalleryFrame(
  frame: GalleryFrame,
  translateX: number,
  translateY: number,
  dismissProgress: number
): GalleryFrame {
  'worklet';
  const progress = clamp(dismissProgress, 0, 1);
  const scale = lerp(1, GALLERY_DRAG_SCALE_FLOOR, progress);
  const width = sanitizeDimension(frame.width) * scale;
  const height = sanitizeDimension(frame.height) * scale;

  return {
    x:
      sanitizeCoordinate(frame.x) +
      (sanitizeDimension(frame.width) - width) / 2 +
      sanitizeCoordinate(translateX),
    y:
      sanitizeCoordinate(frame.y) +
      (sanitizeDimension(frame.height) - height) / 2 +
      Math.max(0, sanitizeCoordinate(translateY)),
    width,
    height,
  };
}

export function resolveGalleryBackdropOpacity(
  openProgress: number,
  dismissProgress: number
) {
  'worklet';
  return clamp(openProgress, 0, 1) * (1 - clamp(dismissProgress, 0, 1));
}
