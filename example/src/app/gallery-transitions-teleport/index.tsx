import { ScreenTransitionsGrid } from '../../galleryBench/galleryScreenTransitions';

export default function Grid() {
  return (
    <ScreenTransitionsGrid
      base="/gallery-transitions-teleport"
      label="react-native-screen-transitions, with teleport"
      teleport={true}
    />
  );
}
