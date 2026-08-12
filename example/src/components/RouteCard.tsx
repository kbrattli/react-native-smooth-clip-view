import { Link } from 'expo-router';
import type { ComponentProps } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

type RouteCardProps = {
  href: ComponentProps<typeof Link>['href'];
  title: string;
};

/**
 * One tappable entry on the home screen; add a route by adding one of these.
 *
 * The card style is passed to <Link> rather than to <Pressable>: `asChild`
 * renders through a Slot that object-spreads the child's `style`, which would
 * silently drop a Pressable style *function*. Press feedback therefore lives on
 * an inner row, driven by Pressable's children-as-function.
 */
export function RouteCard({ href, title }: RouteCardProps) {
  return (
    <Link asChild href={href} style={styles.card}>
      <Pressable
        accessibilityLabel={title}
        accessibilityRole="button"
        testID={`route-card-${String(href).replace(/^\//, '')}`}
      >
        {({ pressed }) => (
          <View style={pressed ? styles.rowPressed : styles.row}>
            <Text style={styles.title}>{title}</Text>
            <Text style={styles.chevron}>›</Text>
          </View>
        )}
      </Pressable>
    </Link>
  );
}

const row = {
  alignItems: 'center',
  flexDirection: 'row',
  justifyContent: 'space-between',
} as const;

const styles = StyleSheet.create({
  card: {
    backgroundColor: '#112743',
    borderColor: 'rgba(125, 233, 255, 0.22)',
    borderRadius: 20,
    borderWidth: StyleSheet.hairlineWidth,
    marginTop: 12,
    padding: 20,
  },
  row,
  rowPressed: { ...row, opacity: 0.72 },
  title: {
    color: '#F7FAFF',
    fontSize: 16,
    fontWeight: '800',
  },
  chevron: {
    color: '#66E3FF',
    fontSize: 26,
    fontWeight: '800',
  },
});
