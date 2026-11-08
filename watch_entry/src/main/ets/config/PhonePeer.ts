// HarmonyOS 5+ Wear Engine fingerprints are AGC APP IDs, not certificate SHA256.
export const PHONE_BUNDLE_NAME: string = 'com.coevomind.clawmate';
export const PHONE_APP_ID: string = '6917613102135452205';
export const WATCH_BUNDLE_NAME: string = 'com.coevomind.clawmate';
// Phone and watch are device-specific modules of the same AGC application.
export const WATCH_APP_ID: string = PHONE_APP_ID;
export const WATCH_ABILITY_NAME: string = 'HiWearMainAbility';
