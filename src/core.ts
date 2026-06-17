import { type PermissionResponse, createPermissionHook } from "expo-modules-core";
import ExpoTwoWayAudioModule from "./ExpoTwoWayAudioModule";

export type InitializeOptions = {
  // ai-coustics SDK license key. Enables on-device Quail voice focus (iOS + Android).
  voiceFocusLicenseKey?: string;
};

export async function initialize(options?: InitializeOptions): Promise<boolean> {
  // Both iOS and Android native initialize() accept the license key (or null).
  return await ExpoTwoWayAudioModule.initialize(options?.voiceFocusLicenseKey ?? null);
}

// True after initialize() wired the Quail processor into the live audio engine
// (false before initialize, on init failure, or when no license key was provided).
export function isVoiceFocusAvailable(): boolean {
  return ExpoTwoWayAudioModule.isVoiceFocusAvailable?.() ?? false;
}

// Latency-compensated enhancement toggle; a no-op when the processor wasn't wired
// into the engine by initialize().
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
