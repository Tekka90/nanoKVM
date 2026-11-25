export function eventCodeToHid(code: string): number | null {
  const letter = /^Key([A-Z])$/.exec(code);
  if (letter?.[1]) return 4 + letter[1].charCodeAt(0) - "A".charCodeAt(0);
  const digit = /^Digit([1-9])$/.exec(code);
  if (digit?.[1]) return 30 + Number(digit[1]) - 1;
  if (code === "Digit0") return 39;
  const exact: Record<string, number> = {
    Enter: 40, Escape: 41, Backspace: 42, Tab: 43, Space: 44,
    Minus: 45, Equal: 46, BracketLeft: 47, BracketRight: 48,
    Backslash: 49, Semicolon: 51, Quote: 52, Backquote: 53,
    Comma: 54, Period: 55, Slash: 56, CapsLock: 57,
    Insert: 73, Home: 74, PageUp: 75, Delete: 76, End: 77, PageDown: 78,
    ArrowRight: 79, ArrowLeft: 80, ArrowDown: 81, ArrowUp: 82,
  };
  if (exact[code] !== undefined) return exact[code];
  const functionKey = /^F(\d+)$/.exec(code);
  if (functionKey) {
    const number = Number(functionKey[1]);
    if (number >= 1 && number <= 12) return 57 + number;
  }
  return null;
}
