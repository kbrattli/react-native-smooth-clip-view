import { StatusBar } from 'expo-status-bar';
import { Stack } from 'expo-router';
import { StyleSheet } from 'react-native';
import { GestureHandlerRootView } from 'react-native-gesture-handler';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { SharedElementTransitionProvider } from '../SharedElementTransitionContext';

export default function RootLayout() {
  return (
    <GestureHandlerRootView style={styles.root}>
      <SafeAreaProvider>
        <StatusBar style="light" />
        <SharedElementTransitionProvider>
          <Stack
            screenOptions={{
              headerStyle: { backgroundColor: '#07111F' },
              headerTintColor: '#F7FAFF',
              headerTitleStyle: { fontWeight: '800' },
              contentStyle: { backgroundColor: '#07111F' },
            }}
          >
            <Stack.Screen name="index" options={{ title: 'SmoothClipView' }} />
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
            <Stack.Screen name="clip-bench" options={{ title: 'Clip bench' }} />
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
            <Stack.Screen
              name="image-gallery-overlay"
              options={{
                animation: 'none',
                contentStyle: { backgroundColor: 'transparent' },
                headerShown: false,
                presentation: 'transparentModal',
              }}
            />
          </Stack>
        </SharedElementTransitionProvider>
      </SafeAreaProvider>
    </GestureHandlerRootView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
});
