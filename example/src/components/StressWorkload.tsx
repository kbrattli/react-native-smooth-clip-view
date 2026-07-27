import { useMemo } from 'react';
import { Image, StyleSheet, Text, View } from 'react-native';
import Svg, {
  Circle,
  ClipPath,
  Defs,
  G,
  LinearGradient,
  Mask,
  Path,
  Rect,
  Stop,
} from 'react-native-svg';
import {
  createStressWorkload,
  STRESS_MARKER_COUNT,
  type StressSvgLayer,
} from '../stressWorkload';
import { StressMiniChart } from './StressMiniChart';

const imageSources = [
  require('../../assets/stress-background.jpg'),
  require('../../assets/icon.png'),
  require('../../assets/splash-icon.png'),
] as const;
const SVG_PRIMITIVE_INDICES = Array.from({ length: 8 }, (_, index) => index);
const ROW_HEIGHT = 23;
const ROW_GAP = 3;
const ROW_HORIZONTAL_INSET = 8;

type StressWorkloadProps = {
  height: number;
  hostIndex: number;
  width: number;
};

type StressSvgOverlayProps = {
  height: number;
  hostIndex: number;
  layer: StressSvgLayer;
  width: number;
};

function StressSvgOverlay({
  height,
  hostIndex,
  layer,
  width,
}: StressSvgOverlayProps) {
  const gradientId = `stress-gradient-${hostIndex}-${layer.layerIndex}`;
  const clipId = `stress-clip-${hostIndex}-${layer.layerIndex}`;
  const maskId = `stress-mask-${hostIndex}-${layer.layerIndex}`;
  const phase = (layer.seed % 29) + layer.layerIndex * 7;
  const pathA = `M ${-width * 0.15} ${height * (0.22 + layer.layerIndex * 0.15)} C ${width * 0.18} ${height * 0.02}, ${width * 0.58} ${height * 0.78}, ${width * 1.15} ${height * (0.18 + layer.layerIndex * 0.12)}`;
  const pathB = `M ${width * 0.04} ${height * 0.86} Q ${width * (0.4 + layer.layerIndex * 0.05)} ${height * 0.08}, ${width * 0.96} ${height * 0.7}`;

  return (
    <Svg
      height={height}
      pointerEvents="none"
      style={styles.svgOverlay}
      viewBox={`0 0 ${width} ${height}`}
      width={width}
    >
      <Defs>
        <LinearGradient id={gradientId} x1="0" y1="0" x2="1" y2="1">
          <Stop offset="0" stopColor="#00E5FF" stopOpacity={0.08} />
          <Stop offset="0.48" stopColor="#7868FF" stopOpacity={0.32} />
          <Stop offset="1" stopColor="#FF5CB8" stopOpacity={0.09} />
        </LinearGradient>
        <ClipPath id={clipId}>
          <Circle
            cx={width * (0.32 + layer.layerIndex * 0.18)}
            cy={height * (0.36 + layer.layerIndex * 0.09)}
            r={Math.min(width, height) * 0.42}
          />
          <Rect
            x={width * 0.08}
            y={height * 0.1}
            width={width * 0.84}
            height={height * 0.78}
            rx={12 + layer.layerIndex * 4}
          />
        </ClipPath>
        <Mask id={maskId}>
          <Rect x={0} y={0} width={width} height={height} fill="#FFFFFF" />
          <Circle
            cx={width * (0.72 - layer.layerIndex * 0.11)}
            cy={height * (0.24 + layer.layerIndex * 0.19)}
            r={18 + layer.layerIndex * 9}
            fill="#000000"
            opacity={0.64}
          />
        </Mask>
      </Defs>

      <G clipPath={`url(#${clipId})`} mask={`url(#${maskId})`}>
        {SVG_PRIMITIVE_INDICES.map((index) => (
          <Rect
            key={`rect-${index}`}
            x={((index * 31 + phase) % 101) * (width / 100) - 12}
            y={((index * 47 + phase) % 97) * (height / 100) - 10}
            width={22 + ((index + layer.layerIndex) % 4) * 9}
            height={14 + ((index * 3 + layer.layerIndex) % 5) * 7}
            rx={4 + (index % 4)}
            fill={`url(#${gradientId})`}
            stroke={index % 2 === 0 ? '#72F5FF' : '#F58ACB'}
            strokeOpacity={0.24}
          />
        ))}
        {SVG_PRIMITIVE_INDICES.map((index) => (
          <Circle
            key={`circle-${index}`}
            cx={((index * 19 + phase * 2) % 103) * (width / 100)}
            cy={((index * 37 + phase * 3) % 101) * (height / 100)}
            r={3 + ((index + layer.layerIndex) % 5) * 2.4}
            fill={index % 2 === 0 ? '#87FFE2' : '#9D91FF'}
            fillOpacity={0.18 + (index % 3) * 0.08}
          />
        ))}
        <Path
          d={pathA}
          fill="none"
          stroke="#A9F9FF"
          strokeOpacity={0.38}
          strokeWidth={1.2 + layer.layerIndex * 0.35}
        />
        <Path
          d={pathB}
          fill="none"
          stroke="#FF8DCB"
          strokeDasharray={`${3 + layer.layerIndex} ${2 + layer.layerIndex}`}
          strokeOpacity={0.34}
          strokeWidth={0.9 + layer.layerIndex * 0.3}
        />
      </G>
    </Svg>
  );
}

export function StressWorkload({
  height,
  hostIndex,
  width,
}: StressWorkloadProps) {
  const workload = useMemo(() => createStressWorkload(hostIndex), [hostIndex]);
  const chartWidth = Math.max(1, width - ROW_HORIZONTAL_INSET * 2);

  return (
    <View
      pointerEvents="none"
      style={StyleSheet.absoluteFill}
      testID={`stress-workload-${hostIndex}`}
    >
      {workload.imageLayers.map((layer) => (
        <Image
          blurRadius={layer.sourceIndex === 0 ? 2.5 : 0.8}
          key={layer.key}
          resizeMode="cover"
          source={imageSources[layer.sourceIndex]}
          style={[
            styles.imageLayer,
            {
              height: height * 0.46,
              left: width * layer.leftRatio,
              opacity: layer.opacity,
              top: height * layer.topRatio,
              transform: [
                { rotate: `${layer.rotation}deg` },
                { scale: layer.scale },
              ],
              width: width * 0.68,
            },
          ]}
          testID={layer.key}
        />
      ))}

      <View style={styles.rows}>
        {workload.rows.map((row) => (
          <View
            key={row.key}
            style={[styles.row, { height: ROW_HEIGHT, width: chartWidth }]}
            testID={row.key}
          >
            <StressMiniChart
              data={row}
              height={ROW_HEIGHT}
              width={chartWidth}
            />
            <Text style={styles.rowLabel}>
              {String(row.rowIndex + 1).padStart(2, '0')}
            </Text>
            <View style={styles.rowTicks}>
              {Array.from({ length: STRESS_MARKER_COUNT }, (_, markerIndex) => (
                <View
                  key={`tick-${markerIndex}`}
                  style={[
                    styles.rowTick,
                    markerIndex % 3 === 0 && styles.rowTickStrong,
                  ]}
                />
              ))}
            </View>
          </View>
        ))}
      </View>

      {workload.svgLayers.map((layer) => (
        <StressSvgOverlay
          height={height}
          hostIndex={hostIndex}
          key={layer.key}
          layer={layer}
          width={width}
        />
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  imageLayer: {
    borderRadius: 18,
    position: 'absolute',
  },
  row: {
    borderColor: 'rgba(119, 232, 255, 0.16)',
    borderRadius: 4,
    borderWidth: StyleSheet.hairlineWidth,
    overflow: 'hidden',
    position: 'relative',
  },
  rowLabel: {
    color: 'rgba(232, 252, 255, 0.8)',
    fontSize: 6,
    fontWeight: '900',
    left: 3,
    letterSpacing: 0.3,
    position: 'absolute',
    top: 2,
  },
  rows: {
    gap: ROW_GAP,
    left: ROW_HORIZONTAL_INSET,
    position: 'absolute',
    top: 52,
  },
  rowTick: {
    backgroundColor: 'rgba(255, 255, 255, 0.26)',
    flex: 1,
    height: StyleSheet.hairlineWidth,
  },
  rowTicks: {
    bottom: 2,
    flexDirection: 'row',
    gap: 2,
    left: 3,
    position: 'absolute',
    right: 3,
  },
  rowTickStrong: {
    backgroundColor: 'rgba(107, 246, 255, 0.7)',
    height: 1,
  },
  svgOverlay: {
    left: 0,
    position: 'absolute',
    top: 0,
  },
});
