import { StatusBar } from 'expo-status-bar';
import { Stack } from 'expo-router';
import { SafeAreaProvider } from 'react-native-safe-area-context';

export default function RootLayout() {
  return (
    <SafeAreaProvider>
      <StatusBar style="light" />
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
      </Stack>
    </SafeAreaProvider>
  );
}
