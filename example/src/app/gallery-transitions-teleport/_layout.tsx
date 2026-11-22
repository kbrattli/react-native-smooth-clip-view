import { ScreenTransitionsLayout } from '../../galleryBench/galleryScreenTransitions';

const MODE = { teleport: true } as const;

/** Gallery bench: react-native-screen-transitions, with teleport (docs/gallery-mount-time.md). */
export default function Layout() {
  return <ScreenTransitionsLayout {...MODE} />;
}
