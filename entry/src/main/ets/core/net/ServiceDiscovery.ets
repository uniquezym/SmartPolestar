import { HttpClient } from './HttpClient';
import { SessionState } from '../model/SessionState';
import { BusinessError, Log } from '../../common/Log';

/**
 * 服务发现结果。
 */
export interface DiscoveredHosts {
  c3: string;
  c3Lbs: string;
}

/**
 * C3 服务发现 —— 对应 Android 端 p000.ga0 的 m1378n / m1380o。
 *
 * 流程：
 *   GET https://cnepmob.volvocars.com.cn/
 *   Accept: application/volvo.cloud.cnepmob.v1+json
 *   -> "c3".grpcHost     主业务主机
 *   -> "c3Lbs".grpcHost  定位/空调定时主机
 *
 * 安全约束：主机名必须匹配 *.volvocars.com.cn，否则拒绝使用，防止服务端被污染后
 * 把客户端引到任意主机。
 */
export class ServiceDiscovery {
  /** 服务发现端点。 */
  static readonly DISCOVERY_URL: string = 'https://cnepmob.volvocars.com.cn/';

  /** 服务发现响应使用的 Accept 头。 */
  static readonly DISCOVERY_ACCEPT: string = 'application/volvo.cloud.cnepmob.v1+json';

  /**
   * 允许的 C3 主机名正则。
   * 等价于 Java 的 (?i)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+volvocars\.com\.cn
   */
  private static readonly HOST_PATTERN: RegExp =
    /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+volvocars\.com\.cn$/i;

  /**
   * 填充会话中的两个 gRPC 主机（仅在缺失时才发起网络请求）。
   *
   * @param session 会话上下文
   */
  static async resolveHosts(session: SessionState): Promise<void> {
    if (session.c3Host.length === 0 || session.c3LbsHost.length === 0) {
      const root = await HttpClient.request(
        ServiceDiscovery.DISCOVERY_URL, 'GET', undefined, ServiceDiscovery.DISCOVERY_ACCEPT, undefined);

      if (session.c3Host.length === 0) {
        const c3 = root['c3'] as Record<string, Object> | undefined;
        if (c3 === undefined) {
          Log.error('C3 服务发现没有返回主服务');
        } else {
          session.c3Host = (c3['grpcHost'] as string) ?? '';
          if (!ServiceDiscovery.isTrustedHost(session.c3Host)) {
            Log.error('C3 服务发现返回了无效主机名');
          }
        }
      }

      if (session.c3LbsHost.length === 0) {
        const lbs = root['c3Lbs'] as Record<string, Object> | undefined;
        if (lbs === undefined) {
          Log.error('C3 服务发现没有返回 LBS 主机');
        } else {
          session.c3LbsHost = (lbs['grpcHost'] as string) ?? '';
          if (!ServiceDiscovery.isTrustedHost(session.c3LbsHost)) {
            Log.error('C3 服务发现返回了无效 LBS 主机名');
          }
        }
      }
    }
  }

  /**
   * 校验主机名是否在白名单内。
   */
  static isTrustedHost(host: string): boolean {
    return host.length > 0 && ServiceDiscovery.HOST_PATTERN.test(host);
  }

  /**
   * 解析服务发现结果（供单元测试使用）。
   */
  static parseHosts(root: Record<string, Object>): DiscoveredHosts {
    const c3 = root['c3'] as Record<string, Object> | undefined;
    const lbs = root['c3Lbs'] as Record<string, Object> | undefined;
    return {
      c3: (c3?.['grpcHost'] as string) ?? '',
      c3Lbs: (lbs?.['grpcHost'] as string) ?? ''
    };
  }
}
