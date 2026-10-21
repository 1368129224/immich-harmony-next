interface ApiFailure {
  code?: number;
  message?: string;
}

// HarmonyOS HTTP failures are BusinessError objects, not necessarily Error instances.
export function formatApiError(error: Object): string {
  if (!error) {
    return 'Unknown network error';
  }
  const failure = error as ApiFailure;
  switch (failure.code) {
    case 201:
      return 'Internet permission denied (201)';
    case 2300006:
      return 'Cannot resolve server hostname (2300006). Check DNS and IPv6 connectivity; an IPv6-only server may not be reachable from this emulator.';
    case 2300007:
      return 'Cannot connect to server (2300007). Check the server port and device network.';
    case 2300028:
      return 'Server request timed out (2300028). Check device network and server availability.';
    case 2300060:
      return 'Server TLS certificate verification failed (2300060). Check its certificate and device clock.';
    default:
      if (typeof failure.message === 'string' && failure.message) {
        return failure.code ? `${failure.message} (${failure.code})` : failure.message;
      }
      return failure.code ? `Network error (${failure.code})` : 'Unknown network error';
  }
}
