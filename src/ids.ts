let nextSmoothClipId = Date.now() * 1024;

export function allocateSmoothClipId(): number {
  nextSmoothClipId += 1;
  return nextSmoothClipId;
}
