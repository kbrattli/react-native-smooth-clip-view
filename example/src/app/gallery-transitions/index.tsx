import { ScreenTransitionsGrid } from '../../galleryBench/galleryScreenTransitions';

export default function Grid() {
  return (
    <ScreenTransitionsGrid
      base="/gallery-transitions"
      label="react-native-screen-transitions, without teleport"
      teleport={false}
    />
  );
}
