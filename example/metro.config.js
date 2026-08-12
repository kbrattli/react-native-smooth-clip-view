const path = require('path');
// `expo/metro-config` is the documented entry point and resolves through the
// declared `expo` dependency; `@expo/metro-config` only ever worked by hoisting.
const { getDefaultConfig } = require('expo/metro-config');
const { withMetroConfig } = require('react-native-monorepo-config');

const root = path.resolve(__dirname, '..');

/**
 * Metro configuration
 * https://facebook.github.io/metro/docs/configuration
 *
 * @type {import('metro-config').MetroConfig}
 */
const config = withMetroConfig(getDefaultConfig(__dirname), {
  root,
  dirname: __dirname,
  conditions: ['react-native-smooth-clip-view-source'],
});

module.exports = config;
