import { useRouter } from 'expo-router';
import { useCallback, useMemo } from 'react';
import { StyleSheet, View } from 'react-native';
import { GestureDetector } from 'react-native-gesture-handler';
import {
  ChoreographyScreen,
  useChoreographyRouter,
} from 'react-native-screen-choreography/expo-router';
import {
  GalleryGridScreen,
  GalleryPhoto,
  galleryTileTap,
  scheduleGalleryMarkerClear,
} from '../../galleryBench/GalleryBench';
import { rectStyle } from '../../galleryBench/galleryBenchGeometry';
import {
  galleryChoreography,
  galleryChoreographyGroup,
} from '../../galleryBench/galleryChoreography';
import type { GalleryImage } from '../../galleryImages';
import type { HeroRect } from '../../heroBench/heroBenchGeometry';

/**
 * The grid: each tile's photo is a shared element owner (rendered once, on
 * this screen). The tap pushes through `useChoreographyRouter` with the
 * tile's group and the definition's motion, as `Element.Pressable` would.
 */
export default function GalleryChoreographyGrid() {
  const router = useRouter();
  const { push } = useChoreographyRouter(router);
  const open = useCallback(
    (index: number) => {
      push({
        href: {
          pathname: '/gallery-choreography/[id]',
          params: { id: String(index) },
        },
        transitionConfig: { group: galleryChoreographyGroup(index) },
        ...galleryChoreography.navigationOptions,
      }).catch(() => undefined);
      scheduleGalleryMarkerClear();
    },
    [push]
  );
  return (
    <ChoreographyScreen>
      <GalleryGridScreen
        label="react-native-screen-choreography"
        onExit={() => router.back()}
        renderTile={({ index, photo, rect }) => (
          <ChoreographyTile
            index={index}
            key={photo.id}
            open={open}
            photo={photo}
            rect={rect}
          />
        )}
      />
    </ChoreographyScreen>
  );
}

function ChoreographyTile({
  index,
  open,
  photo,
  rect,
}: {
  index: number;
  open: (index: number) => void;
  photo: GalleryImage;
  rect: HeroRect;
}) {
  const tap = useMemo(() => galleryTileTap(index, open), [index, open]);
  return (
    <GestureDetector gesture={tap}>
      <View style={rectStyle(rect)} testID={`gallery-tile-${index}`}>
        <galleryChoreography.Element
          groupId={galleryChoreographyGroup(index)}
          name="photo"
          style={StyleSheet.absoluteFill}
        >
          <GalleryPhoto photo={photo} />
        </galleryChoreography.Element>
      </View>
    </GestureDetector>
  );
}
