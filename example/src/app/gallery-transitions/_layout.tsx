import { ScreenTransitionsLayout } from '../../galleryBench/galleryScreenTransitions';

const MODE = { teleport: false } as const;

/** Gallery bench: react-native-screen-transitions, without teleport (docs/gallery-mount-time.md). */
export default function Layout() {
  return <ScreenTransitionsLayout {...MODE} />;
}
