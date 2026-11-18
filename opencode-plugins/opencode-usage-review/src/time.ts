const DAY_MS = 86_400_000;

export interface TimeRange {
  from: number;
  to: number;
  label: string;
}

export function timezoneName(): string {
  return Intl.DateTimeFormat().resolvedOptions().timeZone;
}

export function localDayKey(timestamp: number): string {
  const date = new Date(timestamp);
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function startOfLocalDay(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate(), 0, 0, 0, 0);
}

export function localDayRange(day: string, now = new Date()): TimeRange {
  const base = startOfLocalDay(now);
  if (day === "today") {
    const tomorrow = new Date(base);
    tomorrow.setDate(tomorrow.getDate() + 1);
    return { from: base.getTime(), to: tomorrow.getTime(), label: localDayKey(base.getTime()) };
  }
  if (day === "yesterday") {
    const yesterday = new Date(base);
    yesterday.setDate(yesterday.getDate() - 1);
    return {
      from: yesterday.getTime(),
      to: base.getTime(),
      label: localDayKey(yesterday.getTime()),
    };
  }
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(day);
  if (!match) {
    throw new Error(`Invalid day "${day}". Use today, yesterday, or YYYY-MM-DD.`);
  }
  const year = Number(match[1]);
  const month = Number(match[2]);
  const date = Number(match[3]);
  const start = new Date(year, month - 1, date, 0, 0, 0, 0);
  const end = new Date(start);
  end.setDate(end.getDate() + 1);
  return { from: start.getTime(), to: end.getTime(), label: localDayKey(start.getTime()) };
}

export function lastDaysRange(days: number, now = new Date()): TimeRange {
  if (!Number.isInteger(days) || days < 1 || days > 366) {
    throw new Error("--days must be an integer from 1 to 366.");
  }
  const end = startOfLocalDay(now);
  end.setDate(end.getDate() + 1);
  const start = new Date(end);
  start.setDate(start.getDate() - days);
  return {
    from: start.getTime(),
    to: Math.min(end.getTime(), now.getTime() + 1),
    label: `last ${days} day${days === 1 ? "" : "s"}`,
  };
}

export function isDeepSeekPeak(timestamp: number): boolean {
  const date = new Date(timestamp);
  const weekday = date.getUTCDay();
  if (weekday === 0 || weekday === 6) return false;
  const hour = date.getUTCHours();
  return (hour >= 1 && hour < 4) || (hour >= 6 && hour < 10);
}

export function formatDuration(ms: number): string {
  if (!Number.isFinite(ms) || ms <= 0) return "0m";
  const minutes = Math.round(ms / 60_000);
  if (minutes < 60) return `${minutes}m`;
  const hours = minutes / 60;
  if (hours < 10) return `${hours.toFixed(2).replace(/0$/, "")}h`;
  return `${hours.toFixed(1)}h`;
}

export function formatMoney(usd: number): string {
  if (!Number.isFinite(usd)) return "$0.00";
  if (usd === 0) return "$0.00";
  if (usd < 0.01) return `$${usd.toFixed(4)}`;
  if (usd < 10) return `$${usd.toFixed(2)}`;
  return `$${usd.toFixed(1)}`;
}

export function formatDateTime(timestamp: number): string {
  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  }).format(timestamp);
}

export function formatPercent(value: number): string {
  return `${Math.round(value * 100)}%`;
}

export function dayKeysBetween(from: number, to: number): string[] {
  const keys: string[] = [];
  const cursor = new Date(from);
  const end = new Date(to);
  while (cursor.getTime() < end.getTime()) {
    keys.push(localDayKey(cursor.getTime()));
    cursor.setDate(cursor.getDate() + 1);
    if (keys.length > 400) break;
  }
  return keys;
}

export function dayMs(): number {
  return DAY_MS;
}
