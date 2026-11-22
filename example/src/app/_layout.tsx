import { StatusBar } from 'expo-status-bar';
import { Stack } from 'expo-router';
import { StyleSheet } from 'react-native';
import { GestureHandlerRootView } from 'react-native-gesture-handler';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { ReanimatedScreenProvider } from 'react-native-screens/reanimated';
import { GalleryOverlayHost } from '../components/GalleryOverlayHost';
import { cancelHeroWayBack } from '../heroBench/flightBridge';
import {
  HeroBenchProbe,
  HeroBenchTapMarker,
} from '../heroBench/heroBenchProbe';
import { SharedElementTransitionProvider } from '../SharedElementTransitionContext';

export default function RootLayout() {
  return (
    <GestureHandlerRootView style={styles.root}>
      <SafeAreaProvider>
        <StatusBar style="light" />
        <SharedElementTransitionProvider>
          {/*
            react-native-screens' Reanimated screens, so a screen can read its
            transition progress on the UI thread
            (`useReanimatedTransitionProgress`; the hero bench's way back).
          */}
          <ReanimatedScreenProvider>
            <Stack
              screenOptions={{
                headerStyle: { backgroundColor: '#07111F' },
                headerTintColor: '#F7FAFF',
                headerTitleStyle: { fontWeight: '800' },
                contentStyle: { backgroundColor: '#07111F' },
              }}
            >
              <Stack.Screen
                name="index"
                options={{ title: 'SmoothClipView' }}
              />
              <Stack.Screen
                name="benchmark-screen"
                options={{ title: 'Stress benchmark' }}
              />
              <Stack.Screen
                name="zoom-transition"
                options={{ title: 'Zoom transition' }}
              />
              <Stack.Screen
                name="image-gallery"
                options={{
                  contentStyle: { backgroundColor: '#000000' },
                  headerStyle: { backgroundColor: '#000000' },
                  title: 'Gallery',
                }}
              />
              <Stack.Screen
                name="clip-bench"
                options={{ title: 'Clip bench' }}
              />
              {/*
              Hero bench: Reanimated SET vs a SmoothClipView flight
              (docs/hero-bench.md). Headerless so the hero sits at known
              window coordinates. Each detail is registered twice: pushed with
              the default slide and the swipe-back gesture, and as a page
              sheet that is dragged down to dismiss.
            */}
              <Stack.Screen
                name="hero-bench"
                options={{ headerShown: false }}
              />
              <Stack.Screen
                name="hero-bench-set"
                options={{ gestureEnabled: true, headerShown: false }}
              />
              <Stack.Screen
                name="hero-bench-set-sheet"
                options={{ headerShown: false, presentation: 'pageSheet' }}
              />
              <Stack.Screen
                listeners={{ gestureCancel: cancelHeroWayBack }}
                name="hero-bench-flight"
                options={{ gestureEnabled: true, headerShown: false }}
              />
              <Stack.Screen
                listeners={{ gestureCancel: cancelHeroWayBack }}
                name="hero-bench-flight-sheet"
                options={{ headerShown: false, presentation: 'pageSheet' }}
              />
              {/*
              The overlay is a real route. `transparentModal` keeps the card
              list mounted and visible beneath it, and `animation: 'none'`
              stops the navigator adding motion of its own — the native clip
              window is the entire transition.
            */}
              <Stack.Screen
                name="zoom-overlay"
                options={{
                  animation: 'none',
                  contentStyle: { backgroundColor: 'transparent' },
                  headerShown: false,
                  presentation: 'transparentModal',
                }}
              />
            </Stack>
          </ReanimatedScreenProvider>
          {/*
            The gallery overlay is NOT a route: it mounts as the navigator's
            topmost sibling in the root surface, so its first frame composites
            at the next vsync and the clip transition never waits on (or races)
            a modal presentation.
          */}
          <GalleryOverlayHost />
          <HeroBenchProbe />
          <HeroBenchTapMarker />
        </SharedElementTransitionProvider>
      </SafeAreaProvider>
    </GestureHandlerRootView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
});
