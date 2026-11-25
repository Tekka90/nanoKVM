export interface StatInput {
  packets: number;
  bytes: number;
}

export interface StatBaseline extends StatInput {
  at: number;
}

export interface StatSample {
  kbps: number;
  fps: number;
}

export function sampleStats(
  previous: StatBaseline | null,
  current: StatInput,
  at: number,
): { baseline: StatBaseline; sample: StatSample | null } {
  const baseline = { ...current, at };
  if (!previous || at <= previous.at + 50) {
    return { baseline, sample: null };
  }
  const seconds = (at - previous.at) / 1000;
  return {
    baseline,
    sample: {
      kbps: ((current.bytes - previous.bytes) * 8) / 1000 / seconds,
      fps: (current.packets - previous.packets) / seconds,
    },
  };
}

export function appendSample(
  history: StatSample[],
  sample: StatSample | null,
  capacity = 60,
): StatSample[] {
  if (!sample) return history;
  return [...history, sample].slice(-capacity);
}

export function summarize(history: StatSample[]): {
  averageKbps: number;
  peakKbps: number;
} {
  if (!history.length) return { averageKbps: 0, peakKbps: 0 };
  return {
    averageKbps:
      history.reduce((total, sample) => total + sample.kbps, 0) /
      history.length,
    peakKbps: Math.max(...history.map((sample) => sample.kbps)),
  };
}
