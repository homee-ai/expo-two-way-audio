import { type PermissionResponse, createPermissionHook } from "expo-modules-core";
import { Platform } from "react-native";
import ExpoTwoWayAudioModule from "./ExpoTwoWayAudioModule";

export type InitializeOptions = {
  // ai-coustics SDK license key. iOS-only: enables on-device Quail voice focus.
  voiceFocusLicenseKey?: string;
};

export async function initialize(options?: InitializeOptions) {
  if (Platform.OS === "ios") {
    // Android's native initialize() takes no arguments; only iOS accepts the key.
    return await ExpoTwoWayAudioModule.initialize(options?.voiceFocusLicenseKey ?? null);
  }
  return await ExpoTwoWayAudioModule.initialize();
}

// True only on iOS after initialize() wired the Quail processor into the live
// audio engine (false before initialize, on failure, or on Android).
export function isVoiceFocusAvailable(): boolean {
  return ExpoTwoWayAudioModule.isVoiceFocusAvailable?.() ?? false;
}

// Latency-compensated enhancement toggle; no-op when unavailable (e.g. Android).
export function setVoiceFocusEnabled(enabled: boolean) {
  ExpoTwoWayAudioModule.setVoiceFocusEnabled?.(enabled);
}

export function playPCMData(audioData: Uint8Array) {
  return ExpoTwoWayAudioModule.playPCMData(audioData);
}

export function bypassVoiceProcessing(bypass: boolean) {
  return ExpoTwoWayAudioModule.bypassVoiceProcessing(bypass);
}

export function toggleRecording(val: boolean): boolean {
  return ExpoTwoWayAudioModule.toggleRecording(val);
}

export function isRecording(): boolean {
  return ExpoTwoWayAudioModule.isRecording();
}

export function flushPlayback() {
  return ExpoTwoWayAudioModule.flushPlayback();
}

export function tearDown() {
  return ExpoTwoWayAudioModule.tearDown();
}

export function restart() {
  return ExpoTwoWayAudioModule.restart();
}

export async function getMicrophonePermissionsAsync(): Promise<PermissionResponse> {
  return ExpoTwoWayAudioModule.getMicrophonePermissionsAsync();
}

export async function requestMicrophonePermissionsAsync(): Promise<PermissionResponse> {
  return ExpoTwoWayAudioModule.requestMicrophonePermissionsAsync();
}

export function getMicrophoneModeIOS() {
  return ExpoTwoWayAudioModule.getMicrophoneModeIOS();
}

export function setMicrophoneModeIOS() {
  return ExpoTwoWayAudioModule.setMicrophoneModeIOS();
}
