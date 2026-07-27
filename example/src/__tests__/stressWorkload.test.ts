import { describe, expect, it } from '@jest/globals';
import {
  createStressWorkload,
  STRESS_BAR_COUNT,
  STRESS_HOST_COUNT,
  STRESS_IMAGE_LAYER_COUNT,
  STRESS_MARKER_COUNT,
  STRESS_ROWS_PER_HOST,
  STRESS_SVG_LAYER_COUNT,
  STRESS_TRACE_COUNT,
} from '../stressWorkload';

describe('pathological stress workload', () => {
  it('keeps the fixed brutal host and layer counts', () => {
    expect(STRESS_HOST_COUNT).toBe(10);

    for (let hostIndex = 0; hostIndex < STRESS_HOST_COUNT; hostIndex += 1) {
      const workload = createStressWorkload(hostIndex);

      expect(workload.rows).toHaveLength(STRESS_ROWS_PER_HOST);
      expect(workload.imageLayers).toHaveLength(STRESS_IMAGE_LAYER_COUNT);
      expect(workload.svgLayers).toHaveLength(STRESS_SVG_LAYER_COUNT);

      for (const row of workload.rows) {
        expect(row.bars).toHaveLength(STRESS_BAR_COUNT);
        expect(row.markers).toHaveLength(STRESS_MARKER_COUNT);
        expect(row.traces).toHaveLength(STRESS_TRACE_COUNT);
        for (const trace of row.traces) {
          expect(trace).toHaveLength(STRESS_MARKER_COUNT);
        }
      }
    }
  });

  it('generates deterministic data for a host', () => {
    expect(createStressWorkload(4)).toEqual(createStressWorkload(4));
    expect(createStressWorkload(4)).not.toEqual(createStressWorkload(5));
  });

  it('uses stable unique keys across all hosts and descendants', () => {
    const keys = Array.from({ length: STRESS_HOST_COUNT }, (_, hostIndex) => {
      const workload = createStressWorkload(hostIndex);

      return [
        ...workload.rows.map((row) => row.key),
        ...workload.imageLayers.map((layer) => layer.key),
        ...workload.svgLayers.map((layer) => layer.key),
      ];
    }).flat();

    expect(new Set(keys).size).toBe(keys.length);
  });
});
