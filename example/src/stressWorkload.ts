/* eslint-disable no-bitwise -- deterministic stress data uses integer hashing */
export const STRESS_HOST_COUNT = 10;
export const STRESS_ROWS_PER_HOST = 12;
export const STRESS_IMAGE_LAYER_COUNT = 6;
export const STRESS_SVG_LAYER_COUNT = 3;
export const STRESS_BAR_COUNT = 16;
export const STRESS_MARKER_COUNT = 8;
export const STRESS_TRACE_COUNT = 2;

export type StressImageLayer = Readonly<{
  key: string;
  leftRatio: number;
  opacity: number;
  rotation: number;
  scale: number;
  sourceIndex: 0 | 1 | 2;
  topRatio: number;
}>;

export type StressRowData = Readonly<{
  bars: readonly number[];
  key: string;
  markers: readonly number[];
  rowIndex: number;
  traces: readonly (readonly number[])[];
}>;

export type StressSvgLayer = Readonly<{
  key: string;
  layerIndex: number;
  seed: number;
}>;

export type StressWorkloadData = Readonly<{
  imageLayers: readonly StressImageLayer[];
  rows: readonly StressRowData[];
  svgLayers: readonly StressSvgLayer[];
}>;

function seededUnit(seed: number): number {
  let value = seed | 0;
  value = Math.imul(value ^ (value >>> 16), 0x45d9f3b);
  value = Math.imul(value ^ (value >>> 16), 0x45d9f3b);
  value ^= value >>> 16;

  return (value >>> 0) / 0xffffffff;
}

function createValues(count: number, seed: number): readonly number[] {
  return Array.from({ length: count }, (_, index) =>
    Number((0.12 + seededUnit(seed + index * 97) * 0.82).toFixed(6))
  );
}

function createRows(hostIndex: number): readonly StressRowData[] {
  return Array.from({ length: STRESS_ROWS_PER_HOST }, (_, rowIndex) => {
    const seed = (hostIndex + 1) * 10_007 + (rowIndex + 1) * 1_009;

    return {
      bars: createValues(STRESS_BAR_COUNT, seed + 11),
      key: `stress-${hostIndex}-row-${rowIndex}`,
      markers: createValues(STRESS_MARKER_COUNT, seed + 23),
      rowIndex,
      traces: Array.from(
        { length: STRESS_TRACE_COUNT },
        (_unused, traceIndex) =>
          createValues(STRESS_MARKER_COUNT, seed + 101 + traceIndex * 1_003)
      ),
    };
  });
}

function createImageLayers(hostIndex: number): readonly StressImageLayer[] {
  return Array.from({ length: STRESS_IMAGE_LAYER_COUNT }, (_, layerIndex) => {
    const seed = (hostIndex + 1) * 2_003 + (layerIndex + 1) * 211;

    return {
      key: `stress-${hostIndex}-image-${layerIndex}`,
      leftRatio: Number((-0.18 + seededUnit(seed + 17) * 0.82).toFixed(6)),
      opacity: Number((0.16 + seededUnit(seed + 29) * 0.2).toFixed(6)),
      rotation: Number((-18 + seededUnit(seed + 41) * 36).toFixed(6)),
      scale: Number((0.82 + seededUnit(seed + 53) * 0.54).toFixed(6)),
      sourceIndex: (layerIndex % 3) as 0 | 1 | 2,
      topRatio: Number((-0.12 + seededUnit(seed + 67) * 0.88).toFixed(6)),
    };
  });
}

function createSvgLayers(hostIndex: number): readonly StressSvgLayer[] {
  return Array.from({ length: STRESS_SVG_LAYER_COUNT }, (_, layerIndex) => ({
    key: `stress-${hostIndex}-svg-${layerIndex}`,
    layerIndex,
    seed: (hostIndex + 1) * 4_001 + (layerIndex + 1) * 503,
  }));
}

export function createStressWorkload(hostIndex: number): StressWorkloadData {
  return {
    imageLayers: createImageLayers(hostIndex),
    rows: createRows(hostIndex),
    svgLayers: createSvgLayers(hostIndex),
  };
}
