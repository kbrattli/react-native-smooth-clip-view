import {
  useCallback,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from 'react';
import {
  Pressable,
  StyleSheet,
  Text,
  useWindowDimensions,
  View,
} from 'react-native';
import {
  cancelAnimation,
  Easing,
  useDerivedValue,
  useSharedValue,
  withRepeat,
  withTiming,
  type SharedValue,
} from 'react-native-reanimated';
import { type ClipGeometry } from 'react-native-smooth-clip-view';
import { Button } from './Button';
import {
  AnimatedLayoutStressItem,
  DirectStressItem,
  LegacySmoothClipStressItem,
  NativeStressItem,
  ScalarStressItem,
  SharedDriverStressItem,
  useBoundDriver,
  useBoundScalarsDriver,
  useLoopingDriver,
} from './StressTestItem';
import { getStressClipGeometry } from '../stressGeometry';

export type StressImplementation =
  'legacy' | 'direct' | 'scalar' | 'native' | 'animated-layout';
type DriverTopology = 'shared' | 'independent';
type HostCount = 1 | 10 | 20;

type StressTestScreenProps = { implementation: StressImplementation };
type StressGridProps = {
  animatedClip: SharedValue<ClipGeometry>;
  cardHeight: number;
  cardWidth: number;
  hostCount: HostCount;
  handoffRun: number;
  implementation: StressImplementation;
  initialClip: ClipGeometry;
  running: boolean;
  topology: DriverTopology;
};

const GRID_GAP = 12;
const GRID_HORIZONTAL_INSET = 18;
const GRID_MAX_WIDTH = 440;
const CARD_ASPECT_RATIO = 1.08;
const HALF_OSCILLATION_MS = 650;

function Choice<T extends string | number>({
  current,
  label,
  onChange,
  value,
}: {
  current: T;
  label: string;
  onChange(value: T): void;
  value: T;
}) {
  const selected = current === value;
  return (
    <Pressable
      onPress={() => onChange(value)}
      style={[styles.choice, selected && styles.choiceSelected]}
    >
      <Text style={[styles.choiceText, selected && styles.choiceTextSelected]}>
        {label}
      </Text>
    </Pressable>
  );
}

type StressGridBodyProps = StressGridProps & { expandedClip: ClipGeometry };

function stressItemCommon(props: StressGridBodyProps, index: number) {
  return {
    animatedClip: props.animatedClip,
    expandedClip: props.expandedClip,
    height: props.cardHeight,
    handoffRun: props.handoffRun,
    index,
    initialClip: props.initialClip,
    running: props.running,
    width: props.cardWidth,
  };
}

function GridFrame({
  cardWidth,
  implementation,
  children,
}: {
  cardWidth: number;
  implementation: StressImplementation;
  children: ReactNode;
}) {
  return (
    <View
      style={[styles.grid, { width: cardWidth * 2 + GRID_GAP }]}
      testID={`stress-grid-${implementation}`}
    >
      {children}
    </View>
  );
}

function SharedInteractiveGrid(props: StressGridBodyProps) {
  const driver = useBoundDriver(props.initialClip, props.animatedClip);
  return (
    <GridFrame
      cardWidth={props.cardWidth}
      implementation={props.implementation}
    >
      {Array.from({ length: props.hostCount }, (_, index) => (
        <SharedDriverStressItem
          key={index}
          {...stressItemCommon(props, index)}
          driver={driver}
        />
      ))}
    </GridFrame>
  );
}

function SharedScalarsGrid(props: StressGridBodyProps) {
  const driver = useBoundScalarsDriver(props.initialClip, props.animatedClip);
  return (
    <GridFrame
      cardWidth={props.cardWidth}
      implementation={props.implementation}
    >
      {Array.from({ length: props.hostCount }, (_, index) => (
        <SharedDriverStressItem
          key={index}
          {...stressItemCommon(props, index)}
          driver={driver}
        />
      ))}
    </GridFrame>
  );
}

function SharedNativeGrid(props: StressGridBodyProps) {
  const driver = useLoopingDriver(
    props.initialClip,
    props.expandedClip,
    props.running,
    props.handoffRun
  );
  return (
    <GridFrame
      cardWidth={props.cardWidth}
      implementation={props.implementation}
    >
      {Array.from({ length: props.hostCount }, (_, index) => (
        <SharedDriverStressItem
          key={index}
          {...stressItemCommon(props, index)}
          driver={driver}
        />
      ))}
    </GridFrame>
  );
}

function IndependentGrid(props: StressGridBodyProps) {
  return (
    <GridFrame
      cardWidth={props.cardWidth}
      implementation={props.implementation}
    >
      {Array.from({ length: props.hostCount }, (_, index) => {
        const common = stressItemCommon(props, index);
        if (props.implementation === 'animated-layout') {
          return <AnimatedLayoutStressItem key={index} {...common} />;
        }
        if (props.implementation === 'legacy') {
          return <LegacySmoothClipStressItem key={index} {...common} />;
        }
        if (props.implementation === 'direct') {
          return <DirectStressItem key={index} {...common} />;
        }
        if (props.implementation === 'scalar') {
          return <ScalarStressItem key={index} {...common} />;
        }
        return <NativeStressItem key={index} {...common} />;
      })}
    </GridFrame>
  );
}

function StressGrid(props: StressGridProps) {
  const expandedClip = useMemo(
    () => getStressClipGeometry(1, props.cardWidth, props.cardHeight),
    [props.cardHeight, props.cardWidth]
  );
  // Only the selected implementation mounts a driver: an always-live driver
  // installs a per-frame reaction plus a native call that would contaminate
  // every other benchmark mode's measurements.
  const body = { ...props, expandedClip };
  if (props.topology === 'shared') {
    if (props.implementation === 'direct') {
      return <SharedInteractiveGrid {...body} />;
    }
    if (props.implementation === 'scalar') {
      return <SharedScalarsGrid {...body} />;
    }
    if (props.implementation === 'native') {
      return <SharedNativeGrid {...body} />;
    }
  }
  return <IndependentGrid {...body} />;
}

export function StressTestScreen({ implementation }: StressTestScreenProps) {
  const { width: windowWidth } = useWindowDimensions();
  const [running, setRunning] = useState(false);
  const [hostCount, setHostCount] = useState<HostCount>(10);
  const [handoffRun, setHandoffRun] = useState(0);
  const [topology, setTopology] = useState<DriverTopology>('shared');
  const progress = useSharedValue(0);
  const gridWidth = Math.min(
    GRID_MAX_WIDTH,
    Math.max(0, windowWidth - GRID_HORIZONTAL_INSET * 2)
  );
  const cardWidth = (gridWidth - GRID_GAP) / 2;
  const cardHeight = cardWidth * CARD_ASPECT_RATIO;
  const initialClip = useMemo(
    () => getStressClipGeometry(0, cardWidth, cardHeight),
    [cardHeight, cardWidth]
  );
  const animatedClip = useDerivedValue(() =>
    getStressClipGeometry(progress.value, cardWidth, cardHeight)
  );
  const dimensionKey = `${Math.round(cardWidth)}x${Math.round(cardHeight)}`;

  const resetAnimation = useCallback(() => {
    cancelAnimation(progress);
    progress.value = 0;
  }, [progress]);

  useEffect(() => resetAnimation, [resetAnimation]);
  useEffect(() => {
    resetAnimation();
    setRunning(false);
  }, [hostCount, implementation, resetAnimation, topology]);

  const toggleAnimation = useCallback(() => {
    if (running) {
      resetAnimation();
      setRunning(false);
      return;
    }
    if (implementation !== 'native') {
      progress.value = withRepeat(
        withTiming(1, {
          duration: HALF_OSCILLATION_MS,
          easing: Easing.inOut(Easing.cubic),
        }),
        -1,
        true
      );
    }
    setRunning(true);
  }, [implementation, progress, resetAnimation, running]);

  return (
    <View style={styles.screen} testID={`stress-screen-${implementation}-root`}>
      <View style={styles.controls}>
        <Text style={styles.modeLabel}>
          {implementation === 'native'
            ? 'Core Animation · no per-frame app callback'
            : implementation === 'scalar'
              ? 'Scalar hot path · no SharedValue write'
              : 'Fixed Yoga footprint · animated clip geometry'}
        </Text>
        <View style={styles.choiceRow}>
          {([1, 10, 20] as const).map((count) => (
            <Choice
              current={hostCount}
              key={count}
              label={`${count} host${count === 1 ? '' : 's'}`}
              onChange={(value) => setHostCount(value as HostCount)}
              value={count}
            />
          ))}
        </View>
        <View style={styles.choiceRow}>
          <Choice
            current={topology}
            label="Shared driver"
            onChange={(value) => setTopology(value as DriverTopology)}
            value="shared"
          />
          <Choice
            current={topology}
            label="Independent"
            onChange={(value) => setTopology(value as DriverTopology)}
            value="independent"
          />
        </View>
        <Button onPress={toggleAnimation} running={running} />
        {implementation === 'native' && (
          <Pressable
            onPress={() => setHandoffRun((value) => value + 1)}
            style={styles.handoffButton}
            testID="stress-handoff-button"
          >
            <Text style={styles.handoffButtonText}>Grab → update → spring</Text>
          </Pressable>
        )}
      </View>

      <StressGrid
        animatedClip={animatedClip}
        cardHeight={cardHeight}
        cardWidth={cardWidth}
        hostCount={hostCount}
        handoffRun={handoffRun}
        implementation={implementation}
        initialClip={initialClip}
        key={`${implementation}-${topology}-${hostCount}-${dimensionKey}`}
        running={running}
        topology={topology}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { marginTop: 14 },
  controls: { alignItems: 'center', paddingHorizontal: GRID_HORIZONTAL_INSET },
  modeLabel: {
    color: '#8397AF',
    fontSize: 12,
    fontWeight: '700',
    letterSpacing: 0.2,
  },
  choiceRow: { flexDirection: 'row', gap: 6, marginTop: 9 },
  choice: {
    borderColor: '#263E59',
    borderRadius: 8,
    borderWidth: StyleSheet.hairlineWidth,
    paddingHorizontal: 9,
    paddingVertical: 6,
  },
  choiceSelected: { backgroundColor: '#24445F' },
  choiceText: { color: '#8397AF', fontSize: 10, fontWeight: '700' },
  choiceTextSelected: { color: '#D6F8FF' },
  handoffButton: {
    borderColor: '#4DD7FF',
    borderRadius: 8,
    borderWidth: StyleSheet.hairlineWidth,
    marginTop: 10,
    paddingHorizontal: 12,
    paddingVertical: 7,
  },
  handoffButtonText: { color: '#D6F8FF', fontSize: 11, fontWeight: '700' },
  grid: {
    alignSelf: 'center',
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: GRID_GAP,
    marginTop: 18,
  },
});
