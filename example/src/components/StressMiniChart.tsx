import { useMemo } from 'react';
import {
  Canvas,
  Circle,
  LinearGradient,
  Path,
  Rect,
  RoundedRect,
  vec,
} from '@shopify/react-native-skia';
import { StyleSheet } from 'react-native';
import type { StressRowData } from '../stressWorkload';

type StressMiniChartProps = {
  data: StressRowData;
  height: number;
  width: number;
};

const BAR_GAP = 1;
const CHART_INSET = 2;

function createPath(
  values: readonly number[],
  width: number,
  height: number
): string {
  return values
    .map((value, index) => {
      const x =
        CHART_INSET +
        (index / Math.max(1, values.length - 1)) * (width - CHART_INSET * 2);
      const y = CHART_INSET + (1 - value) * (height - CHART_INSET * 2);

      return `${index === 0 ? 'M' : 'L'} ${x.toFixed(2)} ${y.toFixed(2)}`;
    })
    .join(' ');
}

export function StressMiniChart({ data, height, width }: StressMiniChartProps) {
  const paths = useMemo(
    () => data.traces.map((trace) => createPath(trace, width, height)),
    [data.traces, height, width]
  );
  const barSlot = width / data.bars.length;
  const barWidth = Math.max(1, barSlot - BAR_GAP);

  return (
    <Canvas style={[styles.canvas, { height, width }]}>
      <RoundedRect x={0} y={0} width={width} height={height} r={4}>
        <LinearGradient
          start={vec(0, 0)}
          end={vec(width, height)}
          colors={['#072B42', '#16476A', '#051522']}
        />
      </RoundedRect>

      {data.bars.map((value, index) => {
        const barHeight = Math.max(1, value * (height - 5));

        return (
          <Rect
            key={`bar-${index}`}
            x={index * barSlot + BAR_GAP / 2}
            y={height - barHeight - 1}
            width={barWidth}
            height={barHeight}
            color={index % 2 === 0 ? '#0CC9E8' : '#766CF6'}
            opacity={0.42 + (index % 4) * 0.12}
          />
        );
      })}

      {paths.map((path, index) => (
        <Path
          key={`trace-${index}`}
          path={path}
          color={index === 0 ? '#F4FEFF' : '#FF8AC7'}
          opacity={0.82}
          style="stroke"
          strokeWidth={index === 0 ? 1 : 0.75}
        />
      ))}

      {data.markers.map((value, index) => (
        <Circle
          key={`marker-${index}`}
          cx={
            CHART_INSET +
            (index / Math.max(1, data.markers.length - 1)) *
              (width - CHART_INSET * 2)
          }
          cy={CHART_INSET + (1 - value) * (height - CHART_INSET * 2)}
          r={index % 3 === 0 ? 1.7 : 1.15}
          color={index % 2 === 0 ? '#FFF59D' : '#68F7D4'}
        />
      ))}
    </Canvas>
  );
}

const styles = StyleSheet.create({
  canvas: {
    borderRadius: 4,
  },
});
