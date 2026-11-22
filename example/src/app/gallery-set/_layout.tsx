import { Stack } from 'expo-router';
import { GALLERY_BACKGROUND } from '../../galleryBench/galleryBenchGeometry';

/**
 * Gallery bench, Reanimated shared element transitions
 * (docs/gallery-mount-time.md). The same native stack and fade as the
 * flight's gallery.
 */
export default function GallerySetLayout() {
  return (
    <Stack
      screenOptions={{
        contentStyle: { backgroundColor: GALLERY_BACKGROUND },
        headerShown: false,
      }}
    >
      <Stack.Screen name="index" />
      <Stack.Screen
        name="[id]"
        options={{ animation: 'fade', gestureEnabled: false }}
      />
    </Stack>
  );
}
