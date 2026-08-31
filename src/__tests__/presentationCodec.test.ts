import { describe, expect, it } from '@jest/globals';

import { canonicalizeClipPresentation } from '../geometry';
import {
  PRESENTATION_STRIDE,
  presentationFromPacket,
  presentationPacket,
} from '../presentationCodec';

describe('presentation codec', () => {
  it('round-trips every presentation channel through one versionless packet', () => {
    const presentation = canonicalizeClipPresentation({
      clip: {
        x: -3,
        y: 7,
        width: 120,
        height: 80,
        radius: 0,
        topLeftRadius: 32,
        topRightRadius: 20,
        bottomRightRadius: 12,
        bottomLeftRadius: 4,
        curve: 'continuous',
      },
      contentTranslateX: 11,
      contentTranslateY: -9,
      contentScale: 0.75,
      boxShadow: {
        color: '#33669980',
        offsetX: 3,
        offsetY: 4,
        blurRadius: 64,
        spreadDistance: -2,
      },
    });

    expect(presentation).not.toBeNull();
    const packet = presentationPacket(presentation!);
    expect(packet).toHaveLength(PRESENTATION_STRIDE);
    expect(presentationFromPacket(packet)).toEqual(presentation);
  });

  it('preserves an absent shadow and rejects incomplete or non-finite packets', () => {
    const presentation = canonicalizeClipPresentation({
      clip: { x: 0, y: 0, width: 40, height: 30, radius: 8 },
      contentTranslateX: 0,
      contentTranslateY: 0,
    });
    const packet = presentationPacket(presentation!);

    expect(presentationFromPacket(packet)?.boxShadow).toBeUndefined();
    expect(presentationFromPacket(packet.slice(1))).toBeNull();
    packet[5] = Number.NaN;
    expect(presentationFromPacket(packet)).toBeNull();

    const invalidCurve = presentationPacket(presentation!);
    invalidCurve[8] = 2;
    expect(presentationFromPacket(invalidCurve)).toBeNull();
    const invalidScale = presentationPacket(presentation!);
    invalidScale[11] = 0;
    expect(presentationFromPacket(invalidScale)).toBeNull();
    const invalidShadowFlag = presentationPacket(presentation!);
    invalidShadowFlag[12] = 2;
    expect(presentationFromPacket(invalidShadowFlag)).toBeNull();
  });
});
