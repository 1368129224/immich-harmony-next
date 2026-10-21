interface ApiFailure {
  code?: number;
  message?: string;
}

// HarmonyOS HTTP failures are BusinessError objects, not necessarily Error instances.
export function formatApiError(error: Object): string {
  if (!error) {
    return '未知网络错误';
  }
  const failure = error as ApiFailure;
  switch (failure.code) {
    case 201:
      return '没有网络权限（201）';
    case 2300006:
      return '无法解析服务器域名（2300006）。请检查 DNS、代理或 IPv6 网络设置。';
    case 2300007:
      return '无法连接服务器（2300007）。请检查服务器端口和设备网络。';
    case 2300028:
      return '服务器请求超时（2300028）。请检查设备网络及服务器状态。';
    case 2300060:
      return '服务器 TLS 证书校验失败（2300060）。请检查证书和设备时间。';
    default:
      if (typeof failure.message === 'string' && failure.message) {
        return failure.code ? `${failure.message}（${failure.code}）` : failure.message;
      }
      return failure.code ? `网络错误（${failure.code}）` : '未知网络错误';
  }
}
