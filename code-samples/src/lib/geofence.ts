const EARTH_RADIUS_M = 6_371_000;

export function distanceMeters(
  lat1: number, lng1: number, lat2: number, lng2: number
): number {
  const toRad = (deg: number) => (deg * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return EARTH_RADIUS_M * 2 * Math.asin(Math.sqrt(a));
}

export function isWithinRadius(
  lat1: number, lng1: number, lat2: number, lng2: number,
  radiusMeters: number,
): boolean {
  return distanceMeters(lat1, lng1, lat2, lng2) <= radiusMeters;
}
