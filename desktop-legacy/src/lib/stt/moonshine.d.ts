// Ambient type stub for @moonshine-ai/moonshine-js (v0.1.x ships
// without .d.ts files). Covers only the surface this app uses; expand
// as needed. Upstream issue: the package's `exports` only maps `.` →
// the bundled .min.js with no `types` entry.
declare module "@moonshine-ai/moonshine-js" {
  export interface TranscriberCallbacks {
    onTranscriptionCommitted?: (text: string) => void;
    onTranscriptionUpdated?: (text: string) => void;
  }

  export class MicrophoneTranscriber {
    constructor(
      modelUrl: string,
      callbacks: TranscriberCallbacks,
      useVAD?: boolean,
      precision?: string,
    );
    start(): Promise<void>;
    stop(): Promise<void>;
  }

  export class MoonshineSpeechRecognition {
    constructor(modelUrl?: string);
    addEventListener(type: string, listener: (e: unknown) => void): void;
  }
}
