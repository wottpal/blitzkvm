// log writes one JSON line. Fields are ids, counts and statuses only: never
// boxes, tokens or keys.
export function log(event: string, fields: Record<string, string | number | boolean | undefined> = {}): void {
  console.log(JSON.stringify({ event, ...fields }));
}
