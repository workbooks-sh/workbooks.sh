// @capacitor/haptics whisper/voice tier.
// whisper = light/selection (subtle confirmation)
// voice   = medium/heavy/notification (meaningful state change)
// All calls are fire-and-forget; failures are silent (web fallback = no-op).

import { Haptics, ImpactStyle, NotificationType } from '@capacitor/haptics';
import { isHapticsEnabled } from './settings.js';

const h = (fn) => { if (!isHapticsEnabled()) return; try { fn(); } catch (_) {} };

// whisper tier — light confirmation, selection feedback
export const whisperTap   = () => h(() => Haptics.impact({ style: ImpactStyle.Light }));
export const whisperPick  = () => h(() => Haptics.selectionChanged());

// voice tier — meaningful state changes
export const voiceDeal    = () => h(() => Haptics.impact({ style: ImpactStyle.Medium }));
export const voiceKill    = () => h(() => Haptics.impact({ style: ImpactStyle.Heavy }));
export const voiceError   = () => h(() => Haptics.notification({ type: NotificationType.Warning }));
export const voiceSuccess = () => h(() => Haptics.notification({ type: NotificationType.Success }));
export const voiceFail    = () => h(() => Haptics.notification({ type: NotificationType.Error }));
