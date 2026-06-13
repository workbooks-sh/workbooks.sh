// AI search preview (wb-aakl.19). Stubbed synthesised-answer payload so the
// AI search UI (prompt → answer + sources + follow-ups) is demonstrable before
// the real model/nexus lane is wired. Shape mirrors what the live endpoint
// would return, so the component doesn't change when it goes real.

export interface AiSource {
  title: string;
  url?: string;
  path?: string;
  snippet: string;
}
export interface AiAnswer {
  answer: string;
  sources: AiSource[];
  related: string[];
}

export function aiAnswer(query: string): AiAnswer {
  const q = query.trim();
  const topic = q || "your workspace";
  return {
    answer:
      `Here's what I found across your files and the web on **${topic}**. ` +
      `The short version: it spans a few of your workbooks and some current sources. ` +
      `I've pulled the most relevant passages below and linked where each came from — ` +
      `ask a follow-up to go deeper or have me draft something from these.`,
    sources: [
      { title: "Designing Data-Intensive Apps", path: "Reading/Designing Data-Intensive Apps.md", snippet: `A chapter touches directly on ${topic}; bookmarked in Reading.` },
      { title: `${topic} — overview`, url: "https://en.wikipedia.org/wiki/Main_Page", snippet: `Background, history and key concepts for ${topic}.` },
      { title: "2026 Plan", path: "Roadmap/2026 Plan.org", snippet: `Your roadmap references ${topic} under Q3 goals.` },
      { title: `${topic}: docs & guides`, url: "https://example.com", snippet: `Getting-started guide with practical examples.` },
    ],
    related: [
      `How does ${topic} apply to my current work?`,
      `Summarise everything in my files about ${topic}`,
      `What changed recently with ${topic}?`,
    ],
  };
}
