import {
  Circle,
  Defs,
  LinearGradient,
  Path,
  Rect,
  Stop,
  Svg,
} from 'react-native-svg';
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
  const gradientId = `row-gradient-${data.key}`;
  const barSlot = width / data.bars.length;
  const barWidth = Math.max(1, barSlot - BAR_GAP);

  return (
    <Svg height={height} width={width} viewBox={`0 0 ${width} ${height}`}>
      <Defs>
        <LinearGradient id={gradientId} x1="0" y1="0" x2="1" y2="1">
          <Stop offset="0" stopColor="#072B42" />
          <Stop offset="0.52" stopColor="#16476A" />
          <Stop offset="1" stopColor="#051522" />
        </LinearGradient>
      </Defs>
      <Rect
        x={0}
        y={0}
        width={width}
        height={height}
        rx={4}
        fill={`url(#${gradientId})`}
      />

      {data.bars.map((value, index) => {
        const barHeight = Math.max(1, value * (height - 5));

        return (
          <Rect
            key={`bar-${index}`}
            x={index * barSlot + BAR_GAP / 2}
            y={height - barHeight - 1}
            width={barWidth}
            height={barHeight}
            fill={index % 2 === 0 ? '#0CC9E8' : '#766CF6'}
            opacity={0.42 + (index % 4) * 0.12}
          />
        );
      })}

      {data.traces.map((trace, index) => (
        <Path
          key={`trace-${index}`}
          d={createPath(trace, width, height)}
          fill="none"
          stroke={index === 0 ? '#F4FEFF' : '#FF8AC7'}
          strokeOpacity={0.82}
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
          fill={index % 2 === 0 ? '#FFF59D' : '#68F7D4'}
        />
      ))}
    </Svg>
  );
}
