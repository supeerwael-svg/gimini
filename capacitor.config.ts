import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'com.edutrack.app',
  appName: 'EduTrack',
  webDir: 'dist',
  android: {
    allowMixedContent: true,
  },
};

export default config;
